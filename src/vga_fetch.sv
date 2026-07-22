// vga_fetch.sv — tile line fetcher (console video, Phase 2 core).
//
// For one logical scanline it walks the tiles left to right and, per tile, reads
// the tile-map byte (PSRAM) then the two 2bpp pattern bytes for this row (flash),
// pushing the pattern pair into a line buffer a renderer drains as the beam
// scans. Reads only; a master on qspi_arbiter's highest-priority video port.
//
// RESOLUTION = 160x120, 20 tiles/line (decision 2026-07-22). MEASURED: a
// scattered map+pattern fetch costs ~81 system clocks/tile (the flash 6Bh
// pattern read alone sends a 24-bit SERIAL address). At 320 wide (40 tiles) a
// line is 3242 clocks — 2x over even the doubled-line budget — so the classic
// tile model does NOT fit the QSPI bus at 320. At 160 wide (20 tiles, 4x pixel
// scaling) a line is ~1620 clocks, which fits inside the 3200-clock display time
// of one logical line (4 screen lines), leaving the rest of the bus to the CPU.
//
// WHY A LINE BUFFER, not a JIT FIFO: the beam draws a tile every 32 clocks but
// the fetch produces one every ~81, so the fetch is SLOWER than the beam and any
// just-in-time FIFO underruns once it drains. The engine therefore fetches the
// WHOLE next line ahead (during the current line's 3200-clock display) into a
// buffer; the renderer reads it while the next line fills the other half
// (ping-pong — the double-buffer wrapper is the next block). This reverses the
// earlier "FIFO-only" call; the measured fetch speed forces it. ~40 B/line here.
//
// Memory model (parameters, so the CPU/layout can place them):
//   tile map    : TILEMAP_BASE + tile_row*20 + tile_col      in PSRAM (mutable)
//   pattern data: PATTERN_BASE + map_byte*16 + row_in_tile*2  in flash (ROM)
//   8x8 tiles, 2 bpp -> 16 bytes/tile, 2 bytes per row.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module vga_fetch #(
    parameter [23:0] TILEMAP_BASE = 24'h010000,   // PSRAM
    parameter [23:0] PATTERN_BASE = 24'h000000,   // flash
    parameter int    TILES        = 20,          // 160-wide (measured to fit)
    parameter int    FIFO_LOG2    = 5            // 32 entries: holds a full line
) (
    input  logic        clk,
    input  logic        rst,

    // beam interface
    input  logic        start,      // pulse: begin fetching for line_y
    input  logic [7:0]  line_y,     // 0..239 logical line

    // renderer pop interface
    input  logic        pop,        // consume the front tile's pattern pair
    output logic [15:0] tile_pat,   // {hi, lo} pattern bytes of the front tile
    output logic        empty,
    output logic        line_busy,  // fetching this line, or data still queued
    output logic        fetching,   // mid-line fetch -> arbiter locks the bus to video

    // qspi_arbiter video master port (read-only)
    output logic        vid_req,
    output logic        vid_dev,    // 0 flash, 1 PSRAM
    output logic [23:0] vid_addr,
    output logic [6:0]  vid_len,
    input  logic        vid_ack,
    input  logic        vid_rvalid,
    input  logic [7:0]  vid_rdata
);

  localparam int DEPTH = 1 << FIFO_LOG2;
  localparam [23:0] MAP_STRIDE = TILES[23:0];   // tile-map bytes per row

  localparam [2:0] F_IDLE = 3'd0, F_MAP = 3'd1, F_MAPW = 3'd2,
                   F_PAT  = 3'd3, F_PATW = 3'd4, F_PUSH = 3'd5;

  logic [2:0]  st;
  logic [5:0]  col;             // 0..TILES
  logic [4:0]  tile_row;        // line_y / 8  (0..29)
  logic [2:0]  row_in;          // line_y % 8
  logic [7:0]  map_byte;
  logic [7:0]  pat_hi, pat_lo;
  logic        pat_second;      // collecting the 2nd pattern byte

  // FIFO of 16-bit pattern pairs
  logic [15:0] mem [DEPTH];
  logic [FIFO_LOG2:0] wptr, rptr;
  wire [FIFO_LOG2:0]  count = wptr - rptr;
  wire full  = (count == DEPTH[FIFO_LOG2:0]);
  assign empty = (wptr == rptr);
  assign tile_pat = mem[rptr[FIFO_LOG2-1:0]];
  assign line_busy = (st != F_IDLE) || !empty;
  assign fetching  = (st != F_IDLE);   // while true the arbiter reserves the bus for video

  always_ff @(posedge clk) begin
    if (rst) begin
      st         <= F_IDLE;
      col        <= 6'd0;
      vid_req    <= 1'b0;
      vid_dev    <= 1'b0;
      vid_addr   <= 24'd0;
      vid_len    <= 7'd1;
      wptr       <= '0;
      rptr       <= '0;
      pat_second <= 1'b0;
      tile_row   <= 5'd0;
      row_in     <= 3'd0;
      map_byte   <= 8'd0;
      pat_hi     <= 8'd0;
      pat_lo     <= 8'd0;
    end else begin
      if (pop && !empty)
        rptr <= rptr + 1'b1;

      case (st)
        F_IDLE:
          if (start) begin
            tile_row <= line_y[7:3];
            row_in   <= line_y[2:0];
            col      <= 6'd0;
            st       <= F_MAP;
          end

        F_MAP:                               // issue tile-map read (PSRAM, 1 B)
          if (!full) begin
            vid_req  <= 1'b1;
            vid_dev  <= 1'b1;
            vid_addr <= TILEMAP_BASE + {13'd0, tile_row} * MAP_STRIDE + {18'd0, col};
            vid_len  <= 7'd1;
            st       <= F_MAPW;
          end

        F_MAPW: begin                        // capture the map byte, wait ack
          if (vid_rvalid) map_byte <= vid_rdata;
          if (vid_ack) begin
            vid_req    <= 1'b0;
            pat_second <= 1'b0;
            st         <= F_PAT;
          end
        end

        F_PAT: begin                         // issue pattern read (flash, 2 B)
          vid_req  <= 1'b1;
          vid_dev  <= 1'b0;
          vid_addr <= PATTERN_BASE + {map_byte, 4'd0} + {20'd0, row_in, 1'b0};
          vid_len  <= 7'd2;
          st       <= F_PATW;
        end

        F_PATW: begin                        // capture 2 pattern bytes, wait ack
          if (vid_rvalid) begin
            if (!pat_second) pat_hi <= vid_rdata;
            else             pat_lo <= vid_rdata;
            pat_second <= 1'b1;
          end
          if (vid_ack) begin
            vid_req <= 1'b0;
            st      <= F_PUSH;
          end
        end

        F_PUSH: begin                        // push the pair, advance the tile
          mem[wptr[FIFO_LOG2-1:0]] <= {pat_hi, pat_lo};
          wptr <= wptr + 1'b1;
          col  <= col + 1'b1;
          st   <= (col + 1'b1 == TILES[5:0]) ? F_IDLE : F_MAP;
        end

        default: st <= F_IDLE;
      endcase
    end
  end

endmodule
