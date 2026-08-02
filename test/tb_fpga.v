`default_nettype none
`timescale 1ns / 1ps

// tb_fpga -- ulx3s_top through its actual pins.
//
// Every other suite drives tt_um_joonatanalanampa_console or a sub-block
// directly. Until this bench, NOTHING had ever elaborated ulx3s_top, so the
// header permutation, the three orientation straps, the loader/SoC bus mux and
// the tristates were unverified logic sitting between a working SoC and the
// connectors. tb_rehearse says as much in its own header: "The Pmod row
// permutation is NOT reproduced here". This is the bench that reproduces it.
//
// THE POINT, AND WHY A SIMPLER BENCH WOULD PROVE NOTHING. ulx3s_top's
// permutation is self-consistent: bus_out and bus_in are built from the same
// algebra, so if that algebra were wrong, a model that reached the flash
// THROUGH the gateware's own mapping would still round-trip perfectly and pass.
// The only way to catch it is a model that knows the real pinout independently.
// Hence `seat_flip`: the testbench decides how the Pmod is physically seated,
// the cocotb memory model uses only that, and sw[0] is the gateware's separate
// GUESS at it. Setting the two to disagree must break the boot -- which is what
// test_wrong_cartridge_strap_does_not_boot checks.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

module tb_fpga ();

  initial begin
    $dumpfile("tb_fpga.fst");
    $dumpvars(0, tb_fpga);
    #1;
  end

  reg        clk = 1'b0;
  reg  [6:0] btn;
  reg  [3:0] sw;
  reg  [2:0] pad_gp, pad_gn;
  reg        sd_cdn;

  wire [7:0] led;
  wire [3:0] vga_gp, vga_gn;
  wire [3:0] audio_l, audio_r;
  wire       ftdi_rxd, wifi_gpio0;
  wire       sd_clk, sd_cmd;

  // tri1 models PULLMODE=UP from ulx3s.lpf. An undriven cartridge line really
  // does read high on the board, and for a chip select that means "deselected"
  // -- the safe reading, and the one the pre-reset X window depends on.
  tri1 [3:0] pmod_gp;
  tri1 [3:0] pmod_gn;
  tri1 [3:0] sd_d;

  // ---- how the Pmod is PHYSICALLY seated. Set by the test, never by the
  // ---- gateware. sw[0] is the design's separate guess at this same fact.
  reg seat_flip = 1'b0;

  // The cartridge memory answers on uio[2] (SD1). Which physical wire that is
  // follows from the seating alone:
  //   not flipped: uio[b] -> gp[3-b] for b<4  =>  uio[2] is gp[1]
  //   flipped:     uio[b] -> gn[3-b] for b<4  =>  uio[2] is gn[1]
  reg mem_dq1    = 1'b1;
  reg mem_dq1_oe = 1'b0;
  assign pmod_gp[1] = (!seat_flip && mem_dq1_oe) ? mem_dq1 : 1'bz;
  assign pmod_gn[1] = ( seat_flip && mem_dq1_oe) ? mem_dq1 : 1'bz;

  // ---- the SD card answers on sd_d[0]; the other three are driven by the top
  reg sd_miso = 1'b1;
  assign sd_d[0] = sd_miso;

  // Single-bit aliases so the card model can watch these without indexing an
  // inout vector through the VPI.
  wire sd_cs_n = sd_d[3];
  wire sd_sck  = sd_clk;
  wire sd_mosi = sd_cmd;

  // Both header rows as ONE net, so the cartridge model can wait on "anything
  // on J1 moved". It has to be edge-triggered rather than sampled once per
  // system clock: once the loader hands over, qspi_ctrl drives SCK at clk/2,
  // and a once-per-clock sampler aliases against it -- it sits there seeing a
  // constant SCK while the bus is in fact running flat out. That failure looks
  // exactly like a dead SoC, which is the sort of thing that costs a day on
  // the bench, so it is worth a wire to make impossible here.
  wire [7:0] hdr = {pmod_gn, pmod_gp};

  ulx3s_top top (
      .clk_25mhz  (clk),
      .btn        (btn),
      .sw         (sw),
      .led        (led),
      .ftdi_rxd   (ftdi_rxd),
      .wifi_gpio0 (wifi_gpio0),
      .pmod_gp    (pmod_gp),
      .pmod_gn    (pmod_gn),
      .vga_gp     (vga_gp),
      .vga_gn     (vga_gn),
      .audio_l    (audio_l),
      .audio_r    (audio_r),
      .pad_gp     (pad_gp),
      .pad_gn     (pad_gn),
      .sd_clk     (sd_clk),
      .sd_cmd     (sd_cmd),
      .sd_d       (sd_d),
      .sd_cdn     (sd_cdn)
  );

endmodule

`default_nettype wire
