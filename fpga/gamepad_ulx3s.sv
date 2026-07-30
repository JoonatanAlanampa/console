// gamepad_ulx3s.sv — harness front end for the TT Gamepad Pmod.
//
// This replaces `snes_pad` in the ULX3S harness. The reason is a pin fact, not
// a preference: the raw SNES protocol needs LATCH and CLK as OUTPUTS, and the
// chip's `ui` pins are inputs only, so a bare pad can never be read by the
// silicon. The Gamepad Pmod puts a CH32V003 on the far end as the MASTER — it
// drives latch, clock and data, and we only sample. It is the sole controller
// path that can exist on the real chip.
//
// The protocol handling itself is NOT reimplemented here: `vendor/gamepad_pmod.v`
// is the Pmod designer's own reference receiver, vendored verbatim. This file
// is only the adapter that turns its one-wire-per-button outputs back into the
// packed 12-bit vector the rest of the harness already speaks, using the SAME
// bit order `snes_pad` produced:
//
//   0 B      4 Up     8  A
//   1 Y      5 Down   9  X
//   2 Select 6 Left   10 L
//   3 Start  7 Right  11 R
//
// Because the low 8 bits are unchanged, `ui_in = btn1[7:0]` still carries
// exactly what it did before and `tt_um_joonatanalanampa_console` stays
// bit-identical — info.yaml and the chip's button decode do not move.
//
// Facts taken from the vendored reference (read from the code, not assumed):
//   * data is sampled on the RISING edge of pmod_clk;
//   * a frame is committed on the RISING edge of pmod_latch — latch is a frame
//     TERMINATOR, not a start marker;
//   * in a 24-bit dual frame, CONTROLLER 2 IS TRANSMITTED FIRST (decoder1
//     reads data_reg[11:0], i.e. the last 12 bits shifted in);
//   * an all-1s word means "no controller plugged in", and the decoder forces
//     the buttons to 0 in that case, so an empty port reads as "nothing
//     pressed" rather than "everything pressed".
//
// KNOWN LIMIT, inherited deliberately: the reference commits whatever is in
// the shift register when latch rises; it does not check that a full frame's
// worth of bits arrived. A partial/glitched frame therefore commits shifted
// data rather than being rejected. Matching the reference is the safer choice
// than inventing stricter framing that real hardware might not honour.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module gamepad_ulx3s (
    input  wire         clk,
    input  wire         rst,

    // All three are DRIVEN BY THE PMOD, i.e. inputs to us.
    input  wire         pmod_latch,
    input  wire         pmod_clk,
    input  wire         pmod_data,

    output logic [11:0] btn1,
    output logic [11:0] btn2,
    output logic        present1,
    output logic        present2
);

  wire [1:0] b, y, sel, st, up, dn, lf, rt, a, x, l, r, present;

  gamepad_pmod_dual dual (
      .rst_n      (~rst),
      .clk        (clk),
      .pmod_data  (pmod_data),
      .pmod_clk   (pmod_clk),
      .pmod_latch (pmod_latch),
      .b          (b),
      .y          (y),
      .select     (sel),
      .start      (st),
      .up         (up),
      .down       (dn),
      .left       (lf),
      .right      (rt),
      .a          (a),
      .x          (x),
      .l          (l),
      .r          (r),
      .is_present (present)
  );

  // Repack to the snes_pad bit order (bit 0 = B).
  always_comb begin
    btn1 = {r[0], l[0], x[0], a[0], rt[0], lf[0], dn[0], up[0],
            st[0], sel[0], y[0], b[0]};
    btn2 = {r[1], l[1], x[1], a[1], rt[1], lf[1], dn[1], up[1],
            st[1], sel[1], y[1], b[1]};
  end

  assign present1 = present[0];
  assign present2 = present[1];

endmodule

`default_nettype wire
