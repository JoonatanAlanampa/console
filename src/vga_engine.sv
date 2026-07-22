// vga_engine.sv — the console's video engine: ping-pong line buffers, a 2bpp
// tile renderer, and an 8-sprite overlay. Drops into the vga_testpat socket
// (de, x, y, frame_start + fetch hooks) and drives the Tiny VGA Pmod RGB222.
//
// 160x120 logical over 640x480 (4x pixel scaling). One logical line = 4 screen
// lines. Per logical line the fetcher fills the BACK buffers (tiles, then
// sprites) while the renderer reads the FRONT buffers for the current line;
// they swap at each logical-line boundary. Line 0 is prefetched during v-blank.
//
// Sprites (research/console-sprites.md): OAM is on-chip (cached per frame, never
// re-fetched from QSPI -- our bus is too overhead-heavy for per-line attribute
// reads), and sprites are VERTICALLY DOUBLED (their pattern row is fetched once
// per logical line, sharing the ~3200-clock budget with the tiles). 8 sprites,
// 8x8, 2bpp; sprite colour index 0 is transparent (the tile shows through);
// lowest sprite index wins. OAM entry (32 bits): {7'b0, en, tile[8], y[8], x[8]}
// with x,y in logical (160x120) space.
//
// The tile fetch (vga_fetch) and the sprite fetch share the one arbiter video
// port; the engine muxes the port between them and runs tiles then sprites.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module vga_engine #(
    parameter [23:0] TILEMAP_BASE = 24'h010000,
    parameter [23:0] PATTERN_BASE = 24'h000000,
    parameter int    TILES        = 20,          // 160 wide
    parameter int    SPRITES      = 8,
    parameter [5:0]  PAL0 = 6'b000000,            // RGB222 palette
    parameter [5:0]  PAL1 = 6'b110000,
    parameter [5:0]  PAL2 = 6'b001100,
    parameter [5:0]  PAL3 = 6'b111111
) (
    input  logic         clk,
    input  logic         rst,

    // from vga_timing
    input  logic         de,
    input  logic [9:0]   x,
    input  logic [9:0]   y,
    input  logic         frame_start,
    input  logic         line_fetch,
    input  logic [9:0]   next_y,

    // sprite attribute memory (CPU-owned; flattened, SPRITES x 32 bit)
    input  logic [SPRITES*32-1:0] oam,

    // Tiny VGA Pmod
    output logic [1:0]   r,
    output logic [1:0]   g,
    output logic [1:0]   b,

    // qspi_arbiter video master port + bus lock
    output logic         vid_req,
    output logic         vid_dev,
    output logic [23:0]  vid_addr,
    output logic [6:0]   vid_len,
    output logic         vid_lock,
    input  logic         vid_ack,
    input  logic         vid_rvalid,
    input  logic [7:0]   vid_rdata
);

  // ---------------------------------------------------- tile fetcher (vga_fetch)
  logic        f_start;
  logic [7:0]  f_liney;
  logic [15:0] f_pat;
  logic        f_empty;
  logic        f_fetching;
  wire         f_pop = !f_empty;
  logic        f_req, f_dev;
  logic [23:0] f_addr;
  logic [6:0]  f_len;
  logic        f_ack, f_rvalid;

  vga_fetch #(.TILEMAP_BASE(TILEMAP_BASE), .PATTERN_BASE(PATTERN_BASE),
              .TILES(TILES)) fetch (
      .clk (clk), .rst (rst),
      .start (f_start), .line_y (f_liney),
      .pop (f_pop), .tile_pat (f_pat), .empty (f_empty),
      .line_busy (), .fetching (f_fetching),
      .vid_req (f_req), .vid_dev (f_dev), .vid_addr (f_addr), .vid_len (f_len),
      .vid_ack (f_ack), .vid_rvalid (f_rvalid), .vid_rdata (vid_rdata)
  );

  logic [15:0] linebuf [2][TILES];
  logic        front;
  logic [4:0]  drain_col;
  logic [7:0]  front_ly;
  logic        sprites_fetched;      // sprites for the back line already fetched

  // sprite line buffer (ping-pong): {valid, x, pattern pair} per sprite
  logic        sp_valid [2][SPRITES];
  logic [7:0]  sp_x     [2][SPRITES];
  logic [15:0] sp_pat   [2][SPRITES];

  // ------------------------------------------------------------ sprite fetch FSM
  localparam [1:0] SP_IDLE = 2'd0, SP_ISSUE = 2'd1, SP_WAIT = 2'd2;
  logic [1:0]  sp_st;
  logic [3:0]  sp_i;
  logic [7:0]  sp_liney;
  logic [7:0]  sp_hi;
  logic        sp_second;
  logic        sp_req, sp_dev;
  logic [23:0] sp_addr;
  logic [6:0]  sp_len;
  wire         sp_active = (sp_st != SP_IDLE);
  logic        sp_start;

  wire [31:0]  oam_e = oam[sp_i*32 +: 32];
  wire [7:0]   e_x   = oam_e[7:0];
  wire [7:0]   e_y   = oam_e[15:8];
  wire [7:0]   e_t   = oam_e[23:16];
  wire         e_en  = oam_e[24];
  wire [7:0]   e_row = sp_liney - e_y;
  wire         e_hit = e_en && (sp_liney >= e_y) && (e_row < 8'd8);

  // ------------------------------------------- video-port mux (tiles vs sprites)
  assign vid_req   = f_fetching ? f_req  : sp_req;
  assign vid_dev   = f_fetching ? f_dev  : sp_dev;
  assign vid_addr  = f_fetching ? f_addr : sp_addr;
  assign vid_len   = f_fetching ? f_len  : sp_len;
  assign vid_lock  = f_fetching || sp_active;
  assign f_ack     = f_fetching && vid_ack;
  assign f_rvalid  = f_fetching && vid_rvalid;
  wire   sp_ack    = sp_active && vid_ack;
  wire   sp_rvalid = sp_active && vid_rvalid;

  wire vblank_start = (x == 10'd0) && (y == 10'd480);

  always_ff @(posedge clk)
    if (rst) begin
      f_start         <= 1'b0;
      f_liney         <= 8'd0;
      front           <= 1'b0;
      drain_col       <= 5'd0;
      front_ly        <= 8'hFF;
      sprites_fetched <= 1'b0;
      sp_start        <= 1'b0;
      sp_st           <= SP_IDLE;
      sp_i            <= 4'd0;
      sp_liney        <= 8'd0;
      sp_hi           <= 8'd0;
      sp_second       <= 1'b0;
      sp_req          <= 1'b0;
      sp_dev          <= 1'b0;
      sp_addr         <= 24'd0;
      sp_len          <= 7'd2;
    end else begin
      f_start  <= 1'b0;
      sp_start <= 1'b0;

      // drain the tile FIFO into the back tile buffer
      if (f_pop && drain_col < TILES[4:0]) begin
        linebuf[~front][drain_col] <= f_pat;
        drain_col <= drain_col + 5'd1;
      end

      // sprite fetch: after the tiles of this line are fully drained and the
      // bus is free, walk the OAM once, fetching each covering sprite's row
      if (sp_start) begin
        sp_st <= SP_ISSUE;
        sp_i  <= 4'd0;
      end else case (sp_st)
        SP_ISSUE:
          if (sp_i == SPRITES[3:0])
            sp_st <= SP_IDLE;
          else if (!e_hit) begin
            sp_valid[~front][sp_i] <= 1'b0;
            sp_i <= sp_i + 4'd1;
          end else begin
            sp_x[~front][sp_i] <= e_x;
            sp_req    <= 1'b1;
            sp_dev    <= 1'b0;
            sp_addr   <= PATTERN_BASE + {e_t, 4'd0} + {20'd0, e_row[2:0], 1'b0};
            sp_len    <= 7'd2;
            sp_second <= 1'b0;
            sp_st     <= SP_WAIT;
          end

        SP_WAIT: begin
          if (sp_rvalid) begin
            if (!sp_second) sp_hi <= vid_rdata;                  // byte 0 = hi
            else begin
              sp_pat[~front][sp_i]   <= {sp_hi, vid_rdata};      // byte 1 = lo
              sp_valid[~front][sp_i] <= 1'b1;
            end
            sp_second <= 1'b1;
          end
          if (sp_ack) begin
            sp_req <= 1'b0;
            sp_i   <= sp_i + 4'd1;
            sp_st  <= SP_ISSUE;
          end
        end

        default: sp_st <= SP_IDLE;
      endcase

      // line control: prefetch line 0 in v-blank, then swap + refetch each line
      if (vblank_start) begin
        f_start         <= 1'b1;
        f_liney         <= 8'd0;
        sp_liney        <= 8'd0;
        drain_col       <= 5'd0;
        sprites_fetched <= 1'b0;
        front_ly        <= 8'hFF;
      end else if (line_fetch && next_y[9:2] != front_ly && next_y < 10'd480) begin
        front           <= ~front;
        front_ly        <= next_y[9:2];
        drain_col       <= 5'd0;
        sprites_fetched <= 1'b0;
        f_start         <= 1'b1;
        f_liney         <= next_y[9:2] + 8'd1;
        sp_liney        <= next_y[9:2] + 8'd1;
      end else if (drain_col == TILES[4:0] && !f_fetching
                   && !sprites_fetched && sp_st == SP_IDLE) begin
        sp_start        <= 1'b1;             // tiles done + bus free -> sprites
        sprites_fetched <= 1'b1;
      end
    end

  // ------------------------------------------------------------------- renderer
  wire [7:0]  vx    = x[9:2];
  wire [4:0]  tcol  = vx[7:3];
  wire [2:0]  pxi   = vx[2:0];
  wire [15:0] tpair = linebuf[front][tcol];
  wire [1:0]  tidx  = {tpair[8 + (3'd7 - pxi)], tpair[3'd7 - pxi]};

  // sprite composite: lowest-index non-transparent covering sprite wins
  logic [1:0] pidx;
  logic [2:0] spx;
  logic [1:0] sidx;
  always_comb begin
    pidx = tidx;
    spx  = 3'd0;
    sidx = 2'd0;
    for (int s = SPRITES - 1; s >= 0; s--)
      if (sp_valid[front][s] && vx >= sp_x[front][s]
          && (vx - sp_x[front][s]) < 8'd8) begin
        spx  = 3'(vx - sp_x[front][s]);
        sidx = {sp_pat[front][s][8 + (3'd7 - spx)], sp_pat[front][s][3'd7 - spx]};
        if (sidx != 2'd0) pidx = sidx;
      end
  end

  logic [5:0] rgb;
  always_comb
    case (pidx)
      2'd0:    rgb = PAL0;
      2'd1:    rgb = PAL1;
      2'd2:    rgb = PAL2;
      default: rgb = PAL3;
    endcase

  assign {r, g, b} = de ? rgb : 6'd0;

endmodule
