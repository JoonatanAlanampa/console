`default_nettype none
`timescale 1ns / 1ps

// Testbench for the chiptune audio block (standalone).
module tb_audio ();

  initial begin
    $dumpfile("tb_audio.fst");
    $dumpvars(0, tb_audio);
    #1;
  end

  reg         clk;
  reg         rst;
  reg  [63:0] v_freq;          // 4 x 16
  reg  [7:0]  v_wave;          // 4 x 2
  reg  [15:0] v_vol;           // 4 x 4
  wire [7:0]  sample;
  wire        audio_out;

  audio dut (
      .clk (clk), .rst (rst),
      .v_freq (v_freq), .v_wave (v_wave), .v_vol (v_vol),
      .sample (sample), .audio_out (audio_out)
  );

endmodule
