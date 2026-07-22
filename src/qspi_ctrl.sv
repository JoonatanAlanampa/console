// qspi_ctrl.sv — quad-mode QSPI memory controller for the console.
//
// Drives the custom cartridge Pmod: one W25Q128 flash (CS0) + one 8 MB
// APS6404 PSRAM (CS1) on a shared uio bus. `uio[7]` is NOT a chip select
// on this board — it carries the sigma-delta audio out — so there is no
// CS2 here, unlike the stock QSPI Pmod. Pad map the top module applies:
//   SD0=uio[1] SD1=uio[2] SD2=uio[4] SD3=uio[5] SCK=uio[3]
//   CS0(flash)=uio[0] CS1(PSRAM)=uio[6] audio=uio[7]
//
// --------------------------------------------------------------------------
// MMIO 1-bit FALLBACK (backlog item 2's hard requirement).
// `cfg` RESETS TO 0, so the chip always comes up in plain 1-bit SPI mode 0,
// the mode that cannot fail. Software opts into quad per device afterwards
// by writing the CPU's QSPI_CFG MMIO register (wired to `cfg`):
//   cfg[0]: flash reads use 6Bh Fast Read Quad Output (cmd+addr+8 dummies
//           serial on SD0, data quad on SD3..0). Needs the flash QE bit,
//           factory-set on the QSPI Pmod's W25Q128JV. A QE-bit misfire can
//           only cost quad flash reads, never the boot — that is the point.
//   cfg[1]: PSRAM reads use EBh (cmd serial, addr quad, 6 waits, data quad)
//           and writes use 38h (cmd serial, addr+data quad).
// With cfg=0 every access is 03h read / 02h write, 1-bit, SD0 only.
//
// --------------------------------------------------------------------------
// Request port — byte-streaming, variable burst (this is the console's
// model; the arbiter multiplexes three of these onto one controller). It
// ADOPTS docs/qspi-arbiter-spec.md §7 but FIXES the two gaps that review
// flagged there:
//   * §7 had no write-data channel — added (`wdata`/`wnext`, streamed).
//   * §7 stole addr[23] for the device select, truncating the 16 MB flash
//     to 8 MB — replaced by a separate `dev` bit so `addr` is a full 24-bit
//     byte address within the selected device.
// Protocol: master raises `req` with {we,dev,addr,len} and holds it until
// the one-cycle `ack` (transaction COMPLETE, bus idle, CS released — the
// arbiter releases its grant on this, exactly like tt-riscv's mem_arbiter).
//   reads : each byte streams out on `rdata` with a one-cycle `rvalid`, in
//           ascending address order; `len` bytes then `ack`.
//   writes: the controller pulses `wnext` once per byte as it consumes it;
//           the master must present that byte on `wdata` while `wnext` is
//           high and advance on the pulse (N pulses for N bytes). PSRAM only
//           — a write with dev=flash is an acknowledged no-op.
//
// --------------------------------------------------------------------------
// DEVICE LIMITS THE ARBITER MUST RESPECT (not enforced here — this block is
// deliberately simple; the align/split owner is the arbiter, review A2/A4):
//   * PSRAM tCEM: CS-low must stay < 8 us or refresh starves and RAM
//     CORRUPTS. A quad PSRAM burst of len<=16 is ~4.2 us (safe). A 1-bit
//     PSRAM burst of len<=16 is up to ~12.8 us @25MHz — OVER tCEM — so
//     1-bit PSRAM bursts must be capped at <= 8 bytes. Flash has no tCEM.
//   * PSRAM 1 KB page wrap: a linear burst that crosses a 1024-byte page
//     boundary wraps to the page start and re-reads/re-writes it. The
//     arbiter must align-or-split PSRAM bursts at 1 KB. Flash reads (03h/
//     6Bh) run continuously across the array with no such wrap.
//
// SCK = clk/2 throughout. Pad-side command/timing logic is ported verbatim
// from the proven tt-riscv qspi_ctrl (40 rv32ui riscv-tests green through
// its XIP path, both SPI modes); only the request port is byte-streamed.
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
    input  logic [4:0]  len,        // burst length in bytes, 1..16
    input  logic [7:0]  wdata,      // write byte, sampled while wnext is high
    output logic        wnext,      // one cycle: controller consumed a byte
    output logic        ack,        // one cycle: transaction complete
    output logic [7:0]  rdata,      // streamed read byte
    output logic        rvalid,     // one cycle per rdata byte

    // QSPI pads (cartridge Pmod)
    output logic        sck,
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
  logic [39:0] osh;        // cmd [+ serial addr [+ serial dummies]]
  logic [7:0]  wsh;        // write-data byte shifter
  logic [7:0]  bsh;        // read-data byte accumulator
  logic [5:0]  nbits;      // bits/nibbles left in the cmd/addr/dummy phase
  logic [3:0]  sub;        // bits (serial) or nibbles (quad) left in a byte
  logic [4:0]  bytes_left; // data bytes still to move

  // per-transaction phase plan, latched in S_IDLE
  logic        we_q;       // write transaction
  logic        qaddr_q;    // address goes out quad (EBh/38h)
  logic        flq_q;      // 6Bh flash quad read: serial cmd+addr, quad data
  logic [4:0]  len_q;

  wire dev_ram  = dev;
  wire fl_quad  = cfg[0] && !dev_ram && !we;   // 6Bh
  wire ram_quad = cfg[1] &&  dev_ram;          // EBh (rd) / 38h (wr)

  logic [7:0] cmd;
  always_comb
    if (we)           cmd = ram_quad ? 8'h38 : 8'h02;
    else if (dev_ram) cmd = ram_quad ? 8'hEB : 8'h03;
    else              cmd = fl_quad  ? 8'h6B : 8'h03;

  // pad drive: serial phases talk on SD0 only; quad-out phases drive all
  // four; input/dummy phases release the bus (Pmod pull-ups hold the flash's
  // WP#/HOLD# deasserted while SD2/SD3 float in serial mode)
  wire q_addr_ph = (state == S_QADDR);
  wire q_wr_ph   = (state == S_QWR);
  wire s_wr_ph   = (state == S_WR);
  wire quad_out   = q_addr_ph || q_wr_ph;
  wire serial_out = (state == S_IDLE) || (state == S_CMDA) || s_wr_ph
                 || (state == S_FIN);
  assign sd_oe  = quad_out ? 4'b1111 : serial_out ? 4'b0001 : 4'b0000;
  assign sd_out = q_addr_ph ? osh[39:36]
                : q_wr_ph   ? wsh[7:4]
                : s_wr_ph   ? {3'b000, wsh[7]}
                :             {3'b000, osh[39]};

  always_ff @(posedge clk)
    if (rst) begin
      state      <= S_IDLE;
      sck        <= 1'b0;
      cs_flash_n <= 1'b1;
      cs_ram_n   <= 1'b1;
      ack        <= 1'b0;
      wnext      <= 1'b0;
      rvalid     <= 1'b0;
      rdata      <= 8'd0;
      osh        <= 40'd0;
      wsh        <= 8'd0;
      bsh        <= 8'd0;
      nbits      <= 6'd0;
      sub        <= 4'd0;
      bytes_left <= 5'd0;
      we_q       <= 1'b0;
      qaddr_q    <= 1'b0;
      flq_q      <= 1'b0;
      len_q      <= 5'd0;
    end else begin
      ack    <= 1'b0;                          // pulses
      wnext  <= 1'b0;
      rvalid <= 1'b0;

      case (state)
        S_IDLE:
          if (req && !ack) begin
            if (we && !dev_ram) begin
              ack <= 1'b1;                      // flash is read-only: no-op
            end else begin
              we_q    <= we;
              qaddr_q <= ram_quad;              // EBh/38h: address goes quad
              flq_q   <= fl_quad;               // 6Bh: serial addr, quad data
              len_q   <= len;
              if (ram_quad) begin
                osh   <= {cmd, 32'd0};          // cmd only; address goes quad
                nbits <= 6'd8;
              end else if (fl_quad) begin
                osh   <= {cmd, addr, 8'd0};     // 6Bh + addr + 8 dummy bits
                nbits <= 6'd40;
              end else begin
                osh   <= {cmd, addr, 8'd0};     // 03h/02h + addr
                nbits <= 6'd32;
              end
              cs_flash_n <= dev_ram;
              cs_ram_n   <= ~dev_ram;
              sck        <= 1'b0;
              state      <= S_CMDA;
            end
          end

        S_CMDA:                                 // serial out, MSB on SD0
          if (!sck) sck <= 1'b1;                // rising edge: slave samples
          else begin                            // falling edge: next bit out
            sck   <= 1'b0;
            osh   <= {osh[38:0], 1'b0};
            nbits <= nbits - 6'd1;
            if (nbits == 6'd1) begin
              if (qaddr_q) begin
                osh   <= {addr, 16'd0};          // 6 nibbles, high first
                nbits <= 6'd6;
                state <= S_QADDR;
              end else if (we_q) begin
                wsh        <= wdata;             // load byte 0
                wnext      <= 1'b1;
                sub        <= 4'd8;
                bytes_left <= len_q;
                state      <= S_WR;
              end else if (flq_q) begin
                bsh        <= 8'd0;
                sub        <= 4'd2;              // quad: 2 nibbles/byte
                bytes_left <= len_q;
                state      <= S_QRD;
              end else begin
                bsh        <= 8'd0;
                sub        <= 4'd8;              // serial: 8 bits/byte
                bytes_left <= len_q;
                state      <= S_RD;
              end
            end
          end

        S_QADDR:                                // quad out: address nibbles
          if (!sck) sck <= 1'b1;
          else begin
            sck   <= 1'b0;
            osh   <= {osh[35:0], 4'b0};
            nbits <= nbits - 6'd1;
            if (nbits == 6'd1) begin
              if (we_q) begin
                wsh        <= wdata;             // load byte 0
                wnext      <= 1'b1;
                sub        <= 4'd2;
                bytes_left <= len_q;
                state      <= S_QWR;
              end else begin
                nbits <= 6'd6;                   // EBh: 6 wait cycles
                state <= S_DUMMY;
              end
            end
          end

        S_DUMMY:                                // bus released, clock runs
          if (!sck) sck <= 1'b1;
          else begin
            sck   <= 1'b0;
            nbits <= nbits - 6'd1;
            if (nbits == 6'd1) begin
              bsh        <= 8'd0;
              sub        <= 4'd2;
              bytes_left <= len_q;
              state      <= S_QRD;
            end
          end

        S_WR:                                   // serial data out, MSB first
          if (!sck) sck <= 1'b1;
          else begin
            sck <= 1'b0;
            wsh <= {wsh[6:0], 1'b0};
            sub <= sub - 4'd1;
            if (sub == 4'd1) begin              // byte done
              if (bytes_left == 5'd1) state <= S_FIN;
              else begin
                wsh        <= wdata;             // load next byte
                wnext      <= 1'b1;
                sub        <= 4'd8;
                bytes_left <= bytes_left - 5'd1;
              end
            end
          end

        S_QWR:                                  // quad data out, high nibble first
          if (!sck) sck <= 1'b1;
          else begin
            sck <= 1'b0;
            wsh <= {wsh[3:0], 4'b0};
            sub <= sub - 4'd1;
            if (sub == 4'd1) begin
              if (bytes_left == 5'd1) state <= S_FIN;
              else begin
                wsh        <= wdata;
                wnext      <= 1'b1;
                sub        <= 4'd2;
                bytes_left <= bytes_left - 5'd1;
              end
            end
          end

        S_RD:                                   // serial in on SD1
          if (!sck) begin                       // rising edge: sample
            sck <= 1'b1;
            bsh <= {bsh[6:0], sd_in[1]};
            sub <= sub - 4'd1;
            if (sub == 4'd1) begin              // byte complete this sample
              rdata      <= {bsh[6:0], sd_in[1]};
              rvalid     <= 1'b1;
              if (bytes_left == 5'd1) state <= S_FIN;
              else begin
                sub        <= 4'd8;
                bytes_left <= bytes_left - 5'd1;
              end
            end
          end else
            sck <= 1'b0;

        S_QRD:                                  // quad in, nibble per edge
          if (!sck) begin
            sck <= 1'b1;
            bsh <= {bsh[3:0], sd_in};
            sub <= sub - 4'd1;
            if (sub == 4'd1) begin
              rdata      <= {bsh[3:0], sd_in};
              rvalid     <= 1'b1;
              if (bytes_left == 5'd1) state <= S_FIN;
              else begin
                sub        <= 4'd2;
                bytes_left <= bytes_left - 5'd1;
              end
            end
          end else
            sck <= 1'b0;

        default: begin                          // S_FIN: deselect + ack
          sck        <= 1'b0;
          cs_flash_n <= 1'b1;
          cs_ram_n   <= 1'b1;
          ack        <= 1'b1;
          state      <= S_IDLE;
        end
      endcase
    end

endmodule
