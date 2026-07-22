`default_nettype none
`timescale 1ns / 1ps

// Testbench top for the memory arbiter driving the real full-rate QSPI
// controller. cocotb drives the four flattened master ports and, through
// test_arb.py's bit-level flash/PSRAM models, the SD lines.
module tb_arb ();

  initial begin
    $dumpfile("tb_arb.fst");
    $dumpvars(0, tb_arb);
    #1;
  end

  reg         clk;
  reg         rst;
  reg  [1:0]  cfg;

  // master ports (4): index 0 video, 1 audio, 2 ifetch, 3 data
  reg  [3:0]  m_req;
  reg  [3:0]  m_we;
  reg  [3:0]  m_dev;
  reg  [95:0] m_addr;
  reg  [27:0] m_len;
  reg  [31:0] m_wdata;
  wire [3:0]  m_ack;
  wire [3:0]  m_wnext;
  wire [3:0]  m_rvalid;
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

  qspi_arbiter arb (
      .clk (clk), .rst (rst), .cfg (cfg), .vid_lock (1'b0),
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
