// tt_um_joonatanalanampa_console.sv — the console chip's top: the vendored
// TinyRV32 core + the word/byte adapter + the integrated SoC, mapped to the
// TinyTapeout pins.
//
//   uo  = Tiny VGA Pmod (RGB222 + syncs)
//   uio = cartridge Pmod  (flash + PSRAM QSPI, audio on uio[7])
//   ui  = 8 input buttons (direct GPIO -- the SNES serial reader needs
//         latch/clk OUTPUT pins this pinout has none of; a future controller
//         Pmod can add them)
//
// QSPI mode is owned by sysregs SYSCTL.cfg (software writes the MMIO carve-out);
// the core's own QSPI_CFG output is left unconnected.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module tt_um_joonatanalanampa_console (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  wire rst = ~rst_n;

  // ---- core <-> adapter (word interface) ----
  wire        if_req;
  wire [22:0] if_addr;
  wire        if_ack;
  wire [31:0] if_rdata, if_rdata2;
  wire        d_req, d_we;
  wire [22:0] d_addr;
  wire [31:0] d_wdata;
  wire [3:0]  d_be;
  wire        d_ack;
  wire [31:0] d_rdata;

  rv32_core #(.NREGS(16)) core (
      .clk (clk), .rst (rst),
      .halted (), .led (), .uart_txd (), .gpio_in (ui_in), .qspi_cfg (),
      .if_req (if_req), .if_addr (if_addr), .if_ack (if_ack),
      .if_rdata (if_rdata), .if_rdata2 (if_rdata2),
      .d_req (d_req), .d_we (d_we), .d_addr (d_addr), .d_wdata (d_wdata),
      .d_be (d_be), .d_ack (d_ack), .d_rdata (d_rdata)
  );

  // ---- adapter <-> soc (byte-streaming + MMIO) ----
  wire        f_req, f_dev;
  wire [23:0] f_addr;
  wire [6:0]  f_len;
  wire        f_ack, f_rvalid;
  wire [7:0]  f_rdata;
  wire        cd_req, cd_we, cd_dev;
  wire [23:0] cd_addr;
  wire [6:0]  cd_len;
  wire [7:0]  cd_wdata;
  wire        cd_ack, cd_wnext, cd_rvalid;
  wire [7:0]  cd_rdata;
  wire        cm_sel, cm_we;
  wire [5:0]  cm_addr;
  wire [31:0] cm_wdata, cm_rdata;

  cpu_adapter adapt (
      .clk (clk), .rst (rst),
      .if_req (if_req), .if_addr (if_addr), .if_ack (if_ack),
      .if_rdata (if_rdata), .if_rdata2 (if_rdata2),
      .d_req (d_req), .d_we (d_we), .d_addr (d_addr), .d_wdata (d_wdata),
      .d_be (d_be), .d_ack (d_ack), .d_rdata (d_rdata),
      .f_req (f_req), .f_dev (f_dev), .f_addr (f_addr), .f_len (f_len),
      .f_ack (f_ack), .f_rvalid (f_rvalid), .f_rdata (f_rdata),
      .cd_req (cd_req), .cd_we (cd_we), .cd_dev (cd_dev), .cd_addr (cd_addr),
      .cd_len (cd_len), .cd_wdata (cd_wdata), .cd_ack (cd_ack),
      .cd_wnext (cd_wnext), .cd_rvalid (cd_rvalid), .cd_rdata (cd_rdata),
      .cm_sel (cm_sel), .cm_we (cm_we), .cm_addr (cm_addr),
      .cm_wdata (cm_wdata), .cm_rdata (cm_rdata)
  );

  // ---- the integrated SoC ----
  wire [1:0] vga_r, vga_g, vga_b;
  wire       hsync, vsync, audio_out;
  wire       sck, cs_flash_n, cs_ram_n;
  wire [3:0] sd_out, sd_oe, sd_in;

  console_soc soc (
      .clk (clk), .rst (rst),
      .f_req (f_req), .f_dev (f_dev), .f_addr (f_addr), .f_len (f_len),
      .f_ack (f_ack), .f_rvalid (f_rvalid), .f_rdata (f_rdata),
      .d_req (cd_req), .d_we (cd_we), .d_dev (cd_dev), .d_addr (cd_addr),
      .d_len (cd_len), .d_wdata (cd_wdata), .d_ack (cd_ack), .d_wnext (cd_wnext),
      .d_rvalid (cd_rvalid), .d_rdata (cd_rdata),
      .m_sel (cm_sel), .m_we (cm_we), .m_addr (cm_addr), .m_wdata (cm_wdata),
      .m_rdata (cm_rdata),
      .vga_r (vga_r), .vga_g (vga_g), .vga_b (vga_b),
      .hsync (hsync), .vsync (vsync), .audio_out (audio_out),
      .pad0_btn ({4'b0, ui_in}), .pad1_btn (12'd0),
      .sck (sck), .sd_out (sd_out), .sd_oe (sd_oe), .sd_in (sd_in),
      .cs_flash_n (cs_flash_n), .cs_ram_n (cs_ram_n)
  );

  // ---- pins ----
  // Tiny VGA Pmod: {hsync, B0, G0, R0, vsync, B1, G1, R1}
  assign uo_out = {hsync, vga_b[0], vga_g[0], vga_r[0],
                   vsync, vga_b[1], vga_g[1], vga_r[1]};

  // cartridge Pmod: CS0=0 SD0=1 SD1=2 SCK=3 SD2=4 SD3=5 CS1=6 audio=7
  assign sd_in = {uio_in[5], uio_in[4], uio_in[2], uio_in[1]};   // SD3 SD2 SD1 SD0
  assign uio_out = {audio_out, cs_ram_n, sd_out[3], sd_out[2],
                    sck, sd_out[1], sd_out[0], cs_flash_n};
  assign uio_oe  = {1'b1, 1'b1, sd_oe[3], sd_oe[2],
                    1'b1, sd_oe[1], sd_oe[0], 1'b1};

  wire _unused = &{ena, uio_in[0], uio_in[3], uio_in[6], uio_in[7], 1'b0};

endmodule
