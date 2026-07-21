// vga_testpat.sv — stand-in pixel source for the timing core.
//
// This is NOT the console's video engine; it is the placeholder that
// sits in the engine's socket until the tile/sprite scanline renderer
// exists (PLAN.md phase 3). It draws eight colour bars plus a box that
// moves once per frame, which is enough to prove on a real monitor that
// the timing core locks, that the sync polarities are right, and that
// frame_start really happens once per frame.
//
// The socket it defines is the one the real engine must fit: pixels are
// produced combinationally from (x, y) as the beam arrives, with no
// storage between here and the DAC. The real engine will keep one
// scanline of line buffer behind exactly this interface.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module vga_testpat (
    input  wire       clk,
    input  wire       rst,
    input  wire       de,
    input  wire       frame_start,
    input  wire [9:0] x,
    input  wire [9:0] y,
    output wire [1:0] r,
    output wire [1:0] g,
    output wire [1:0] b
);

  // one step per frame, wrapping inside the visible box
  logic [9:0] box_x;
  always_ff @(posedge clk)
    if (rst)              box_x <= 10'd0;
    else if (frame_start) box_x <= (box_x >= 10'd575) ? 10'd0 : box_x + 10'd1;

  wire in_box = (x >= box_x) && (x < box_x + 10'd64) &&
                (y >= 10'd208) && (y < 10'd272);

  wire [2:0] bar = x[9:7];          // 8 bars of 128 px

  assign r = !de ? 2'd0 : in_box ? 2'd3 : {2{bar[2]}};
  assign g = !de ? 2'd0 : in_box ? 2'd3 : {2{bar[1]}};
  assign b = !de ? 2'd0 : in_box ? 2'd3 : {2{bar[0]}};

endmodule

`default_nettype wire
