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
//  * Controller decoding. A raw SNES pad needs LATCH and CLK as OUTPUTS and
//    the chip's `ui` pins are inputs only — which is why `info.yaml` maps ui
//    to eight plain buttons and why the TT Gamepad Pmod is master-side: it
//    drives all three wires and the chip only samples, so it is the sole
//    controller path that can exist on silicon. The harness runs
//    `gamepad_ulx3s` (over the vendored reference receiver) and presents eight
//    decoded buttons to `ui_in`. `src/snes_pad.sv` is no longer instantiated
//    but is kept: it is verified, and it documents the raw pad protocol.
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

    // Onboard 3.5 mm jack (4-bit R2R ladder per channel). This carries the
    // SAME audio as the cartridge Pmod's amp+jack — it does not replace it.
    output logic [3:0] audio_l,
    output logic [3:0] audio_r,

    // TT Gamepad Pmod block on gp/gn[8..10]. All three signals are INPUTS:
    // the Pmod's CH32V003 is the master and drives latch, clock and data.
    // SW3 picks which physical row carries them, exactly as SW1/SW2 do.
    input  wire [2:0]  pad_gp,
    input  wire [2:0]  pad_gn,

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

  // USE_CARD_DETECT stays 0: ulx3s_v20.lpf marks sd_cdn (N5) "not connected",
  // so gating on it would mean never reading the card on this board. The pin
  // is still wired in below so it costs nothing to flip once measured.
  sd_loader #(.CLK_HZ(25_000_000), .USE_CARD_DETECT(1'b0)) loader (
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
  wire [11:0] pad_btn, pad_btn2;

  // SW3 = gamepad row mapping, same ambiguity and same remedy as SW1/SW2.
  wire pad_map_b   = sw[2];
  wire pmod_latch  = pad_map_b ? pad_gp[0] : pad_gn[0];
  wire pmod_clk    = pad_map_b ? pad_gp[1] : pad_gn[1];
  wire pmod_data   = pad_map_b ? pad_gp[2] : pad_gn[2];

  gamepad_ulx3s pad (
      .clk        (clk_25mhz),
      .rst        (rst),
      .pmod_latch (pmod_latch),
      .pmod_clk   (pmod_clk),
      .pmod_data  (pmod_data),
      .btn1       (pad_btn),
      .btn2       (pad_btn2),
      .present1   (),
      .present2   ()
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

  // ------------------------------------------------------- audio, both jacks
  // The console has ONE audio source: the sigma-delta bit on uio[7]. It goes
  // to the cartridge Pmod (which carries the real RC filter, amp and jack —
  // the path the silicon will use) AND, in parallel, to the ULX3S's own 3.5 mm
  // jack. Tapping `bus_out[7]` rather than `uio_out[7]` means both jacks carry
  // the identical waveform and both go silent while the loader owns the bus.
  //
  // The onboard jack is a 4-bit R2R ladder per channel; driving all four bits
  // from the one-bit stream gives full-scale output and lets the speakers do
  // the low-pass filtering, exactly as the Pmod's RC network does. If it is
  // too hot, drive fewer of the low bits to attenuate. Mono source, so both
  // channels get the same signal.
  wire audio_bit = bus_out[7];
  assign audio_l = {4{audio_bit}};
  assign audio_r = {4{audio_bit}};

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
    // SW4 = gamepad bring-up aid. The Pmod is a black box with no cable to
    // meter, so "press B, watch LED0" is the only cheap way to prove the
    // controller path end to end before trusting it in a game.
    if (sw[3])                     led = pad_btn[7:0];
    else if (ldr_err || !ldr_done) led = ldr_status;   // loader diagnostics
    else                           led = frames;       // blinking = video alive
  end

endmodule

`default_nettype wire
