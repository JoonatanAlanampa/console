// snes_pad.sv — SNES/SFC controller reader, N pads on a shared bus.
//
// The SNES pad is a 16-bit parallel-in / serial-out shift register
// (4021-class) that the console clocks itself. The protocol is entirely
// console-driven, so this block is a pure master: nothing about it
// depends on the pad answering, and an unplugged port simply reads as
// "no buttons pressed".
//
//   LATCH  ___----________________________________  12 us high
//   CLK    ---------__--__--__--__ ... __---------  16 pulses, 12 us each
//   DATA   ==< B  >< Y  >< SEL>< ST > ... ========  valid while CLK low
//
// Bit order out of the pad (bit 0 first):
//   0 B      4 Up     8  A      12..15 unused (read 1 = released)
//   1 Y      5 Down   9  X
//   2 Select 6 Left   10 L
//   3 Start  7 Right  11 R
//
// DATA is ACTIVE LOW at the connector (pressed = 0). This block inverts,
// so `btn` is active high: bit set = button held.
//
// Timing is generated from CLK_HZ, not hard-coded counts, so the same
// RTL is correct on the 25 MHz ULX3S prototype and on whatever the TT
// mux is clocked at. The original console polls once per video frame;
// POLL_HZ defaults to 60 for exactly that reason, and `strobe` pulses
// one cycle when a fresh sample lands in `btn` — the natural place for
// the game loop to read input is the vertical blank right after it.
//
// PIN BUDGET: LATCH and CLK are shared by every pad (that is how a real
// multi-tap-free two-port console wires it), so N pads cost N+2 pins:
// one pad = 3 pins, two pads = 4. See PLAN.md — the early plan line
// "2 pads, 3 ui pins" was counting one pad's worth of pins.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module snes_pad #(
    parameter int NPADS  = 2,          // controllers on the shared clock
    parameter int CLK_HZ = 25_000_000,
    parameter int POLL_HZ = 60         // sample rate (once per video frame)
) (
    input  wire                  clk,
    input  wire                  rst,        // synchronous, active high

    // connector side
    output logic                 pad_latch,  // to every pad
    output logic                 pad_clk,    // to every pad
    input  wire  [NPADS-1:0]     pad_data,   // one per pad, active low

    // core side. btn is FLAT (pad p occupies bits [12*p +: 12]) rather
    // than a packed 2-D array: Icarus cannot index a packed array with a
    // loop variable, and a flat bus is also what the SoC's register
    // slice wants anyway.
    output logic [NPADS*12-1:0]  btn,        // active high, see bit map above
    output logic                 strobe      // 1 cycle when btn updates
);

  // ---------------------------------------------------------------- timing
  // 12 us at both ends of the protocol: the latch pulse width and the
  // clock half-period. Rounded up, never down — the pad tolerates slow.
  localparam int TICK_CYCLES = (CLK_HZ + 83_332) / 83_333;   // ~12 us
  localparam int POLL_CYCLES = CLK_HZ / POLL_HZ;
  localparam int TW = $clog2(TICK_CYCLES);
  localparam int PW = $clog2(POLL_CYCLES);

  // A full read is 1 latch tick + 16 clock periods (2 ticks each) = 33
  // ticks, i.e. ~400 us — comfortably inside a 16.7 ms frame.
  localparam int NTICKS = 1 + 32;

  logic [PW-1:0] poll_cnt;
  logic [TW-1:0] tick_cnt;
  logic [5:0]    tick_idx;    // 0..32
  logic          running;
  logic          tick_end;

  assign tick_end = (tick_cnt == TW'(TICK_CYCLES - 1));

  // ---------------------------------------------------------------- phase
  // Phase decode. tick 0 = latch high. From tick 1 on, each pair of
  // ticks is one clock period: even tick = CLK low (pad drives, we
  // sample), odd tick = CLK high (pad advances on the rising edge).
  wire in_latch = running && (tick_idx == 6'd0);
  wire clk_low  = running && (tick_idx != 6'd0) && (tick_idx[0] == 1'b1);

  // Sampling and capture pulses, shared by every pad: the bus is common,
  // so all pads shift on the same tick and latch on the same tick.
  //
  // Sample in the MIDDLE of the CLK-low tick, not at either end. The pad
  // advances its shift register on the RISING edge of CLK, so sampling
  // at the end of the low period races the pad's own output change —
  // measured in simulation before this was moved: the read came back
  // all-zeros because the sample landed exactly on the edge. Half a tick
  // (~6 us) of margin on both sides is what a real console leaves.
  wire sample_en = running && clk_low && (tick_cnt == TW'(TICK_CYCLES / 2));
  wire capture   = running && tick_end && (tick_idx == 6'(NTICKS - 1));

  always_ff @(posedge clk) begin
    strobe <= 1'b0;

    if (rst) begin
      poll_cnt  <= '0;
      tick_cnt  <= '0;
      tick_idx  <= '0;
      running   <= 1'b0;
      pad_latch <= 1'b0;
      pad_clk   <= 1'b1;     // idle high, as the console leaves it
    end else begin
      pad_latch <= in_latch;
      pad_clk   <= !clk_low;

      if (!running) begin
        // wait out the frame period, then start a read
        if (poll_cnt == PW'(POLL_CYCLES - 1)) begin
          poll_cnt <= '0;
          running  <= 1'b1;
          tick_idx <= '0;
          tick_cnt <= '0;
        end else begin
          poll_cnt <= poll_cnt + PW'(1);
        end
      end else begin
        poll_cnt <= poll_cnt + PW'(1);   // keep the frame clock free-running

        if (!tick_end) begin
          tick_cnt <= tick_cnt + TW'(1);
        end else begin
          tick_cnt <= '0;
          if (capture) begin
            running <= 1'b0;
            strobe  <= 1'b1;
          end else begin
            tick_idx <= tick_idx + 6'd1;
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------- pads
  // One shift register per pad, all driven by the shared pulses above.
  // Sampling happens at the END of every CLK-low tick: the pad has had a
  // full 12 us to settle, and it will shift on the rising edge we are
  // about to produce. The 16 sampling ticks are the odd ones, 1..31, so
  // by tick 32 — the final CLK-high half — the shifter is full: bit 0 is
  // the first bit out of the pad (B), bit 15 the last.
  genvar p;
  generate
    for (p = 0; p < NPADS; p++) begin : g_pad
      logic [15:0] shifter;
      always_ff @(posedge clk)
        if (rst)            shifter <= '0;
        else if (sample_en) shifter <= {~pad_data[p], shifter[15:1]};

      always_ff @(posedge clk)
        if (rst)          btn[12*p+:12] <= '0;
        else if (capture) btn[12*p+:12] <= shifter[11:0];  // 12..15 unused
    end
  endgenerate

endmodule

`default_nettype wire
