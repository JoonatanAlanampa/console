`default_nettype none
`timescale 1ns / 1ps

// Testbench for the race-the-beam timing core plus the placeholder
// pixel source that will later be replaced by the tile engine.
module tb_vga ();

  initial begin
    $dumpfile("tb_vga.fst");
    $dumpvars(0, tb_vga);
    #1;
  end

  reg        clk;
  reg        rst;

  wire       hsync, vsync, de;
  wire [9:0] x, y;
  wire       line_fetch, frame_start, pre_line;
  wire [9:0] next_y;
  wire [1:0] r, g, b;

  vga_timing dut (
      .clk        (clk),
      .rst        (rst),
      .hsync      (hsync),
      .vsync      (vsync),
      .de         (de),
      .x          (x),
      .y          (y),
      .line_fetch (line_fetch),
      .next_y     (next_y),
      .frame_start(frame_start),
      .pre_line   (pre_line)
  );

  vga_testpat pat (
      .clk        (clk),
      .rst        (rst),
      .de         (de),
      .frame_start(frame_start),
      .x          (x),
      .y          (y),
      .r          (r),
      .g          (g),
      .b          (b)
  );

endmodule
