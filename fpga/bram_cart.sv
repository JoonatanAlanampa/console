`default_nettype none
//
// bram_cart.sv — the cartridge, in fabric. HARNESS ONLY.
//
// RUNG 2: a console that needs no Pmod. This is a QSPI *device* that sits where
// the Cartridge Pmod would sit, on the same eight uio wires, backed by the
// ULX3S's own block RAM. The chip does not know the difference: it still boots
// by XIP from "flash" address 0, the video engine still races the beam against
// the same shared bus, and qspi_arbiter still arbitrates three masters onto one
// controller. Emulating the device rather than bypassing it is the whole point
// — the arbiter and the race-the-beam fetch ARE the engineering of this
// project, and an ifdef that swapped qspi_ctrl for a BRAM port would mean they
// never ran on hardware at all.
//
// WHAT IS MODELLED, AND WHAT IS DELIBERATELY NOT
// ----------------------------------------------
// Implemented: 03h read (flash and PSRAM) and 02h write (PSRAM), 1-bit SPI
// mode 0. That is the whole set the console actually uses — `cfg` resets to 0
// and sw/game.c:89 writes `SYSCTL = VIDEO_EN`, leaving QSPI in 1-bit safe mode.
//
// NOT implemented: 6Bh / EBh / 38h quad, and every erase/program opcode the
// real W25Q128 has. Those raise `bad_cmd`, which is wired to an LED. A model
// that silently returned zeroes for an opcode it did not understand would look
// exactly like working hardware running a broken program, and the whole reason
// this file exists is to make the memory boring so that everything else can be
// suspected instead.
//
// THE ONE HARD PIECE: 03h HAS NO DUMMY CYCLES
// -------------------------------------------
// The controller sends 8 command bits then 24 address bits, and captures the
// first data bit in the very next cycle (qspi_ctrl.sv S_CMDA -> S_RD; `rx` is
// sampled every negedge). A real W25Q128 manages that with an asynchronous
// array. Block RAM cannot: an address presented at the edge that receives the
// last address bit only produces data one edge LATER, which is one edge too
// late.
//
// So the arrays are 16 bits wide — TWO byte-lanes read in parallel — and the
// read is issued one edge EARLY, at the edge receiving bit 31, when addr[23:1]
// is already known and only addr[0] is still in flight. Both candidate bytes
// therefore arrive in time and addr[0] picks between them combinationally.
// That is the entire reason for the width; nothing else here needs 16 bits.
//
// TIMING CONVENTION. sck = sck_en & ~clk (see qspi_ctrl.sv), so exactly one SPI
// bit moves per system clock and this model needs no clock derived from sck —
// which would be a gated non-global clock and a bad idea in fabric. The
// controller registers its output at posedge clk; this model samples at the
// NEXT posedge, and registers its own output at posedge so the controller's
// negedge capture sees it settled half a clock later. That is bit-for-bit the
// mode-0 relationship the real part has.
//
// ADDRESS ALIASING IS A FEATURE, NOT AN OVERSIGHT. Both devices decode only as
// many low address bits as they have bytes, so the 8 MB PSRAM window aliases
// onto RAM_BYTES. This is what lets ONE sw/game.bin run unmodified on both the
// real cartridge and this model: crt0.S sets sp = 0x01800000, whose first push
// lands at 0x017FFFFC, which aliases to the top of this window and grows down
// toward the tile map at offset 0x010000 — exactly the layout link.ld
// describes, 64x smaller. No software change, no second linker script, no
// FPGA-only binary that could drift from the one the cartridge boots.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

module bram_cart #(
    parameter int FLASH_BYTES = 65536,     // >= sw/game.bin (36864) + headroom
    parameter int RAM_BYTES   = 131072,    // MUST cover TILEMAP_BASE (0x010000)
    // Two files, not one path plus a suffix: concatenating a string parameter
    // works in both toolchains right up until it does not, and a $readmemh that
    // silently finds nothing leaves an array of X that looks like a dead CPU.
    parameter     FLASH_LO    = "fpga/build/game_lo.hex",
    parameter     FLASH_HI    = "fpga/build/game_hi.hex"
) (
    input  wire       clk,
    input  wire       rst,

    // the cartridge bus, exactly as the Pmod would see it
    input  wire       cs_flash_n,          // uio[0]
    input  wire       cs_ram_n,            // uio[6]
    input  wire [3:0] sd_out,              // SD3..SD0 driven by the controller
    input  wire [3:0] sd_oe,
    output wire [3:0] sd_in,               // SD3..SD0 driven back

    output reg        bad_cmd              // sticky: unimplemented opcode seen
);

  localparam int FWORDS = FLASH_BYTES / 2;
  localparam int RWORDS = RAM_BYTES   / 2;
  localparam int FAW    = $clog2(FWORDS);
  localparam int RAW    = $clog2(RWORDS);
  localparam int AW     = (FAW > RAW) ? FAW : RAW;

  localparam [7:0] OP_READ = 8'h03;
  localparam [7:0] OP_PROG = 8'h02;

  wire sel_ram = ~cs_ram_n;
  wire sel     = ~cs_flash_n | ~cs_ram_n;
  wire mosi    = sd_out[0];

  // ------------------------------------------------------------- the arrays
  // Two 8-bit lanes rather than one 16-bit array: byte writes then need no
  // byte-enable trickery, and both still read in parallel off one word address.
  // Even byte addresses live in the _lo lane, odd in _hi.
  (* no_rw_check *) reg [7:0] fl_lo [0:FWORDS-1];
  (* no_rw_check *) reg [7:0] fl_hi [0:FWORDS-1];
  (* no_rw_check *) reg [7:0] rm_lo [0:RWORDS-1];
  (* no_rw_check *) reg [7:0] rm_hi [0:RWORDS-1];

  // The flash image. Generated from sw/game.bin by tools/mkhex.py; see the
  // builders, which regenerate it rather than trusting a committed copy.
  initial $readmemh(FLASH_LO, fl_lo, 0, FWORDS-1);
  initial $readmemh(FLASH_HI, fl_hi, 0, FWORDS-1);

  // PSRAM comes up undefined on the real part too, and crt0 zeroes .bss before
  // anything reads it. Zeroing here keeps SIMULATION X-free, which matters
  // because an X on MISO propagates into the CPU and looks like a bug in the
  // CPU rather than an unwritten memory.
  //
  // ⚠ SIMULATION ONLY, and the guard is not optional: yosys UNROLLS initial
  // loops, so 65536 iterations turns a two-line loop into a synthesis run that
  // does not finish in five minutes. Measured, not feared. On hardware the
  // ECP5's block RAM powers up zeroed anyway, so the guard costs nothing.
`ifndef SYNTHESIS
  integer i;
  initial for (i = 0; i < RWORDS; i = i + 1) begin
    rm_lo[i] = 8'd0;
    rm_hi[i] = 8'd0;
  end
