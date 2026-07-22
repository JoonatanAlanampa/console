// sysregs.sv — the console's memory-mapped control plane. The CPU's data port,
// when it hits the MMIO region, lands here; these registers drive the video
// (sprite OAM), the audio voices, and system config, and read the input pads.
// This is the on-chip register file that makes the CPU able to run the console;
// it is NOT on the shared QSPI bus (registers, not memory).
//
// Word map (word offset = addr):
//   0x00..0x07  OAM[0..7]   sprite {7'b0, en, tile[8], y[8], x[8]}
//   0x08        SYSCTL      {..., cfg[1:0], video_en}   (cfg = QSPI quad enables)
//   0x10..0x13  AUDIO[0..3] voice {.., vol[3:0], wave[1:0], freq[15:0]}
//   0x18        PADS  (RO)  {8'b0, pad1[11:0], pad0[11:0]}
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module sysregs (
    input  logic        clk,
    input  logic        rst,

    // CPU MMIO port (word-addressed, single-cycle)
    input  logic        sel,
    input  logic        we,
    input  logic [5:0]  addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,

    // to the video engine / audio
    output logic [255:0] oam,
    output logic [63:0]  v_freq,
    output logic [7:0]   v_wave,
    output logic [15:0]  v_vol,
    output logic         video_en,
    output logic [1:0]   cfg,

    // from the input pads
    input  logic [11:0] pad0,
    input  logic [11:0] pad1
);

  logic [31:0] oam_r [8];
  logic [31:0] aud_r [4];
  logic [31:0] sysctl_r;

  always_ff @(posedge clk)
    if (rst) begin
      for (int i = 0; i < 8; i++) oam_r[i] <= 32'd0;
      for (int i = 0; i < 4; i++) aud_r[i] <= 32'd0;
      sysctl_r <= 32'd0;
    end else if (sel && we) begin
      if (addr < 6'h08)                      oam_r[addr[2:0]] <= wdata;
      else if (addr == 6'h08)                sysctl_r <= wdata;
      else if (addr >= 6'h10 && addr < 6'h14) aud_r[addr[1:0]] <= wdata;
    end

  always_comb begin
    rdata = 32'd0;
    if (addr < 6'h08)                        rdata = oam_r[addr[2:0]];
    else if (addr == 6'h08)                  rdata = sysctl_r;
    else if (addr >= 6'h10 && addr < 6'h14)  rdata = aud_r[addr[1:0]];
    else if (addr == 6'h18)                  rdata = {8'd0, pad1, pad0};
  end

  // fan the registers out to the peripherals
  genvar s;
  generate
    for (s = 0; s < 8; s++) assign oam[s*32 +: 32] = oam_r[s];
    for (s = 0; s < 4; s++) begin : g_aud
      assign v_freq[s*16 +: 16] = aud_r[s][15:0];
      assign v_wave[s*2  +: 2]  = aud_r[s][17:16];
      assign v_vol[s*4   +: 4]  = aud_r[s][21:18];
    end
  endgenerate

  assign video_en = sysctl_r[0];
  assign cfg      = sysctl_r[2:1];

endmodule
