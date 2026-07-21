/*
 * CORDIC-1: standalone sine generator — one TinyTapeout tile.
 *
 * A bit-serial CORDIC engine swept by a 20-bit DDS phase accumulator,
 * streaming sigma-delta sine on one pin (plus a phase-locked square
 * sync on another). Pure instrument: no bus,
 * no host, no configuration beyond the frequency pins. Select the design,
 * release reset, and it plays.
 *
 *   ui[6:0]  frequency code:
 *              0   -> 440 Hz (concert A) — the wake-up default
 *              1..126 -> code * ~68 Hz   (~68 Hz .. ~8.6 kHz)
 *              127 -> ~2 Hz breathe mode (LED bar visibly waves)
 *   ui[7]    reserved (ignored)
 *
 *   uo[7]    sine sigma-delta (TT Audio Pmod position; RC -> analog)
 *   uo[6]    SQUARE sync, phase-locked at the same frequency (scope
 *            trigger + sine-vs-square timbre demo)
 *   uo[5:1]  live sine level bar (offset binary)
 *   uo[0]    ~1.5 Hz heartbeat — the "chip is alive" pilot light
 *
 * Copyright (c) 2026 Joonatan Alanampa
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_joonatanalanampa_cordic (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  wire rst = ~rst_n;

  assign uio_out = 8'h00;
  assign uio_oe  = 8'h00;

  // ---------------------------------------------------------------- DDS
  // fs = clk / 359 (constant-time bit-serial op) = 69.64 kHz at 25 MHz.
  // f = inc / 2^20 * fs:  code<<10 -> ~68 Hz per step.
  wire [6:0] code = ui_in[6:0];
  wire [19:0] dds_inc = (code == 7'd0)   ? 20'd6625   // 440.0 Hz wake-up tone
                      : (code == 7'd127) ? 20'd30     // ~2 Hz breathe mode
                      : {3'b000, code, 10'b0};

  logic [19:0] phase;

  // ---------------------------------------------------------------- engine
  logic        eng_busy;
  logic        eng_done;
  logic signed [15:0] eng_cos, eng_sin;

  cordic u_cordic (
      .clk(clk), .rst(rst),
      .start(!eng_busy), .mode(1'b0),
      .zi(phase[19:4]), .xi(16'sd0), .yi(16'sd0),
      .done(eng_done), .cos_o(eng_cos), .sin_o(eng_sin),
      /* verilator lint_off PINCONNECTEMPTY */
      .zo()
      /* verilator lint_on PINCONNECTEMPTY */
  );

  always_ff @(posedge clk)
    if (rst) begin
      eng_busy <= 1'b0;
      phase    <= 20'd0;
    end else begin
      if (!eng_busy) begin               // issue the next conversion
        eng_busy <= 1'b1;
        phase    <= phase + dds_inc;
      end else if (eng_done)
        eng_busy <= 1'b0;
    end

  // sample latch: hold the wave steady between conversions
  logic signed [15:0] sin_s;
  always_ff @(posedge clk)
    if (rst)           sin_s <= 16'sd0;
    else if (eng_done) sin_s <= eng_sin;

  // ---------------------------------------------------------------- outputs
  // first-order sigma-delta: the carry-out's density IS the sample value
  logic [16:0] sd_sin;
  always_ff @(posedge clk)
    if (rst) sd_sin <= 17'd0;
    else     sd_sin <= {1'b0, sd_sin[15:0]} + {1'b0, sin_s ^ 16'h8000};

  // heartbeat: bit 23 of a free counter = ~1.5 Hz blink at 25 MHz
  logic [23:0] beat;
  always_ff @(posedge clk)
    if (rst) beat <= 24'd0;
    else     beat <= beat + 24'd1;

  // uo[6]: phase-locked SQUARE sync at the output frequency — free (one
  // wire), triggers the scope, and demos sine-vs-square timbre
  assign uo_out = {sd_sin[16],
                   phase[19],
                   sin_s[15:11] ^ 5'b10000,   // LED bar, offset binary
                   beat[23]};

  wire _unused = &{ena, ui_in[7], uio_in, eng_cos, 1'b0};

endmodule
