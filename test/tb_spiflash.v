`default_nettype none
`timescale 1ns / 1ps

// Testbench for spi_flash — the harness-side W25Q128 driver.
module tb_spiflash ();

  initial begin
    $dumpfile("tb_spiflash.fst");
    $dumpvars(0, tb_spiflash);
    #1;
  end

  reg         clk;
  reg         rst;
  reg         start;
  reg  [1:0]  op;
  reg  [23:0] addr;
  reg  [9:0]  len;
  reg  [7:0]  wdata;
  reg         miso;

  wire        wnext, rvalid, busy, done;
  wire  [7:0] rdata;
  wire        cs_n, sck, mosi;

  spi_flash #(.DIV(0)) dut (
      .clk    (clk),
      .rst    (rst),
      .start  (start),
      .op     (op),
      .addr   (addr),
      .len    (len),
      .wnext  (wnext),
      .wdata  (wdata),
      .rvalid (rvalid),
      .rdata  (rdata),
      .busy   (busy),
      .done   (done),
      .cs_n   (cs_n),
      .sck    (sck),
      .mosi   (mosi),
      .miso   (miso)
  );

endmodule