`endif

  // ---------------------------------------------------------- receive shifter
  reg [31:0] sr;         // command + address, MSB first
  reg [5:0]  bc;         // bits received so far this transaction (saturates)
  reg [23:0] nxt_byte;   // byte address of the NEXT byte to move
  reg [7:0]  osh;        // outgoing byte, MSB already on the wire
  reg [7:0]  ish;        // incoming write byte
  reg [2:0]  dcnt;       // bits left in the current data byte
  reg        miso;
  reg        in_rd, in_wr;

  wire [5:0] bc_next = (bc == 6'd63) ? 6'd63 : bc + 6'd1;

  // The read address. At the edge receiving bit 31 it is formed from the bits
  // already in flight -- that one-edge head start is what makes a zero-dummy
  // 03h read possible at all. Everywhere else it tracks the burst.
  wire [22:0] pre_word = {sr[21:0], mosi};
  wire [22:0] rd_word  = (bc == 6'd30) ? pre_word : nxt_byte[23:1];

  // ⚠ EACH ARRAY MUST OWN ITS OUTPUT REGISTER. Writing this as one register fed
  // by a mux of two memory reads --
  //     q_lo <= sel_ram ? rm_lo[...] : fl_lo[...];
  // -- costs the whole design: neither memory can then absorb the flop into its
  // own output register, so yosys needs an ASYNCHRONOUS read port, DP16KD does
  // not have one, and all four arrays fall back to distributed LUT RAM. Measured
  // on this design: 1 DP16KD, 16468 TRELLIS_DPR16X4 and 74840 LUT4s, against an
  // 85F that only has 83640 LUT4s. Register first, mux afterwards.
  reg [7:0] fq_lo, fq_hi, rq_lo, rq_hi;
  reg       sel_ram_q;

  always @(posedge clk) begin
    fq_lo     <= fl_lo[rd_word[FAW-1:0]];
    fq_hi     <= fl_hi[rd_word[FAW-1:0]];
    rq_lo     <= rm_lo[rd_word[RAW-1:0]];
    rq_hi     <= rm_hi[rd_word[RAW-1:0]];
    sel_ram_q <= sel_ram;                  // the mux select must age with the data
  end

  wire [7:0] q_lo = sel_ram_q ? rq_lo : fq_lo;
  wire [7:0] q_hi = sel_ram_q ? rq_hi : fq_hi;

  // Byte select for the FIRST byte uses addr[0] straight off the wire, because
  // at that edge it has not been registered anywhere yet.
  wire [7:0] first_byte = mosi     ? q_hi : q_lo;
  wire [7:0] next_byte  = nxt_byte[0] ? q_hi : q_lo;

  // ------------------------------------------------------------------- FSM
  always @(posedge clk) begin
    if (rst) begin
      sr <= 32'd0; bc <= 6'd0; nxt_byte <= 24'd0;
      osh <= 8'd0; ish <= 8'd0; dcnt <= 3'd0;
      miso <= 1'b1; in_rd <= 1'b0; in_wr <= 1'b0;
      bad_cmd <= 1'b0;
    end else if (!sel) begin
      // CS high: the transaction is over. bad_cmd is sticky and survives.
      bc    <= 6'd0;
      in_rd <= 1'b0;
      in_wr <= 1'b0;
      dcnt  <= 3'd0;
      miso  <= 1'b1;
    end else begin
      sr <= {sr[30:0], mosi};
      bc <= bc_next;

      if (bc < 6'd31) begin
        // command + address, bits 1..31: nothing to do but shift
      end else if (bc == 6'd31) begin
        // THIS EDGE RECEIVES BIT 32, the last address bit. Everything that
        // makes a zero-dummy read work happens right here.
        //
        // sr currently holds bits 1..31, so bit 1 is sr[30]: the opcode is
        // sr[30:23] and addr[23:1] is sr[22:0], with addr[0] still on the wire.
        case (sr[30:23])
          OP_READ: begin
            in_rd    <= 1'b1;
            miso     <= first_byte[7];
            osh      <= {first_byte[6:0], 1'b0};
            dcnt     <= 3'd7;
            nxt_byte <= {sr[22:0], mosi} + 24'd1;
          end
          OP_PROG: begin
            if (sel_ram) begin
              in_wr    <= 1'b1;
              dcnt     <= 3'd7;
              nxt_byte <= {sr[22:0], mosi};
            end else begin
              bad_cmd <= 1'b1;           // 02h to the read-only flash
            end
          end
          default: bad_cmd <= 1'b1;
        endcase
      end else begin
        // ------------------------------------------------------- data phase
        if (in_rd) begin
          if (dcnt != 3'd0) begin
            miso <= osh[7];
            osh  <= {osh[6:0], 1'b0};
            dcnt <= dcnt - 3'd1;
          end else begin
            miso     <= next_byte[7];
            osh      <= {next_byte[6:0], 1'b0};
            dcnt     <= 3'd7;
            nxt_byte <= nxt_byte + 24'd1;
          end
        end else if (in_wr) begin
          ish <= {ish[6:0], mosi};
          if (dcnt != 3'd0) begin
            dcnt <= dcnt - 3'd1;
          end else begin
            dcnt     <= 3'd7;
            nxt_byte <= nxt_byte + 24'd1;
          end
        end
      end
    end
  end

  // Write port. Separated from the FSM so the array has exactly one write
  // statement per lane, which is what yosys wants to see to infer a BRAM.
  wire       wr_stb  = sel && in_wr && (dcnt == 3'd0) && !rst;
  wire [7:0] wr_data = {ish[6:0], mosi};
  wire [RAW-1:0] wr_word = nxt_byte[RAW:1];

  always @(posedge clk) begin
    if (wr_stb && !nxt_byte[0]) rm_lo[wr_word] <= wr_data;
    if (wr_stb &&  nxt_byte[0]) rm_hi[wr_word] <= wr_data;
  end

  // ---------------------------------------------------------------- the bus
  // SD2/SD3 are the flash's WP#/HOLD# and are held high by pull-ups on the real
  // Pmod; SD0 is master-driven. Only SD1 carries anything back.
  assign sd_in[0] = sd_oe[0] ? sd_out[0] : 1'b1;
  assign sd_in[1] = sd_oe[1] ? sd_out[1] : miso;
  assign sd_in[2] = sd_oe[2] ? sd_out[2] : 1'b1;
  assign sd_in[3] = sd_oe[3] ? sd_out[3] : 1'b1;

endmodule
`default_nettype wire
