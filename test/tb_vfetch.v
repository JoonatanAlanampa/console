`default_nettype none
`timescale 1ns / 1ps

// Testbench top for the race-the-beam tile fetcher: vga_fetch on the arbiter's
// video port (0), a cocotb-driven CPU on the data port (3), through the real
// full-rate controller and bit-level flash/PSRAM models. Audio/ifetch tied off.
module tb_vfetch ();

  initial begin
    $dumpfile("tb_vfetch.fst");
    $dumpvars(0, tb_vfetch);
    #1;
  end

  reg         clk;
  reg         rst;
  reg  [1:0]  cfg;

  // video fetcher control (cocotb)
  reg         start;
  reg  [7:0]  line_y;
  reg         pop;
  wire [15:0] tile_pat;
  wire        empty;
  wire        line_busy;

  // CPU master (cocotb drives)
  reg         cpu_req, cpu_we, cpu_dev;
  reg  [23:0] cpu_addr;
  reg  [6:0]  cpu_len;
  reg  [7:0]  cpu_wdata;
  wire        cpu_ack, cpu_rvalid, cpu_wnext;

  // vga_fetch <-> arbiter video port
  wire        vid_req, vid_dev, vid_lock;
  wire [23:0] vid_addr;
  wire [6:0]  vid_len;

  // arbiter flattened master ports (0 vid, 1 aud, 2 ifetch, 3 data)
  wire [3:0]  m_req    = {cpu_req, 1'b0, 1'b0, vid_req};
  wire [3:0]  m_we     = {cpu_we, 3'b000};
  wire [3:0]  m_dev    = {cpu_dev, 1'b0, 1'b0, vid_dev};
  wire [95:0] m_addr   = {cpu_addr, 24'd0, 24'd0, vid_addr};
  wire [27:0] m_len    = {cpu_len, 7'd1, 7'd1, vid_len};
  wire [31:0] m_wdata  = {cpu_wdata, 24'd0};
  wire [3:0]  m_ack, m_wnext, m_rvalid;
  wire [7:0]  m_rdata;

  assign cpu_ack    = m_ack[3];
  assign cpu_rvalid = m_rvalid[3];
  assign cpu_wnext  = m_wnext[3];

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

  vga_fetch fetch (
      .clk (clk), .rst (rst),
      .start (start), .line_y (line_y),
      .pop (pop), .tile_pat (tile_pat), .empty (empty), .line_busy (line_busy),
      .fetching (vid_lock),
      .vid_req (vid_req), .vid_dev (vid_dev), .vid_addr (vid_addr),
      .vid_len (vid_len), .vid_ack (m_ack[0]), .vid_rvalid (m_rvalid[0]),
      .vid_rdata (m_rdata)
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
