`default_nettype none
`timescale 1ns / 1ps

// Testbench for gamepad_ulx3s — the harness front end for the TT Gamepad Pmod.
//
// The clock is the real 25 MHz because the CDC is part of what is under test:
// the Pmod clocks at ~100 kHz, i.e. ~250 system clocks per bit, and the
// vendored receiver relies on 2-flop synchronizers plus edge detection to
// cross that boundary. Running a fake fast clock would hide exactly the
// sampling behaviour worth checking.
//
// cocotb drives latch/clk/data as the Pmod MASTER would. Note the framing
// lesson already paid for elsewhere in this suite: the master owns the edges,
// so the model asserts data BEFORE raising the clock and holds it past the
// falling edge, which is what the real Pmod does.
module tb_gamepad ();

  initial begin
    $dumpfile("tb_gamepad.fst");
    $dumpvars(0, tb_gamepad);
    #1;
  end

  reg clk;
  reg rst;
  reg pmod_latch;
  reg pmod_clk;
  reg pmod_data;

  wire [11:0] btn1, btn2;
  wire        present1, present2;

  gamepad_ulx3s dut (
      .clk        (clk),
      .rst        (rst),
      .pmod_latch (pmod_latch),
      .pmod_clk   (pmod_clk),
      .pmod_data  (pmod_data),
      .btn1       (btn1),
      .btn2       (btn2),
      .present1   (present1),
      .present2   (present2)
  );

endmodule
