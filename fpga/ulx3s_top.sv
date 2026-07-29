// ulx3s_top.sv — the console prototype on the ULX3S 85F.
//
// Runs the UNCHANGED `tt_um_joonatanalanampa_console` against real hardware:
// the custom Cartridge Pmod on the J1 header, a Tiny VGA Pmod on J2, a SNES
// controller on three GPIO pins, and a game loaded from the onboard microSD
// slot. Everything the chip cannot do lives out here in the harness, so the
// module that gets hardened is byte-identical to the module that runs here.
//
// WHAT IS HARNESS-ONLY, AND WHY
// -----------------------------
//  * microSD. The chip has no free pin (8 uo = VGA, 8 uio = cartridge, ui is
//    input-only), so `sd_loader` copies the game into the cartridge flash
//    while the SoC is held in reset and then hands the bus over. The SoC boots
//    by XIP from flash address 0 exactly as silicon will.
//  * SNES decoding. The protocol needs LATCH and CLK as OUTPUTS and the chip's
//    `ui` pins are inputs only — which is why `info.yaml` maps ui to eight
//    plain buttons and why the TT Gamepad Pmod is master-side. Here the
//    harness runs `snes_pad` and presents eight decoded buttons to `ui_in`.
//    Consequence: A, X, L and R are not reachable through an 8-bit input
//    budget. ui_in carries B, Y, Select, Start, Up, Down, Left, Right.
//
// HEADER ORIENTATION. A Pmod can be seated either way round on the J1/J2
// blocks, so the gp/gn row assignment is selectable at runtime rather than
// guessed: SW1 flips the cartridge mapping, SW2 flips the VGA one. Set them to
// whatever the cartridge bring-up bitstream reported. This is the same trick
// tt-riscv/fpga uses, and it exists because a reversed Pmod is otherwise a
// silent failure that looks like dead gateware.
//
// LEDs: the loader's status byte until it releases the bus, then a frame
// counter driven by VSYNC — a visibly blinking LED8 means video is running.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module ulx3s_top (
    input  wire        clk_25mhz,
    input  wire  [6:0] btn,
    input  wire  [3:0] sw,
    output logic [7:0] led,
    output logic       ftdi_rxd,
    output logic       wifi_gpio0,

    // J1 header: Cartridge Pmod (flash + PSRAM + audio)
    inout  wire  [3:0] pmod_gp,
    inout  wire  [3:0] pmod_gn,

    // J2 header: Tiny VGA Pmod (outputs only)
    output logic [3:0] vga_gp,
    output logic [3:0] vga_gn,

    // SNES controller (3 signals + the header's 3V3/GND)
    output logic       pad_latch,
    output logic       pad_clk,
    input  wire        pad_data,

    // onboard microSD, in SPI mode
    output logic       sd_clk,
    output logic       sd_cmd,               // MOSI
    inout  wire  [3:0] sd_d,                 // d[0] = MISO, d[3] = CS
    input  wire        sd_cdn                // card detect, active low
);

  assign wifi_gpio0 = 1'b1;                  // keep the ESP32 booted
  assign ftdi_rxd   = 1'b1;                  // UART idle: uo is all VGA

  // ------------------------------------------------------- reset
  logic [15:0] por = '0;
  always_ff @(posedge clk_25mhz) if (!(&por)) por <= por + 16'd1;

  wire por_done = &por;
  wire rst      = !(btn[0] && por_done);     // BTN0 (PWR) is active low

  // ------------------------------------------------------- microSD loader
  logic ldr_sd_cs_n, ldr_sd_sck, ldr_sd_mosi;
  logic ldr_cs_n, ldr_sck, ldr_mosi;
  logic ldr_owns, ldr_done, ldr_err;
  logic [7:0] ldr_status;

  wire [7:0] bus_in;                          // read back off the J1 header
  wire cart_miso = bus_in[2];                 // SD1

  sd_loader #(.CLK_HZ(25_000_000)) loader (
      .clk        (clk_25mhz),
      .rst        (rst),
      .sd_cs_n    (ldr_sd_cs_n),
      .sd_sck     (ldr_sd_sck),
      .sd_mosi    (ldr_sd_mosi),
      .sd_miso    (sd_d[0]),
      .sd_present (~sd_cdn),
      .cart_cs_n  (ldr_cs_n),
      .cart_sck   (ldr_sck),
      .cart_mosi  (ldr_mosi),
      .cart_miso  (cart_miso),
      .owns_bus   (ldr_owns),
      .done       (ldr_done),
      .error      (ldr_err),
      .status     (ldr_status)
  );

  // SD card pins. In SPI mode d[1] and d[2] are unused and must not float
  // low, so they are driven high; d[3] is chip select.
  assign sd_clk = ldr_sd_sck;
  assign sd_cmd = ldr_sd_mosi;
  assign sd_d[3] = ldr_sd_cs_n;
  assign sd_d[2] = 1'b1;
  assign sd_d[1] = 1'b1;
  assign sd_d[0] = 1'bz;                      // MISO, driven by the card

  // ------------------------------------------------------- SNES controller
  wire [11:0] pad_btn;

  snes_pad #(
      .NPADS  (1),
      .CLK_HZ (25_000_000),
      .POLL_HZ(60)
  ) pad (
      .clk      (clk_25mhz),
      .rst      (rst),
      .pad_latch(pad_latch),
      .pad_clk  (pad_clk),
      .pad_data (pad_data),
      .btn      (pad_btn),
      .strobe   ()
  );

  // B, Y, Select, Start, Up, Down, Left, Right — the low 8 of the pad's 12.
  wire [7:0] ui_in = pad_btn[7:0];

  // ------------------------------------------------------- the console chip
  wire [7:0] uo_out, uio_out, uio_oe;
  wire soc_rst_n = ldr_done && !rst;          // held in reset until the load ends

  tt_um_joonatanalanampa_console console (
      .ui_in   (ui_in),
      .uo_out  (uo_out),
      .uio_in  (bus_in),
      .uio_out (uio_out),
      .uio_oe  (uio_oe),
      .ena     (1'b1),
      .clk     (clk_25mhz),
      .rst_n   (soc_rst_n)
  );

  // ------------------------------------------------------- cartridge bus mux
  // uio numbering: 0=CS0 1=SD0 2=SD1 3=SCK 4=SD2 5=SD3 6=CS1 7=AUDIO.
  // While loading, SD2/SD3 are the flash's WP#/HOLD# and MUST be high, CS1
  // holds the PSRAM deselected, and SD1 is an input carrying MISO.
  wire [7:0] ld_out = {1'b0, 1'b1, 1'b1, 1'b1, ldr_sck, 1'b0, ldr_mosi, ldr_cs_n};
  wire [7:0] ld_oe  = {1'b1, 1'b1, 1'b1, 1'b1, 1'b1,    1'b0, 1'b1,     1'b1};

  wire [7:0] bus_out = ldr_owns ? ld_out : uio_out;
  wire [7:0] bus_oe  = ldr_owns ? ld_oe  : uio_oe;

  // Header permutation, orientation-selectable (see the note at the top).
  //   mapping A: gp[n] = uio[3-n], gn[n] = uio[7-n]; mapping B swaps the rows.
  wire cart_map_b = sw[0];
  generate for (genvar n = 0; n < 4; n++) begin : g_cart
    wire [2:0] gpi = cart_map_b ? 3'(7 - n) : 3'(3 - n);
    wire [2:0] gni = cart_map_b ? 3'(3 - n) : 3'(7 - n);
    assign pmod_gp[n] = bus_oe[gpi] ? bus_out[gpi] : 1'bz;
    assign pmod_gn[n] = bus_oe[gni] ? bus_out[gni] : 1'bz;
  end endgenerate

  generate for (genvar k = 0; k < 8; k++) begin : g_cart_in
    assign bus_in[k] = ((k < 4) ^ cart_map_b) ? pmod_gp[3 - (k & 3)]
                                              : pmod_gn[3 - (k & 3)];
  end endgenerate

  // ------------------------------------------------------- VGA Pmod
  // Same 2x6 geometry as the cartridge, so the same algebra — outputs only.
  wire vga_map_b = sw[1];
  generate for (genvar n = 0; n < 4; n++) begin : g_vga
    wire [2:0] pi = vga_map_b ? 3'(7 - n) : 3'(3 - n);
    wire [2:0] ni = vga_map_b ? 3'(3 - n) : 3'(7 - n);
    assign vga_gp[n] = uo_out[pi];
    assign vga_gn[n] = uo_out[ni];
  end endgenerate

  // ------------------------------------------------------- status LEDs
  // Tiny VGA Pmod bit order is {HSYNC,B0,G0,R0,VSYNC,B1,G1,R1}, so uo_out[3]
  // is VSYNC — one pulse per frame, i.e. a free liveness signal.
  wire vsync = uo_out[3];
  logic vsync_q;
  logic [7:0] frames;

  always_ff @(posedge clk_25mhz) begin
    vsync_q <= vsync;
    if (rst)                        frames <= '0;
    else if (vsync && !vsync_q)     frames <= frames + 8'd1;
  end

  always_comb begin
    if (ldr_err || !ldr_done) led = ldr_status;   // loader diagnostics
    else                      led = frames;       // blinking = video is alive
  end

endmodule

`default_nettype wire
