`default_nettype none
`timescale 1ns / 1ps

// Testbench for sd_loader — microSD card and cartridge flash together.
// Both behavioural parts are driven from cocotb; this is the closest thing to
// the real power-on sequence that exists without the ULX3S in hand.
module tb_sdload ();

  initial begin
    $dumpfile("tb_sdload.fst");
    $dumpvars(0, tb_sdload);
    #1;
  end

  reg  clk;
  reg  rst;
  reg  sd_present;
  reg  sd_miso;
  reg  cart_miso;

  wire sd_cs_n, sd_sck, sd_mosi;
  wire cart_cs_n, cart_sck, cart_mosi;
  wire owns_bus, done, error;
  wire [7:0] status;

  sd_loader #(.CLK_HZ(25_000_000)) dut (
      .clk        (clk),
      .rst        (rst),
      .sd_cs_n    (sd_cs_n),
      .sd_sck     (sd_sck),
      .sd_mosi    (sd_mosi),
      .sd_miso    (sd_miso),
      .sd_present (sd_present),
      .cart_cs_n  (cart_cs_n),
      .cart_sck   (cart_sck),
      .cart_mosi  (cart_mosi),
      .cart_miso  (cart_miso),
      .owns_bus   (owns_bus),
      .done       (done),
      .error      (error),
      .status     (status)
  );

endmodule
