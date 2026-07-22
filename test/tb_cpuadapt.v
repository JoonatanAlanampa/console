`default_nettype none
`timescale 1ns / 1ps

// Testbench for cpu_adapter: the adapter's console-side ports drive the real
// arbiter (fetch=master2, data=master3) + controller + memories, and its MMIO
// port drives sysregs. cocotb models the core, issuing word fetch/load/store.
module tb_cpuadapt ();

  initial begin
    $dumpfile("tb_cpuadapt.fst");
    $dumpvars(0, tb_cpuadapt);
    #1;
  end

  reg         clk, rst;
  reg  [1:0]  cfg;

  // core side (cocotb)
  reg         if_req;
  reg  [22:0] if_addr;
  wire        if_ack;
  wire [31:0] if_rdata, if_rdata2;
  reg         d_req, d_we;
  reg  [22:0] d_addr;
  reg  [31:0] d_wdata;
  reg  [3:0]  d_be;
  wire        d_ack;
  wire [31:0] d_rdata;

  // adapter <-> console
  wire        f_req, f_dev;
  wire [23:0] f_addr;
  wire [6:0]  f_len;
  wire        cd_req, cd_we, cd_dev;
  wire [23:0] cd_addr;
  wire [6:0]  cd_len;
  wire [7:0]  cd_wdata;
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
      .f_ack (a_ack[2]), .f_rvalid (a_rvalid[2]), .f_rdata (a_rdata),
      .cd_req (cd_req), .cd_we (cd_we), .cd_dev (cd_dev), .cd_addr (cd_addr),
      .cd_len (cd_len), .cd_wdata (cd_wdata), .cd_ack (a_ack[3]),
      .cd_wnext (a_wnext[3]), .cd_rvalid (a_rvalid[3]), .cd_rdata (a_rdata),
      .cm_sel (cm_sel), .cm_we (cm_we), .cm_addr (cm_addr),
      .cm_wdata (cm_wdata), .cm_rdata (cm_rdata)
  );

  sysregs regs (
      .clk (clk), .rst (rst),
      .sel (cm_sel), .we (cm_we), .addr (cm_addr), .wdata (cm_wdata), .rdata (cm_rdata),
      .oam (), .v_freq (), .v_wave (), .v_vol (), .video_en (), .cfg (),
      .pad0 (12'd0), .pad1 (12'd0)
  );

  // arbiter flattened: 0 video (unused), 1 audio (unused), 2 fetch, 3 data
  wire [3:0]  a_req    = {cd_req, f_req, 1'b0, 1'b0};
  wire [3:0]  a_we     = {cd_we, 3'b000};
  wire [3:0]  a_dev    = {cd_dev, f_dev, 1'b0, 1'b0};
  wire [95:0] a_addr   = {cd_addr, f_addr, 24'd0, 24'd0};
  wire [27:0] a_len    = {cd_len, f_len, 7'd1, 7'd1};
  wire [31:0] a_wdata  = {cd_wdata, 24'd0};
  wire [3:0]  a_ack, a_wnext, a_rvalid;
  wire [7:0]  a_rdata;

  wire        c_req, c_we, c_dev, c_wnext, c_ack, c_rvalid;
  wire [23:0] c_addr;
  wire [6:0]  c_len;
  wire [7:0]  c_wdata, c_rdata;

  qspi_arbiter arb (
      .clk (clk), .rst (rst), .cfg (cfg), .vid_lock (1'b0),
      .m_req (a_req), .m_we (a_we), .m_dev (a_dev),
      .m_addr (a_addr), .m_len (a_len), .m_wdata (a_wdata),
      .m_ack (a_ack), .m_wnext (a_wnext), .m_rvalid (a_rvalid), .m_rdata (a_rdata),
      .c_req (c_req), .c_we (c_we), .c_dev (c_dev), .c_addr (c_addr),
      .c_len (c_len), .c_wdata (c_wdata), .c_wnext (c_wnext), .c_ack (c_ack),
      .c_rdata (c_rdata), .c_rvalid (c_rvalid)
  );

  wire        sck;
  wire [3:0]  sd_out, sd_oe;
  reg  [3:0]  sd_in;
  wire        cs_flash_n, cs_ram_n;

  qspi_ctrl ctrl (
      .clk (clk), .rst (rst), .cfg (cfg),
      .req (c_req), .we (c_we), .dev (c_dev), .addr (c_addr), .len (c_len),
      .wdata (c_wdata), .wnext (c_wnext), .ack (c_ack),
      .rdata (c_rdata), .rvalid (c_rvalid),
      .sck (sck), .sd_out (sd_out), .sd_oe (sd_oe), .sd_in (sd_in),
      .cs_flash_n (cs_flash_n), .cs_ram_n (cs_ram_n)
  );

endmodule
