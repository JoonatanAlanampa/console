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

    // Onboard GPDI/HDMI socket. Carries the SAME picture as the VGA Pmod, from
    // the same uo_out bits — it does not replace it. This is the path that
    // needs no Pmod and therefore no soldered header, which is why it is the
    // one the console is brought up on. Only the _p pins are declared;
    // LVCMOS33D drives each _n site with the complement.
    output wire  [3:0] gpdi_dp,

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

  // ------------------------------------------------------- HDMI shift clock
  // 125 MHz for the TMDS serialisers: 10 bits per pixel / 2 per DDR clock = 5
  // clocks, 5 x 25 MHz. The SoC stays on the raw 25 MHz oscillator — it closes
  // at 64 MHz and would not survive being moved into the shift domain — so the
  // two clocks are phase-locked but separate, which dvi_tx.sv handles by
  // measuring their offset rather than assuming one.
  wire clk_shift, pll_lock;
  pll_25_125 pll (.clkin(clk_25mhz), .clkout0(clk_shift), .locked(pll_lock));

  // Reset out of a FLOP in the shift domain, never straight off a pad through a
  // LUT: rung 0 measured 5.3 ns on one such hop across the die, against an 8 ns
  // period. Deliberately NOT gated on ldr_done — the video link keeps running
  // while the SoC is held in reset, so the monitor holds its lock.
  logic [1:0] rst_sh_q;
  always_ff @(posedge clk_shift) rst_sh_q <= {rst_sh_q[0], rst || !pll_lock};
  wire rst_shift = rst_sh_q[1];

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

  // ----------------------------------------------------------- frame counter
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

  // ------------------------------------------------------------------- HDMI
  // The console's picture, unchanged, on the GPDI socket. Three things sit
  // between uo_out and a monitor:
  //
  // 1. `de`. The chip has eight output pins and spends every one of them on
  //    RGB222 + syncs, so display-enable never reaches a pad — and DVI needs
  //    it, to know when to send control words instead of pixels. It cannot be
  //    recovered from the syncs, because a black visible pixel and a porch
  //    pixel are the same eight bits. So a SECOND vga_timing runs here, on the
  //    same clock and the same reset as the one inside the SoC. Identical
  //    counters released from identical resets stay in lockstep for ever, and
  //    `sync_err` below is the standing proof that these two do.
  // 2. Colour depth: RGB222 -> 8 bits per channel by REPLICATION, so 2'b11
  //    becomes 8'hFF and not 8'h03.
  // 3. Something to look at before there is a game. `video_en` resets to 0
  //    (src/sysregs.sv), so until software writes SYSCTL the console outputs
  //    black deliberately — and "black screen, syncs fine" is indistinguishable
  //    from half a dozen real faults. So the harness draws a test card until
  //    the SoC emits its first non-black pixel and then gets out of the way,
  //    permanently. Nothing to set; the LEDs say which of the two is on screen.
  wire soc_rst = ~soc_rst_n;

  wire       rep_de, rep_hs, rep_vs;
  wire [9:0] rep_x, rep_y;

  vga_timing rep (
      .clk (clk_25mhz), .rst (soc_rst),
      .hsync (rep_hs), .vsync (rep_vs), .de (rep_de),
      .x (rep_x), .y (rep_y),
      .line_fetch (), .next_y (), .frame_start (), .pre_line ()
  );

  // Sticky: one disagreeing cycle is enough to make `de` a lie, and a `de` that
  // is off by even a pixel shows up as a picture that is subtly shifted or torn
  // — a symptom nobody would attribute to this replica without being told.
  logic sync_err;
  always_ff @(posedge clk_25mhz)
    if (soc_rst)                                          sync_err <= 1'b0;
    else if (rep_hs != uo_out[7] || rep_vs != uo_out[3])  sync_err <= 1'b1;

  wire [1:0] soc_r = {uo_out[0], uo_out[4]};
  wire [1:0] soc_g = {uo_out[1], uo_out[5]};
  wire [1:0] soc_b = {uo_out[2], uo_out[6]};

  logic soc_drew;
  always_ff @(posedge clk_25mhz)
    if (soc_rst)                                soc_drew <= 1'b0;
    else if (rep_de && |{soc_r, soc_g, soc_b})  soc_drew <= 1'b1;

  // The test card: the same eight bars, 2-pixel border and per-frame walking
  // marker that rung 0 put on this monitor, redrawn from the replica's raster
  // so that it also exercises the replica. Border = the whole visible box
  // arrives; marker = frames are advancing, not one still image being held.
  logic [2:0] bar;
  always_comb begin
    if      (rep_x < 10'd80)  bar = 3'd0;
    else if (rep_x < 10'd160) bar = 3'd1;
    else if (rep_x < 10'd240) bar = 3'd2;
    else if (rep_x < 10'd320) bar = 3'd3;
    else if (rep_x < 10'd400) bar = 3'd4;
    else if (rep_x < 10'd480) bar = 3'd5;
    else if (rep_x < 10'd560) bar = 3'd6;
    else                      bar = 3'd7;
  end

  logic [1:0] br, bg, bb;
  always_comb begin
    case (bar)
      3'd0:    {br, bg, bb} = 6'b11_11_11;   // white
      3'd1:    {br, bg, bb} = 6'b11_11_00;   // yellow
      3'd2:    {br, bg, bb} = 6'b00_11_11;   // cyan
      3'd3:    {br, bg, bb} = 6'b00_11_00;   // green
      3'd4:    {br, bg, bb} = 6'b11_00_11;   // magenta
      3'd5:    {br, bg, bb} = 6'b11_00_00;   // red
      3'd6:    {br, bg, bb} = 6'b00_00_11;   // blue
      default: {br, bg, bb} = 6'b00_00_00;   // black
    endcase
  end

  wire card_hi = (rep_x < 10'd2) || (rep_x >= 10'd638) ||
                 (rep_y < 10'd2) || (rep_y >= 10'd478) ||
                 (rep_y[7:0] == frames);
  wire [1:0] card_r = card_hi ? 2'b11 : br;
  wire [1:0] card_g = card_hi ? 2'b11 : bg;
  wire [1:0] card_b = card_hi ? 2'b11 : bb;

  wire [1:0] px_r = soc_drew ? soc_r : card_r;
  wire [1:0] px_g = soc_drew ? soc_g : card_g;
  wire [1:0] px_b = soc_drew ? soc_b : card_b;

  wire phase_err;

  // Syncs come from the CHIP's own pins, not from the replica — the replica
  // supplies `de` and nothing else, so what reaches the monitor is the SoC's
  // raster and sync_err is what says the two agree.
  dvi_tx dvi (
      .clk_pixel (clk_25mhz),
      .clk_shift (clk_shift),
      .rst_shift (rst_shift),
      .r ({4{px_r}}), .g ({4{px_g}}), .b ({4{px_b}}),
      .hsync (uo_out[7]), .vsync (uo_out[3]), .de (rep_de),
      .gpdi_dp (gpdi_dp), .phase_err (phase_err)
  );

  // ------------------------------------------------------- status LEDs
  // Default display, the one to read on the bench:
  //
  //   led[7]  PLL locked                       steady ON  = good
  //   led[6]  dvi_tx phase error (sticky)      OFF        = 5 shift clocks/pixel
  //   led[5]  timing replica mismatch (sticky) OFF        = `de` is trustworthy
  //   led[4]  the SoC has drawn a pixel        OFF until software enables video
  //   led[3:0] frame counter                   blinking   = video is running
  //
  // So the healthy pre-software state is led[7] on, [6:4] off, [3:0] counting,
  // and the monitor showing the test card. led[4] lighting is the handover.
  always_comb begin
    // SW4 = gamepad bring-up aid. The Pmod is a black box with no cable to
    // meter, so "press B, watch LED0" is the only cheap way to prove the
    // controller path end to end before trusting it in a game.
    if (sw[3])                     led = pad_btn[7:0];
    else if (ldr_err || !ldr_done) led = ldr_status;   // loader diagnostics
    else                           led = {pll_lock, phase_err, sync_err,
                                          soc_drew, frames[3:0]};
  end

endmodule

`default_nettype wire
