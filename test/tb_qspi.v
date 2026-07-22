`default_nettype none
`timescale 1ns / 1ps

// Testbench top for the quad-mode QSPI controller. cocotb drives the
// request port and, through test_qspi.py's bit-level flash/PSRAM models,
// the SD lines; it reads back the streamed data and the pad bus.
module tb_qspi ();

  initial begin
    $dumpfile("tb_qspi.fst");
    $dumpvars(0, tb_qspi);
    #1;
  end

  reg         clk;
  reg         rst;
  reg  [1:0]  cfg;

  reg         req;
  reg         we;
  reg         dev;
  reg  [23:0] addr;
  reg  [4:0]  len;
  reg  [7:0]  wdata;
  wire        wnext;
  wire        ack;
  wire [7:0]  rdata;
  wire        rvalid;

  wire        sck;
  wire [3:0]  sd_out;
  wire [3:0]  sd_oe;
  reg  [3:0]  sd_in;
  wire        cs_flash_n;
  wire        cs_ram_n;

  qspi_ctrl dut (
      .clk        (clk),
      .rst        (rst),
      .cfg        (cfg),
      .req        (req),
      .we         (we),
      .dev        (dev),
      .addr       (addr),
      .len        (len),
      .wdata      (wdata),
      .wnext      (wnext),
      .ack        (ack),
      .rdata      (rdata),
      .rvalid     (rvalid),
      .sck        (sck),
      .sd_out     (sd_out),
      .sd_oe      (sd_oe),
      .sd_in      (sd_in),
      .cs_flash_n (cs_flash_n),
      .cs_ram_n   (cs_ram_n)
  );

endmodule
