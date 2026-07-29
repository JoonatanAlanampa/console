`default_nettype none
`timescale 1ns / 1ps

// tb_rehearse — the full power-on chain, minus the wires.
//
// sd_loader and the UNCHANGED tt_um top share one cartridge bus, exactly as
// ulx3s_top wires them: the loader owns the bus and holds the SoC in reset
// until the game is in flash, then hands over. The Pmod row permutation is
// NOT reproduced here — it is copied verbatim from tt-riscv's proven harness
// and would only obscure what this bench is for, which is proving that a real
// game.bin on a real card layout ends up executing.
module tb_rehearse ();

  initial begin
    $dumpfile("tb_rehearse.fst");
    $dumpvars(0, tb_rehearse);
    #1;
  end

  reg clk;
  reg rst;
  reg sd_present;
  reg sd_miso;

  // ---- loader ----
  wire ldr_sd_cs_n, ldr_sd_sck, ldr_sd_mosi;
  wire ldr_cs_n, ldr_sck, ldr_mosi;
  wire ldr_owns, ldr_done, ldr_err;
  wire [7:0] ldr_status;

  // ---- shared cartridge bus, in uio numbering ----
  wire [7:0] bus;                       // the physical wires
  wire [7:0] uio_out, uio_oe, uo_out;

  // 0=CS0 1=SD0 2=SD1 3=SCK 4=SD2 5=SD3 6=CS1 7=AUDIO
  wire [7:0] ld_out = {1'b0, 1'b1, 1'b1, 1'b1, ldr_sck, 1'b0, ldr_mosi, ldr_cs_n};
  wire [7:0] ld_oe  = {1'b1, 1'b1, 1'b1, 1'b1, 1'b1,    1'b0, 1'b1,     1'b1};

  wire [7:0] drv_out = ldr_owns ? ld_out : uio_out;
  wire [7:0] drv_oe  = ldr_owns ? ld_oe  : uio_oe;

  genvar i;
  generate for (i = 0; i < 8; i++) begin : g_bus
    assign bus[i] = drv_oe[i] ? drv_out[i] : 1'bz;
  end endgenerate

  // The memory models live in cocotb and answer on SD1. Both the loader and
  // the SoC leave SD1 an input in 1-bit mode, so this is the only driver.
  reg mem_dq1;
  reg mem_dq1_oe;
  assign bus[2] = mem_dq1_oe ? mem_dq1 : 1'bz;

  sd_loader #(.CLK_HZ(25_000_000)) loader (
      .clk        (clk),
      .rst        (rst),
      .sd_cs_n    (ldr_sd_cs_n),
      .sd_sck     (ldr_sd_sck),
      .sd_mosi    (ldr_sd_mosi),
      .sd_miso    (sd_miso),
      .sd_present (sd_present),
      .cart_cs_n  (ldr_cs_n),
      .cart_sck   (ldr_sck),
      .cart_mosi  (ldr_mosi),
      .cart_miso  (bus[2]),
      .owns_bus   (ldr_owns),
      .done       (ldr_done),
      .error      (ldr_err),
      .status     (ldr_status)
  );

  wire soc_rst_n = ldr_done && !rst;

  tt_um_joonatanalanampa_console console (
      .ui_in   (ui_in),
      .uo_out  (uo_out),
      .uio_in  (bus),
      .uio_out (uio_out),
      .uio_oe  (uio_oe),
      .ena     (1'b1),
      .clk     (clk),
      .rst_n   (soc_rst_n)
  );

  reg [7:0] ui_in;

  // named for the tests
  wire [1:0] vga_r = {uo_out[0], uo_out[4]};
  wire [1:0] vga_g = {uo_out[1], uo_out[5]};
  wire [1:0] vga_b = {uo_out[2], uo_out[6]};
  wire       vsync = uo_out[3];
  wire       hsync = uo_out[7];

endmodule
