// cpu_adapter.sv — glue between the TinyRV32 core's word memory interface and
// the console's byte-streaming SoC ports (console_soc f_/cd_/cm_).
//
// The core speaks 32-bit words: fetch returns an instruction PAIR (if_rdata @A,
// if_rdata2 @A+4 -- an 8-byte burst), data is a word + byte-enables. The console
// bus streams bytes with a length. This adapter turns each core request into the
// right byte-streaming transaction, reassembles the little-endian word(s), and
// decodes a carve-out of the data address space to the on-chip MMIO registers.
//
// Memory map (core byte address = {word_addr, 2'b0}, 25 bits):
//   0x0000_0000..0x00FF_FFFF  flash (dev 0)          -- code (XIP)
//   0x0100_0000..0x01FE_FFFF  PSRAM (dev 1)          -- data / stack
//   0x01FF_0000..0x01FF_00FF  console MMIO (sysregs) -- OAM / audio / sysctl / pads
// (The core's own LED/UART/QSPI_CFG MMIO at 0x0001_0000 stays internal to it.)
//
// Fetch and data are independent ports (separate arbiter masters), handled by
// two independent FSMs so a fetch and a data access can be in flight together.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module cpu_adapter (
    input  logic        clk,
    input  logic        rst,

    // -------- TinyRV32 core side (word) --------
    input  logic        if_req,
    input  logic [22:0] if_addr,          // word address
    output logic        if_ack,
    output logic [31:0] if_rdata,
    output logic [31:0] if_rdata2,

    input  logic        d_req,
    input  logic        d_we,
    input  logic [22:0] d_addr,           // word address
    input  logic [31:0] d_wdata,
    input  logic [3:0]  d_be,
    output logic        d_ack,
    output logic [31:0] d_rdata,

    // -------- console_soc side (byte-streaming) --------
    // instruction fetch master
    output logic        f_req,
    output logic        f_dev,
    output logic [23:0] f_addr,
    output logic [6:0]  f_len,
    input  logic        f_ack,
    input  logic        f_rvalid,
    input  logic [7:0]  f_rdata,
    // data memory master
    output logic        cd_req,
    output logic        cd_we,
    output logic        cd_dev,
    output logic [23:0] cd_addr,
    output logic [6:0]  cd_len,
    output logic [7:0]  cd_wdata,
    input  logic        cd_ack,
    input  logic        cd_wnext,
    input  logic        cd_rvalid,
    input  logic [7:0]  cd_rdata,
    // MMIO registers
    output logic        cm_sel,
    output logic        cm_we,
    output logic [5:0]  cm_addr,
    output logic [31:0] cm_wdata,
    input  logic [31:0] cm_rdata
);

  // ------------------------------------------------------------------ fetch FSM
  logic        if_busy;
  logic [63:0] if_buf;
  wire  [24:0] if_byte = {if_addr[22:0], 2'b0};
  assign if_rdata  = if_buf[31:0];
  assign if_rdata2 = if_buf[63:32];

  always_ff @(posedge clk)
    if (rst) begin
      if_busy <= 1'b0;
      if_ack  <= 1'b0;
      f_req   <= 1'b0;
      f_dev   <= 1'b0;
      f_addr  <= 24'd0;
      f_len   <= 7'd8;
      if_buf  <= 64'd0;
    end else begin
      if_ack <= 1'b0;
      if (!if_busy) begin
        if (if_req && !if_ack) begin
          f_req   <= 1'b1;
          f_dev   <= if_byte[24];
          f_addr  <= if_byte[23:0];                  // burst base (byte addr)
          f_len   <= 7'd8;                           // instruction pair
          if_busy <= 1'b1;
        end
      end else begin
        if (f_rvalid) if_buf <= {f_rdata, if_buf[63:8]};   // bytes LSB-first
        if (f_ack) begin
          f_req   <= 1'b0;
          if_ack  <= 1'b1;
          if_busy <= 1'b0;
        end
      end
    end

  // ------------------------------------------------------------------- data FSM
  wire [24:0] d_byte = {d_addr[22:0], 2'b0};
  wire        d_mmio = (d_byte[24:8] == 17'h1FF00);   // 0x01FF_00xx

  // byte-enable -> first byte offset + contiguous length (for writes; reads = 4)
  logic [1:0] be_off;
  logic [6:0] be_len;
  always_comb
    case (d_be)
      4'b0001: begin be_off = 2'd0; be_len = 7'd1; end
      4'b0010: begin be_off = 2'd1; be_len = 7'd1; end
      4'b0100: begin be_off = 2'd2; be_len = 7'd1; end
      4'b1000: begin be_off = 2'd3; be_len = 7'd1; end
      4'b0011: begin be_off = 2'd0; be_len = 7'd2; end
      4'b1100: begin be_off = 2'd2; be_len = 7'd2; end
      default: begin be_off = 2'd0; be_len = 7'd4; end   // 1111 (and reads)
    endcase

  localparam [1:0] D_IDLE = 2'd0, D_MMIO = 2'd1, D_MEM = 2'd2;
  logic [1:0]  d_st;
  logic [31:0] d_buf;         // read reassembly (reads) / write source (writes)
  logic [1:0]  wsel;          // which wdata byte to send next
  assign d_rdata = d_buf;
  assign cm_wdata = d_wdata;

  wire [7:0] wbyte = (wsel == 2'd0) ? d_wdata[7:0]
                   : (wsel == 2'd1) ? d_wdata[15:8]
                   : (wsel == 2'd2) ? d_wdata[23:16] : d_wdata[31:24];
  assign cd_wdata = wbyte;

  always_ff @(posedge clk)
    if (rst) begin
      d_st    <= D_IDLE;
      d_ack   <= 1'b0;
      cd_req  <= 1'b0;
      cd_we   <= 1'b0;
      cd_dev  <= 1'b0;
      cd_addr <= 24'd0;
      cd_len  <= 7'd4;
      cm_sel  <= 1'b0;
      cm_we   <= 1'b0;
      cm_addr <= 6'd0;
      d_buf   <= 32'd0;
      wsel    <= 2'd0;
    end else begin
      d_ack <= 1'b0;

      case (d_st)
        D_IDLE:
          if (d_req && !d_ack) begin
            if (d_mmio) begin
              cm_sel  <= 1'b1;
              cm_we   <= d_we;
              cm_addr <= d_byte[7:2];
              d_st    <= D_MMIO;
            end else begin
              cd_req  <= 1'b1;
              cd_we   <= d_we;
              cd_dev  <= d_addr[22];
              cd_addr <= d_byte[23:0] + {22'd0, (d_we ? be_off : 2'd0)};
              cd_len  <= d_we ? be_len : 7'd4;
              wsel    <= be_off;
              d_st    <= D_MEM;
            end
          end

        D_MMIO: begin                    // sysregs: write took effect, rdata comb
          d_buf  <= cm_rdata;
          cm_sel <= 1'b0;
          cm_we  <= 1'b0;
          d_ack  <= 1'b1;
          d_st   <= D_IDLE;
        end

        D_MEM: begin
          if (cd_rvalid) d_buf <= {cd_rdata, d_buf[31:8]};   // reads, LSB-first
          if (cd_wnext)  wsel  <= wsel + 2'd1;               // writes, next byte
          if (cd_ack) begin
            cd_req <= 1'b0;
            d_ack  <= 1'b1;
            d_st   <= D_IDLE;
          end
        end

        default: d_st <= D_IDLE;
      endcase
    end

endmodule
