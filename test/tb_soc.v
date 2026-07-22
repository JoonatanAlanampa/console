`default_nettype none
`timescale 1ns / 1ps

// Testbench top for the integrated console SoC (everything but the CPU core,
// which cocotb drives through the fetch/data/MMIO ports).
module tb_soc ();

  initial begin
    $dumpfile("tb_soc.fst");
    $dumpvars(0, tb_soc);
    #1;
  end

  reg         clk;
  reg         rst;

  // CPU fetch
  reg         f_req, f_dev;
  reg  [23:0] f_addr;
  reg  [6:0]  f_len;
  wire        f_ack, f_rvalid;
  wire [7:0]  f_rdata;

  // CPU data
  reg         d_req, d_we, d_dev;
  reg  [23:0] d_addr;
  reg  [6:0]  d_len;
  reg  [7:0]  d_wdata;
  wire        d_ack, d_wnext, d_rvalid;
  wire [7:0]  d_rdata;

  // CPU MMIO
  reg         m_sel, m_we;
  reg  [5:0]  m_addr;
  reg  [31:0] m_wdata;
  wire [31:0] m_rdata;

  // outputs
  wire [1:0]  vga_r, vga_g, vga_b;
  wire        hsync, vsync, audio_out;
  wire        pad_latch, pad_clk;
  reg  [1:0]  pad_data;

  // QSPI pads
  wire        sck;
  wire [3:0]  sd_out, sd_oe;
  reg  [3:0]  sd_in;
  wire        cs_flash_n, cs_ram_n;

  console_soc soc (
      .clk (clk), .rst (rst),
      .f_req (f_req), .f_dev (f_dev), .f_addr (f_addr), .f_len (f_len),
      .f_ack (f_ack), .f_rvalid (f_rvalid), .f_rdata (f_rdata),
      .d_req (d_req), .d_we (d_we), .d_dev (d_dev), .d_addr (d_addr),
      .d_len (d_len), .d_wdata (d_wdata), .d_ack (d_ack), .d_wnext (d_wnext),
      .d_rvalid (d_rvalid), .d_rdata (d_rdata),
      .m_sel (m_sel), .m_we (m_we), .m_addr (m_addr), .m_wdata (m_wdata),
      .m_rdata (m_rdata),
      .vga_r (vga_r), .vga_g (vga_g), .vga_b (vga_b),
      .hsync (hsync), .vsync (vsync), .audio_out (audio_out),
      .pad_latch (pad_latch), .pad_clk (pad_clk), .pad_data (pad_data),
      .sck (sck), .sd_out (sd_out), .sd_oe (sd_oe), .sd_in (sd_in),
      .cs_flash_n (cs_flash_n), .cs_ram_n (cs_ram_n)
  );

endmodule
