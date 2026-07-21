`default_nettype none
`timescale 1ns / 1ps

// The twin: the fabricated CORDIC-1 RTL and its gate netlist mapped onto
// the self-designed cell library, wired to the same stimulus, running
// side by side. Any difference between uo_out_rtl and uo_out_gl is a
// bug in the library, the mapping, or the cells' behavioural models —
// which is exactly what this harness exists to catch, before an ECP5 or
// a shuttle does.
module tb_cordic_twin ();

  initial begin
    $dumpfile("tb_cordic_twin.fst");
    $dumpvars(0, tb_cordic_twin);
    #1;
  end

  reg        clk;
  reg        rst_n;
  reg        ena;
  reg  [7:0] ui_in;
  reg  [7:0] uio_in;

  wire [7:0] uo_out_rtl, uio_out_rtl, uio_oe_rtl;
  wire [7:0] uo_out_gl,  uio_out_gl,  uio_oe_gl;

  // mismatch flag, so a waveform shows exactly where the twins diverged
  wire       match = (uo_out_rtl === uo_out_gl);

  tt_um_joonatanalanampa_cordic rtl (
      .ui_in  (ui_in),
      .uo_out (uo_out_rtl),
      .uio_in (uio_in),
      .uio_out(uio_out_rtl),
      .uio_oe (uio_oe_rtl),
      .ena    (ena),
      .clk    (clk),
      .rst_n  (rst_n)
  );

  tt_um_joonatanalanampa_cordic_gates gl (
      .ui_in  (ui_in),
      .uo_out (uo_out_gl),
      .uio_in (uio_in),
      .uio_out(uio_out_gl),
      .uio_oe (uio_oe_gl),
      .ena    (ena),
      .clk    (clk),
      .rst_n  (rst_n)
  );

endmodule
