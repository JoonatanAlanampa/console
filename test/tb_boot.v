`default_nettype none
`timescale 1ns / 1ps

// Full-system boot testbench: the tt_um console top with the cartridge Pmod
// modelled by test_boot.py's bit-level flash/PSRAM on the packed uio bus.
module tb_boot ();

  initial begin
    $dumpfile("tb_boot.fst");
    $dumpvars(0, tb_boot);
    #1;
  end

  reg        clk, rst_n, ena;
  reg  [7:0] ui_in;
  wire [7:0] uo_out;
  reg  [7:0] uio_in;
  wire [7:0] uio_out, uio_oe;

  // taps so the cocotb bus model can trigger on sck / CS edges of the packed bus
  wire sck_tap = uio_out[3];
  wire csf_tap = uio_out[0];
  wire csr_tap = uio_out[6];

  tt_um_joonatanalanampa_console dut (
      .ui_in (ui_in), .uo_out (uo_out), .uio_in (uio_in),
      .uio_out (uio_out), .uio_oe (uio_oe),
      .ena (ena), .clk (clk), .rst_n (rst_n)
  );

endmodule
