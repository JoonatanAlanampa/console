// console_soc.sv — the console integrated: video engine + audio + SNES pads +
// the memory arbiter/controller + the MMIO register file, all on one clock and
// one QSPI bus. The CPU (TinyRV32 core) attaches through three ports here --
// instruction fetch, data memory, and MMIO -- so this module is the whole SoC
// minus the core itself; the tt_um top instantiates the core against these
// ports and maps everything to pins.
//
// Bus masters on qspi_arbiter: 0 = video (highest, race-the-beam), 2 = CPU
// fetch, 3 = CPU data. Port 1 (audio) is unused -- the chiptune synth reads no
// memory. MMIO (OAM/audio/sysctl/pads) is on-chip registers, not the QSPI bus.
//
// PIN NOTE for the tt_um layer (flagged, not resolved here): the SNES pads need
// pad_latch/pad_clk as OUTPUTS, but VGA takes all of uo and the cartridge Pmod
// takes all of uio -- there is no free output pin. This conflict must be
// resolved at the top (mux a cartridge line during v-blank, or drop a pad).
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module console_soc (
    input  logic        clk,
    input  logic        rst,

    // CPU instruction fetch (read-only memory master)
    input  logic        f_req,
    input  logic        f_dev,
    input  logic [23:0] f_addr,
    input  logic [6:0]  f_len,
    output logic        f_ack,
    output logic        f_rvalid,
    output logic [7:0]  f_rdata,

    // CPU data memory master
    input  logic        d_req,
    input  logic        d_we,
    input  logic        d_dev,
    input  logic [23:0] d_addr,
    input  logic [6:0]  d_len,
    input  logic [7:0]  d_wdata,
    output logic        d_ack,
    output logic        d_wnext,
    output logic        d_rvalid,
    output logic [7:0]  d_rdata,

    // CPU MMIO port (on-chip registers)
    input  logic        m_sel,
    input  logic        m_we,
    input  logic [5:0]  m_addr,
    input  logic [31:0] m_wdata,
    output logic [31:0] m_rdata,

    // VGA out (Tiny VGA Pmod)
    output logic [1:0]  vga_r,
    output logic [1:0]  vga_g,
    output logic [1:0]  vga_b,
    output logic        hsync,
    output logic        vsync,

    // audio out (cartridge Pmod uio[7])
    output logic        audio_out,

    // input buttons (direct GPIO on ui -- the SNES serial reader needs
    // latch/clk OUTPUT pins this pinout has none of, so pads are read as GPIO;
    // snes_pad stays in the tree for a future controller-Pmod revision)
    input  logic [11:0] pad0_btn,
    input  logic [11:0] pad1_btn,

    // QSPI pads (cartridge Pmod)
    output logic        sck,
    output logic [3:0]  sd_out,
    output logic [3:0]  sd_oe,
    input  logic [3:0]  sd_in,
    output logic        cs_flash_n,
    output logic        cs_ram_n
);

  // -------------------------------------------------------------- video timing
  logic        de, frame_start, line_fetch, hs, vs;
  logic [9:0]  vx, vy, next_y;
  vga_timing tim (
      .clk (clk), .rst (rst), .hsync (hs), .vsync (vs), .de (de),
      .x (vx), .y (vy), .line_fetch (line_fetch), .next_y (next_y),
      .frame_start (frame_start), .pre_line ()
  );
  assign hsync = hs;
  assign vsync = vs;

  // ------------------------------------------------------------- MMIO register file
  logic [255:0] oam;
  logic [63:0]  v_freq;
  logic [7:0]   v_wave;
  logic [15:0]  v_vol;
  logic         video_en;
  logic [1:0]   cfg;

  sysregs regs (
      .clk (clk), .rst (rst),
      .sel (m_sel), .we (m_we), .addr (m_addr), .wdata (m_wdata), .rdata (m_rdata),
      .oam (oam), .v_freq (v_freq), .v_wave (v_wave), .v_vol (v_vol),
      .video_en (video_en), .cfg (cfg),
      .pad0 (pad0_btn), .pad1 (pad1_btn)
  );

  // ------------------------------------------------------------------------ audio
  audio snd (
      .clk (clk), .rst (rst),
      .v_freq (v_freq), .v_wave (v_wave), .v_vol (v_vol),
      .sample (), .audio_out (audio_out)
  );

  // ---------------------------------------------------------------- video engine
  logic [1:0] er, eg, eb;
  logic       vid_req, vid_dev, vid_lock;
  logic [23:0] vid_addr;
  logic [6:0]  vid_len;
  logic        vid_ack, vid_rvalid;
  logic [7:0]  m_rdata_bus;                    // shared arbiter read data

  vga_engine eng (
      .clk (clk), .rst (rst),
      .de (de), .x (vx), .y (vy), .frame_start (frame_start),
      .line_fetch (line_fetch), .next_y (next_y), .oam (oam),
      .r (er), .g (eg), .b (eb),
      .vid_req (vid_req), .vid_dev (vid_dev), .vid_addr (vid_addr),
      .vid_len (vid_len), .vid_lock (vid_lock),
      .vid_ack (vid_ack), .vid_rvalid (vid_rvalid), .vid_rdata (m_rdata_bus)
  );
  assign vga_r = video_en ? er : 2'd0;
  assign vga_g = video_en ? eg : 2'd0;
  assign vga_b = video_en ? eb : 2'd0;

  // ------------------------------------------------------- arbiter + controller
  // masters: 0 video, 1 unused, 2 CPU fetch, 3 CPU data
  wire [3:0]  a_req    = {d_req, f_req, 1'b0, vid_req};
  wire [3:0]  a_we     = {d_we, 3'b000};
  wire [3:0]  a_dev    = {d_dev, f_dev, 1'b0, vid_dev};
  wire [95:0] a_addr   = {d_addr, f_addr, 24'd0, vid_addr};
  wire [27:0] a_len    = {d_len, f_len, 7'd1, vid_len};
  wire [31:0] a_wdata  = {d_wdata, 24'd0};
  wire [3:0]  a_ack, a_wnext, a_rvalid;

  assign vid_ack    = a_ack[0];
  assign vid_rvalid = a_rvalid[0];
  assign f_ack      = a_ack[2];
  assign f_rvalid   = a_rvalid[2];
  assign f_rdata    = m_rdata_bus;
  assign d_ack      = a_ack[3];
  assign d_rvalid   = a_rvalid[3];
  assign d_wnext    = a_wnext[3];
  assign d_rdata    = m_rdata_bus;

  logic        c_req, c_we, c_dev;
  logic [23:0] c_addr;
  logic [6:0]  c_len;
  logic [7:0]  c_wdata;
  logic        c_wnext, c_ack, c_rvalid;
  logic [7:0]  c_rdata;

  qspi_arbiter arb (
      .clk (clk), .rst (rst), .cfg (cfg), .vid_lock (vid_lock),
      .m_req (a_req), .m_we (a_we), .m_dev (a_dev),
      .m_addr (a_addr), .m_len (a_len), .m_wdata (a_wdata),
      .m_ack (a_ack), .m_wnext (a_wnext), .m_rvalid (a_rvalid), .m_rdata (m_rdata_bus),
      .c_req (c_req), .c_we (c_we), .c_dev (c_dev), .c_addr (c_addr),
      .c_len (c_len), .c_wdata (c_wdata), .c_wnext (c_wnext), .c_ack (c_ack),
      .c_rdata (c_rdata), .c_rvalid (c_rvalid)
  );

  qspi_ctrl ctrl (
      .clk (clk), .rst (rst), .cfg (cfg),
      .req (c_req), .we (c_we), .dev (c_dev), .addr (c_addr), .len (c_len),
      .wdata (c_wdata), .wnext (c_wnext), .ack (c_ack),
      .rdata (c_rdata), .rvalid (c_rvalid),
      .sck (sck), .sd_out (sd_out), .sd_oe (sd_oe), .sd_in (sd_in),
      .cs_flash_n (cs_flash_n), .cs_ram_n (cs_ram_n)
  );

endmodule
