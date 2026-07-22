// qspi_ctrl.sv — full-rate quad-mode QSPI memory controller for the console.
//
// Drives the custom cartridge Pmod: one W25Q128 flash (CS0) + one 8 MB
// APS6404 PSRAM (CS1) on a shared uio bus. `uio[7]` is NOT a chip select
// on this board — it carries the sigma-delta audio out — so there is no
// CS2 here, unlike the stock QSPI Pmod. Pad map the top module applies:
//   SD0=uio[1] SD1=uio[2] SD2=uio[4] SD3=uio[5] SCK=uio[3]
//   CS0(flash)=uio[0] CS1(PSRAM)=uio[6] audio=uio[7]
//
// --------------------------------------------------------------------------
// FULL-RATE clocking (80 ns/byte quad at a 25 MHz system clock — the rate
// spec §2 assumes and the video deadline needs). One data unit (a serial bit
// or a quad nibble) moves per SYSTEM CLOCK, so SCK runs at the clock rate:
//
//   sck = sck_en & ~clk       -- gated, inverted: sck HIGH while clk LOW.
//
// so sck rises at clk's falling edge and falls at clk's rising edge (SPI
// mode 0). Output data is registered on the RISING clk edge → stable through
// the whole clk-low window → sampled cleanly by the slave at sck's rising
// (mid-window). Read data returning from the slave is captured on the
// FALLING clk edge (`rx`), half a clock after the slave launches it — that
// half-clock is the off-chip round-trip budget. The SCK pad is therefore a
// generated clock; the hardening flow constrains it as one. (The proven
// tt-riscv qspi_ctrl ran SCK=clk/2, correct there because CPU XIP has no
// hard deadline; the console's race-the-beam fetch needs the full rate.)
//
// --------------------------------------------------------------------------
// MMIO 1-bit FALLBACK (backlog item 2's hard requirement). `cfg` RESETS TO 0,
// so the chip always comes up in plain 1-bit SPI mode 0, the mode that cannot
// fail. Software opts into quad per device afterwards via the QSPI_CFG MMIO
// register (wired to `cfg`):
//   cfg[0]: flash reads use 6Bh Fast Read Quad Output (cmd+addr+8 dummies
//           serial on SD0, data quad on SD3..0). Needs the flash QE bit,
//           factory-set on the QSPI Pmod's W25Q128JV. A QE-bit misfire can
//           only cost quad flash reads, never the boot — that is the point.
//   cfg[1]: PSRAM reads use EBh (cmd serial, addr quad, 6 waits, data quad)
//           and writes use 38h (cmd serial, addr+data quad).
// With cfg=0 every access is 03h read / 02h write, 1-bit, SD0 only.
//
// --------------------------------------------------------------------------
// Request port — byte-streaming, variable burst (this is the console's model;
// the arbiter multiplexes three of these onto one controller). It adopts
// docs/qspi-arbiter-spec.md §7 but FIXES the two gaps review flagged there:
//   * §7 had no write-data channel — added (`wdata`/`wnext`, streamed).
//   * §7 stole addr[23] for the device select — replaced by a separate `dev`
//     bit so `addr` is a full 24-bit byte address within the selected device.
// `len` is 7 bits so the arbiter can issue up to the ~96 B burst quantum.
// Protocol: master raises `req` with {we,dev,addr,len} and holds it until the
// one-cycle `ack` (transaction COMPLETE, bus idle, CS released — the arbiter
// releases its grant on this).
//   reads : each byte streams out on `rdata` with a one-cycle `rvalid`, in
//           ascending address order; `len` bytes then `ack`.
//   writes: the controller pulses `wnext` once per byte as it consumes it;
//           the master presents that byte on `wdata` while `wnext` is high and
//           advances on the pulse (N pulses for N bytes). PSRAM only — a write
//           with dev=flash is an acknowledged no-op.
//
// --------------------------------------------------------------------------
// DEVICE LIMITS THE ARBITER MUST RESPECT (not enforced here — this block is
// deliberately simple; the align/split owner is the arbiter, review A2/A4):
//   * PSRAM tCEM: CS-low must stay < 8 us or refresh starves and RAM
//     CORRUPTS. At the full rate a quad PSRAM burst of ~90 B ≈ 8 us, so the
//     arbiter caps PSRAM bursts near there (flash has no tCEM). A 1-bit PSRAM
//     burst is 4x slower — cap it near ~20 B.
//   * PSRAM 1 KB page wrap: a linear burst that crosses a 1024-byte page
//     boundary wraps to the page start and re-reads/re-writes it. The arbiter
//     aligns-or-splits PSRAM bursts at 1 KB. Flash reads run continuously.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module qspi_ctrl (
    input  logic        clk,
    input  logic        rst,

    input  logic [1:0]  cfg,        // 0: flash quad read, 1: PSRAM quad rd/wr

    // request port (one master; the arbiter multiplexes)
    input  logic        req,        // hold high until ack
    input  logic        we,         // 0 = read, 1 = write (PSRAM only)
    input  logic        dev,        // 0 = flash (CS0), 1 = PSRAM (CS1)
    input  logic [23:0] addr,       // byte address within the selected device
    input  logic [6:0]  len,        // burst length in bytes, 1..96
    input  logic [7:0]  wdata,      // write byte, sampled while wnext is high
    output logic        wnext,      // one cycle: controller consumed a byte
    output logic        ack,        // one cycle: transaction complete
    output logic [7:0]  rdata,      // streamed read byte
    output logic        rvalid,     // one cycle per rdata byte

    // QSPI pads (cartridge Pmod)
    output logic        sck,        // gated clock: sck = sck_en & ~clk
    output logic [3:0]  sd_out,     // SD3..0 output values
    output logic [3:0]  sd_oe,      // SD3..0 output enables
    input  logic [3:0]  sd_in,      // SD3..0 input values
    output logic        cs_flash_n,
    output logic        cs_ram_n
);

  localparam [3:0] S_IDLE  = 4'd0, S_CMDA = 4'd1, S_QADDR = 4'd2,
                   S_DUMMY = 4'd3, S_WR   = 4'd4, S_QWR   = 4'd5,
                   S_RD    = 4'd6, S_QRD  = 4'd7, S_FIN   = 4'd8;

  logic [3:0]  state;
  logic        sck_en;              // gates the output clock
  logic [39:0] osh;                 // cmd [+ serial addr [+ serial dummies]]
  logic [3:0]  txn;                 // registered quad output nibble
  logic        txb;                 // registered serial output bit
  logic [7:0]  wsh;                 // write-data byte shifter
  logic [7:0]  bsh;                 // read-data byte accumulator
  logic [5:0]  nbits;               // units left in the cmd/addr/dummy phase
  logic [3:0]  sub;                 // bits (serial) or nibbles (quad) in a byte
  logic [6:0]  bytes_left;          // data bytes still to move

  // per-transaction plan, latched in S_IDLE
  logic        we_q, qaddr_q, flq_q;
  logic [6:0]  len_q;

  wire dev_ram  = dev;
  wire fl_quad  = cfg[0] && !dev_ram && !we;   // 6Bh
  wire ram_quad = cfg[1] &&  dev_ram;          // EBh (rd) / 38h (wr)

  logic [7:0] cmd;
  always_comb
    if (we)           cmd = ram_quad ? 8'h38 : 8'h02;
    else if (dev_ram) cmd = ram_quad ? 8'hEB : 8'h03;
    else              cmd = fl_quad  ? 8'h6B : 8'h03;

  // read data captured half a clock after the slave launches it
  logic [3:0] rx;
  always_ff @(negedge clk)
    rx <= sd_in;

  // pad drive: serial phases talk on SD0 only; quad-out phases drive all four;
  // input/dummy phases release the bus (Pmod pull-ups hold WP#/HOLD# high)
  wire q_wr_ph   = (state == S_QWR);
  wire q_addr_ph = (state == S_QADDR);
  wire s_out_ph  = (state == S_CMDA) || (state == S_WR);
  // The 6th (last) quad address nibble is registered into txn as S_QADDR exits;
  // for a read the next state is S_DUMMY (bus released), so that nibble must
  // still be DRIVEN for one more cycle before the turnaround. nbits==7 marks it.
  wire dummy_drv = (state == S_DUMMY) && (nbits == 6'd7);
  assign sd_oe  = (q_wr_ph || q_addr_ph || dummy_drv) ? 4'b1111
                : s_out_ph ? 4'b0001 : 4'b0000;
  assign sd_out = (q_wr_ph || q_addr_ph || dummy_drv) ? txn : {3'b000, txb};

  assign sck = sck_en & ~clk;

  always_ff @(posedge clk)
    if (rst) begin
      state      <= S_IDLE;
      sck_en     <= 1'b0;
      cs_flash_n <= 1'b1;
      cs_ram_n   <= 1'b1;
      ack        <= 1'b0;
      wnext      <= 1'b0;
      rvalid     <= 1'b0;
      rdata      <= 8'd0;
      osh        <= 40'd0;
      txn        <= 4'd0;
      txb        <= 1'b0;
      wsh        <= 8'd0;
      bsh        <= 8'd0;
      nbits      <= 6'd0;
      sub        <= 4'd0;
      bytes_left <= 7'd0;
      we_q       <= 1'b0;
      qaddr_q    <= 1'b0;
      flq_q      <= 1'b0;
      len_q      <= 7'd0;
    end else begin
      ack    <= 1'b0;                          // pulses
      wnext  <= 1'b0;
      rvalid <= 1'b0;

      case (state)
        S_IDLE: begin
          sck_en <= 1'b0;
          if (req && !ack) begin
            if (we && !dev_ram) begin
              ack <= 1'b1;                      // flash is read-only: no-op
            end else begin
              we_q    <= we;
              qaddr_q <= ram_quad;
              flq_q   <= fl_quad;
              len_q   <= len;
              // present cmd bit 7 in the first clocked cycle; osh holds the rest
              txb <= cmd[7];
              if (ram_quad) begin
                osh   <= {cmd[6:0], 33'd0};     // cmd only; address goes quad
                nbits <= 6'd8;
              end else if (fl_quad) begin
                osh   <= {cmd[6:0], addr, 9'd0};// 6Bh + addr + 8 dummy bits
                nbits <= 6'd40;
              end else begin
                osh   <= {cmd[6:0], addr, 9'd0};// 03h/02h + addr
                nbits <= 6'd32;
              end
              cs_flash_n <= dev_ram;
              cs_ram_n   <= ~dev_ram;
              sck_en     <= 1'b1;
              state      <= S_CMDA;
            end
          end
        end

        S_CMDA: begin                           // serial out, MSB on SD0
          txb   <= osh[39];
          osh   <= {osh[38:0], 1'b0};
          nbits <= nbits - 6'd1;
          if (nbits == 6'd1) begin
            if (qaddr_q) begin
              txn   <= addr[23:20];              // first address nibble
              osh   <= {addr[19:0], 20'd0};      // remaining 5 nibbles
              nbits <= 6'd5;
              state <= S_QADDR;
            end else if (we_q) begin
              wsh        <= {wdata[6:0], 1'b0};  // load byte 0, present MSB
              txb        <= wdata[7];
              wnext      <= 1'b1;
              sub        <= 4'd7;
              bytes_left <= len_q;
              state      <= S_WR;
            end else if (flq_q) begin
              sub        <= 4'd2;
              bytes_left <= len_q;
              state      <= S_QRD;
            end else begin
              sub        <= 4'd8;
              bytes_left <= len_q;
              state      <= S_RD;
            end
          end
        end

        S_QADDR: begin                          // quad out: address nibbles
          txn   <= osh[39:36];
          osh   <= {osh[35:0], 4'b0};
          nbits <= nbits - 6'd1;
          if (nbits == 6'd1) begin
            if (we_q) begin
              // txn already holds the last address nibble (osh[39:36]); keep it
              wsh        <= wdata;               // hold byte 0
              wnext      <= 1'b1;
              sub        <= 4'd2;                // S_QWR: 2=hi, 1=lo, 0=boundary
              bytes_left <= len_q;
              state      <= S_QWR;
            end else begin
              nbits <= 6'd7;                     // 1 cycle to drive nib5 + 6 EBh waits
              state <= S_DUMMY;
            end
          end
        end

        S_DUMMY: begin                          // bus released, clock runs
          nbits <= nbits - 6'd1;
          if (nbits == 6'd1) begin
            sub        <= 4'd2;
            bytes_left <= len_q;
            state      <= S_QRD;
          end
        end

        S_WR: begin                             // serial data out, MSB first
          txb <= wsh[7];
          wsh <= {wsh[6:0], 1'b0};
          sub <= sub - 4'd1;
          if (sub == 4'd0) begin                // byte boundary
            if (bytes_left == 7'd1) begin
              sck_en <= 1'b0;
              state  <= S_FIN;
            end else begin
              wsh        <= {wdata[6:0], 1'b0};  // next byte, present MSB
              txb        <= wdata[7];
              wnext      <= 1'b1;
              sub        <= 4'd7;
              bytes_left <= bytes_left - 7'd1;
            end
          end
        end

        S_QWR: begin                            // quad data out, high nibble first
          if (sub == 4'd2) begin                // high nibble of current byte
            txn <= wsh[7:4];
            sub <= 4'd1;
          end else if (sub == 4'd1) begin       // low nibble of current byte
            txn <= wsh[3:0];
            sub <= 4'd0;
          end else begin                        // byte boundary: present next high, no gap
            if (bytes_left == 7'd1) begin
              sck_en <= 1'b0;
              state  <= S_FIN;
            end else begin
              txn        <= wdata[7:4];          // next byte high nibble, from wdata
              wsh        <= wdata;               // hold for its low nibble
              wnext      <= 1'b1;
              sub        <= 4'd1;
              bytes_left <= bytes_left - 7'd1;
            end
          end
        end

        S_RD: begin                             // serial in on SD1, captured in rx
          bsh <= {bsh[6:0], rx[1]};
          sub <= sub - 4'd1;
          if (sub == 4'd1) begin
            rdata  <= {bsh[6:0], rx[1]};
            rvalid <= 1'b1;
            if (bytes_left == 7'd1) begin
              sck_en <= 1'b0;
              state  <= S_FIN;
            end else begin
              sub        <= 4'd8;
              bytes_left <= bytes_left - 7'd1;
            end
          end
        end

        S_QRD: begin                            // quad in, nibble per clock
          bsh <= {bsh[3:0], rx};
          sub <= sub - 4'd1;
          if (sub == 4'd1) begin
            rdata  <= {bsh[3:0], rx};
            rvalid <= 1'b1;
            if (bytes_left == 7'd1) begin
              sck_en <= 1'b0;
              state  <= S_FIN;
            end else begin
              sub        <= 4'd2;
              bytes_left <= bytes_left - 7'd1;
            end
          end
        end

        default: begin                          // S_FIN: deselect + ack
          sck_en     <= 1'b0;
          cs_flash_n <= 1'b1;
          cs_ram_n   <= 1'b1;
          ack        <= 1'b1;
          state      <= S_IDLE;
        end
      endcase
    end

endmodule
