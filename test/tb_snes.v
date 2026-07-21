`default_nettype none
`timescale 1ns / 1ps

// Testbench for snes_pad. The clock is deliberately slow (1 MHz) so a
// full 16-bit read is a few hundred cycles instead of ten thousand; the
// protocol timing is derived from CLK_HZ, so this exercises the same
// state machine the 25 MHz build uses.
module tb_snes ();

  initial begin
    $dumpfile("tb_snes.fst");
    $dumpvars(0, tb_snes);
    #1;
  end

  localparam int NPADS = 2;

  reg         clk;
  reg         rst;

  // One driver per pad. They must be SEPARATE handles: two cocotb pad
  // models sharing one vector would race on the read-modify-write of
  // the bus and silently overwrite each other's bits (measured — it
  // reads as "pad 0 pressed nothing").
  reg         pad_data0;
  reg         pad_data1;
  wire [NPADS-1:0] pad_data = {pad_data1, pad_data0};

  wire        pad_latch;
  wire        pad_clk;
  wire [NPADS*12-1:0] btn;
  wire        strobe;

  // named slices, one per pad, so the tests read like the pinout
  wire [11:0] btn0 = btn[11:0];
  wire [11:0] btn1 = btn[23:12];

  snes_pad #(
      .NPADS  (NPADS),
      .CLK_HZ (1_000_000),
      .POLL_HZ(1_000)
  ) dut (
      .clk      (clk),
      .rst      (rst),
      .pad_latch(pad_latch),
      .pad_clk  (pad_clk),
      .pad_data (pad_data),
      .btn      (btn),
      .strobe   (strobe)
  );

endmodule
