// vga_engine.sv — the console's video engine: ping-pong line buffers + a 2bpp
// tile renderer, wrapped around vga_fetch. Drops into the vga_testpat socket
// (de, x, y, frame_start + the fetch hooks) and drives the Tiny VGA Pmod RGB222.
//
// 160x120 logical over 640x480 (4x pixel scaling). One logical line = 4 screen
// lines. The fetcher fills the BACK buffer with the next logical line while the
// renderer reads the FRONT buffer for the current one; they swap at each logical
// line boundary (ping-pong — a single buffer can't, because the fetch is slower
// than the beam, see vga_fetch). Line 0 is prefetched during vertical blanking.
//
// Renderer per pixel (combinational): logical x = x>>2, tile col = x>>5, pixel
// in tile = (x>>2)&7. The tile's two pattern bytes are {plane1, plane0}, MSB =
// leftmost pixel; the 2bpp index picks one of four RGB222 palette entries.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module vga_engine #(
    parameter [23:0] TILEMAP_BASE = 24'h010000,
    parameter [23:0] PATTERN_BASE = 24'h000000,
    parameter int    TILES        = 20,          // 160 wide
    parameter [5:0]  PAL0 = 6'b000000,            // RGB222 palette
    parameter [5:0]  PAL1 = 6'b110000,
    parameter [5:0]  PAL2 = 6'b001100,
    parameter [5:0]  PAL3 = 6'b111111
) (
    input  logic        clk,
    input  logic        rst,

    // from vga_timing
    input  logic        de,
    input  logic [9:0]  x,
    input  logic [9:0]  y,
    input  logic        frame_start,
    input  logic        line_fetch,   // h-blank pulse, next_y valid
    input  logic [9:0]  next_y,

    // Tiny VGA Pmod
    output logic [1:0]  r,
    output logic [1:0]  g,
    output logic [1:0]  b,

    // qspi_arbiter video master port + bus lock
    output logic        vid_req,
    output logic        vid_dev,
    output logic [23:0] vid_addr,
    output logic [6:0]  vid_len,
    output logic        vid_lock,
    input  logic        vid_ack,
    input  logic        vid_rvalid,
    input  logic [7:0]  vid_rdata
);

  // ------------------------------------------------ fetcher + ping-pong buffers
  logic        f_start;
  logic [7:0]  f_liney;
  logic [15:0] f_pat;
  logic        f_empty;
  wire         f_pop = !f_empty;      // drain the fetch FIFO into the back buffer

  vga_fetch #(.TILEMAP_BASE(TILEMAP_BASE), .PATTERN_BASE(PATTERN_BASE),
              .TILES(TILES)) fetch (
      .clk (clk), .rst (rst),
      .start (f_start), .line_y (f_liney),
      .pop (f_pop), .tile_pat (f_pat), .empty (f_empty),
      .line_busy (), .fetching (vid_lock),
      .vid_req (vid_req), .vid_dev (vid_dev), .vid_addr (vid_addr),
      .vid_len (vid_len), .vid_ack (vid_ack), .vid_rvalid (vid_rvalid),
      .vid_rdata (vid_rdata)
  );

  logic [15:0] linebuf [2][TILES];
  logic        front;                 // renderer reads linebuf[front]
  logic [4:0]  drain_col;             // next back-buffer slot to fill
  logic [7:0]  front_ly;              // logical line held in the front buffer

  // first pixel of vertical blanking -> prefetch line 0 into the back buffer
  wire vblank_start = (x == 10'd0) && (y == 10'd480);

  always_ff @(posedge clk)
    if (rst) begin
      f_start   <= 1'b0;
      f_liney   <= 8'd0;
      front     <= 1'b0;
      drain_col <= 5'd0;
      front_ly  <= 8'hFF;             // invalid: forces a swap at the first line
    end else begin
      f_start <= 1'b0;                // pulse

      if (f_pop && drain_col < TILES[4:0]) begin
        linebuf[~front][drain_col] <= f_pat;
        drain_col <= drain_col + 5'd1;
      end

      if (vblank_start) begin          // kick line 0 while the beam is in v-blank
        f_start   <= 1'b1;
        f_liney   <= 8'd0;
        drain_col <= 5'd0;
        front_ly  <= 8'hFF;
      end else if (line_fetch) begin
        // next_y[9:2] is the logical line the next screen line belongs to; when
        // it differs from what the front buffer holds, the just-filled back
        // buffer has it -> swap, and fetch the line after into the new back
        if (next_y[9:2] != front_ly && next_y < 10'd480) begin
          front     <= ~front;
          front_ly  <= next_y[9:2];
          drain_col <= 5'd0;
          f_start   <= 1'b1;
          f_liney   <= next_y[9:2] + 8'd1;
        end
      end
    end

  // ------------------------------------------------------------------- renderer
  wire [7:0]  vx   = x[9:2];          // logical x, 0..159
  wire [4:0]  tcol = vx[7:3];         // tile column, 0..19
  wire [2:0]  pxi  = vx[2:0];         // pixel within the tile, 0..7
  wire [15:0] pair = linebuf[front][tcol];
  wire        bit1 = pair[8 + (3'd7 - pxi)];   // plane 1 (high nibble byte)
  wire        bit0 = pair[3'd7 - pxi];         // plane 0
  wire [1:0]  idx  = {bit1, bit0};

  logic [5:0] rgb;
  always_comb
    case (idx)
      2'd0:    rgb = PAL0;
      2'd1:    rgb = PAL1;
      2'd2:    rgb = PAL2;
      default: rgb = PAL3;
    endcase

  assign {r, g, b} = de ? rgb : 6'd0;

endmodule
