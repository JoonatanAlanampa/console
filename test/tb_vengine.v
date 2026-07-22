`default_nettype none
`timescale 1ns / 1ps

// Testbench top for the whole video engine: vga_timing -> vga_engine (ping-pong
// buffers + tile renderer) on the arbiter's video port, through the real
// controller and bit-level flash/PSRAM. Only the video master is active.
module tb_vengine ();

  initial begin
    $dumpfile("tb_vengine.fst");
    $dumpvars(0, tb_vengine);
    #1;
  end

  reg         clk;
  reg         rst;
  reg  [1:0]  cfg;
  reg  [255:0] oam;             // 8 sprites x 32 bit

  // vga_timing outputs
  wire        hsync, vsync, de, line_fetch, frame_start, pre_line;
  wire [9:0]  x, y, next_y;

  // vga_engine outputs
  wire [1:0]  r, g, b;
  wire        vid_req, vid_dev, vid_lock;
  wire [23:0] vid_addr;
  wire [6:0]  vid_len;

  // arbiter flattened ports: only master 0 (video) active
  wire [3:0]  m_req    = {3'b000, vid_req};
  wire [3:0]  m_we     = 4'd0;
  wire [3:0]  m_dev    = {3'b000, vid_dev};
  wire [95:0] m_addr   = {72'd0, vid_addr};
  wire [27:0] m_len    = {21'd0, vid_len};
  wire [31:0] m_wdata  = 32'd0;
  wire [3:0]  m_ack, m_wnext, m_rvalid;
  wire [7:0]  m_rdata;

  // arbiter <-> controller
  wire        c_req, c_we, c_dev;
  wire [23:0] c_addr;
  wire [6:0]  c_len;
  wire [7:0]  c_wdata;
  wire        c_wnext, c_ack, c_rvalid;
  wire [7:0]  c_rdata;

  // controller pads
  wire        sck;
  wire [3:0]  sd_out, sd_oe;
  reg  [3:0]  sd_in;
  wire        cs_flash_n, cs_ram_n;

  vga_timing tim (
      .clk (clk), .rst (rst),
      .hsync (hsync), .vsync (vsync), .de (de), .x (x), .y (y),
      .line_fetch (line_fetch), .next_y (next_y),
      .frame_start (frame_start), .pre_line (pre_line)
  );

  vga_engine eng (
      .clk (clk), .rst (rst),
      .de (de), .x (x), .y (y), .frame_start (frame_start),
      .line_fetch (line_fetch), .next_y (next_y),
      .oam (oam),
      .r (r), .g (g), .b (b),
      .vid_req (vid_req), .vid_dev (vid_dev), .vid_addr (vid_addr),
      .vid_len (vid_len), .vid_lock (vid_lock),
      .vid_ack (m_ack[0]), .vid_rvalid (m_rvalid[0]), .vid_rdata (m_rdata)
  );

  qspi_arbiter arb (
      .clk (clk), .rst (rst), .cfg (cfg), .vid_lock (vid_lock),
      .m_req (m_req), .m_we (m_we), .m_dev (m_dev),
      .m_addr (m_addr), .m_len (m_len), .m_wdata (m_wdata),
      .m_ack (m_ack), .m_wnext (m_wnext), .m_rvalid (m_rvalid), .m_rdata (m_rdata),
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
