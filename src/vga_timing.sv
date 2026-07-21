// vga_timing.sv — 640x480@60 timing generator, race-the-beam flavoured.
//
// Ordinary VGA timing plus the three things a framebuffer-less console
// actually needs: an early warning before the visible line starts, a
// pulse at the start of the blanking window (when the memory bus is
// free for the next line's fetch), and the number of the line that is
// about to be drawn — not the one being drawn now. A framebuffer design
// needs none of these; a console that generates pixels per scanline as
// the beam arrives needs all three.
//
//   Mode (VESA):  800 x 525 total, 640 x 480 visible, both syncs NEGATIVE
//     H:  visible 640 | front 16 | sync 96 | back 48
//     V:  visible 480 | front 10 | sync  2 | back 33
//
//   Pixel clock: 25.175 MHz nominal. The prototype runs 25.000 MHz
//   (ULX3S crystal) -> 59.52 Hz, inside every monitor's tolerance and
//   the same choice the TT VGA Pmod projects make. Nothing here assumes
//   the exact frequency; all counts are parameters.
//
// The fetch contract, which docs/qspi-arbiter-spec.md budgets against:
//   `line_fetch` pulses once per line, at the start of horizontal
//   blanking, carrying `next_y` = the line whose pixels must be ready
//   before the NEXT visible window opens. The fetch engine therefore has
//   H_FRONT + H_SYNC + H_BACK = 160 pixel clocks (6.4 us at 25 MHz) to
//   land a full line of tile data. That budget is the reason the video
//   path gets absolute priority in the arbiter.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module vga_timing #(
    parameter int H_VIS = 640, H_FRONT = 16, H_SYNC = 96, H_BACK = 48,
    parameter int V_VIS = 480, V_FRONT = 10, V_SYNC =  2, V_BACK = 33,
    parameter bit H_POL = 1'b0,   // sync level during the sync pulse
    parameter bit V_POL = 1'b0,
    parameter int PRE   = 8       // cycles of early warning before a line
) (
    input  wire        clk,       // pixel clock
    input  wire        rst,       // synchronous, active high

    output logic       hsync,
    output logic       vsync,
    output logic       de,        // display enable: inside the visible box
    output logic [9:0] x,         // 0..H_VIS-1 while de
    output logic [9:0] y,         // 0..V_VIS-1 while de or in v-blank ahead

    // race-the-beam hooks
    output logic       line_fetch, // 1 cycle: h-blank opened, fetch next_y
    output logic [9:0] next_y,     // line to prepare (valid at line_fetch)
    output logic       frame_start,// 1 cycle at the top of the frame
    output logic       pre_line    // high for PRE cycles before de rises
);

  localparam int H_TOTAL = H_VIS + H_FRONT + H_SYNC + H_BACK;
  localparam int V_TOTAL = V_VIS + V_FRONT + V_SYNC + V_BACK;

  logic [9:0] hcnt, vcnt;

  wire h_last = (hcnt == 10'(H_TOTAL - 1));
  wire v_last = (vcnt == 10'(V_TOTAL - 1));

  always_ff @(posedge clk)
    if (rst) begin
      hcnt <= '0;
      vcnt <= '0;
    end else if (h_last) begin
      hcnt <= '0;
      vcnt <= v_last ? 10'd0 : vcnt + 10'd1;
    end else begin
      hcnt <= hcnt + 10'd1;
    end

  // Counters run over the whole raster; x/y are only meaningful inside
  // the visible box, which is what `de` is for.
  assign x  = hcnt;
  assign y  = vcnt;
  assign de = (hcnt < 10'(H_VIS)) && (vcnt < 10'(V_VIS));

  assign hsync = ((hcnt >= 10'(H_VIS + H_FRONT)) &&
                  (hcnt <  10'(H_VIS + H_FRONT + H_SYNC))) ? H_POL : ~H_POL;
  assign vsync = ((vcnt >= 10'(V_VIS + V_FRONT)) &&
                  (vcnt <  10'(V_VIS + V_FRONT + V_SYNC))) ? V_POL : ~V_POL;

  // Fetch window opens the instant the visible pixels of this line end.
  // next_y wraps at the last line of the frame so the first fetch of a
  // frame is line 0 — the engine never has to special-case the top —
  // and the pulse is suppressed during vertical blanking, where the
  // "next line" is not a real line. The engine therefore sees exactly
  // V_VIS fetch pulses per frame, one per visible line.
  assign next_y      = v_last ? 10'd0 : (vcnt + 10'd1);
  assign line_fetch  = (hcnt == 10'(H_VIS)) && (next_y < 10'(V_VIS));
  assign frame_start = (hcnt == 10'd0) && (vcnt == 10'd0);
  assign pre_line    = (hcnt >= 10'(H_TOTAL - PRE));

endmodule

`default_nettype wire
