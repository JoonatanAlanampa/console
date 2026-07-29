`default_nettype none
`timescale 1ns / 1ps

// Testbench for sd_spi — the harness-side microSD reader.
//
// The clock is the real 25 MHz, because the divider arithmetic (a ~198 kHz
// init clock derived from CLK_HZ) is part of what is under test: at a fake
// slow clock the DIV_SLOW parameter would collapse to a value the hardware
// never uses. That does mean the 80 wake-up clocks and the init handshake
// take real microseconds of simulated time, which is fine.
module tb_sdspi ();

  initial begin
    $dumpfile("tb_sdspi.fst");
    $dumpvars(0, tb_sdspi);
    #1;
  end

  reg         clk;
  reg         rst;
  reg         init;
  reg         rd;
  reg  [31:0] blk;
  reg         miso;          // driven by the cocotb card model

  wire        ready, busy, err;
  wire        rvalid, rdone;
  wire  [7:0] rdata;
  wire        cs_n, sck, mosi;

  sd_spi #(.CLK_HZ(25_000_000)) dut (
      .clk    (clk),
      .rst    (rst),
      .init   (init),
      .rd     (rd),
      .blk    (blk),
      .ready  (ready),
      .busy   (busy),
      .err    (err),
      .rvalid (rvalid),
      .rdata  (rdata),
      .rdone  (rdone),
      .cs_n   (cs_n),
      .sck    (sck),
      .mosi   (mosi),
      .miso   (miso)
  );

endmodule
