// spi_flash.sv — W25Q128 (cartridge flash) reader/eraser/programmer.
// HARNESS ONLY (fpga/), never hardened.
//
// Same shape as sd_spi.sv on purpose: a byte engine that answers one-cycle
// `b_req` pulses, plus a flat sequencer. Nothing nests, nothing shares a
// return register.
//
// The four operations, and the protocol each one owes the part:
//   OP_ID     9Fh                          -> 3 bytes (EFh 40h 18h on a W25Q128)
//   OP_READ   03h + 24-bit addr            -> `len` bytes
//   OP_ERASE  06h WREN, then 20h + addr    -> 4 KiB sector, then poll
//   OP_PROG   06h WREN, then 02h + addr    -> <=256 bytes, then poll
//
// Two rules the part enforces and this module must honour:
//   * every erase and every program needs its OWN 06h WREN, sent as a complete
//     transaction (CS low, one byte, CS high) beforehand — the write-enable
//     latch clears itself after each write completes;
//   * the erase/program only STARTS when CS rises, and the part is then busy
//     for milliseconds. Polling 05h until status bit 0 clears is not optional:
//     a command sent while busy is silently discarded.
//
// WRITE-DATA TIMING. `wnext` pulses as each byte is handed to the shifter, so
// the producer has a full byte time (>=16 clk at DIV_FAST) to put the next one
// on `wdata`. A single-cycle-latency BRAM read comfortably makes that.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module spi_flash #(
    parameter int DIV = 0                       // 12.5 MHz at a 25 MHz clk
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,                   // pulse
    input  wire [1:0]  op,
    input  wire [23:0] addr,
    input  wire [9:0]  len,                     // bytes for READ / PROG

    output logic       wnext,                   // pulse: `wdata` consumed
    input  wire  [7:0] wdata,

    output logic       rvalid,
    output logic [7:0] rdata,

    output logic       busy,
    output logic       done,                    // 1-cycle pulse

    output logic       cs_n,
    output logic       sck,
    output logic       mosi,
    input  wire        miso
);

  localparam [1:0] OP_ID = 2'd0, OP_READ = 2'd1, OP_ERASE = 2'd2, OP_PROG = 2'd3;

  // ------------------------------------------------------------ byte engine
  logic [7:0] spi_tx, spi_rx;
  logic       spi_start, spi_busy, spi_done;

  spi_master #(.DIVW(8)) spi (
      .clk (clk), .rst (rst),
      .div (8'(DIV)), .start (spi_start), .wdata (spi_tx), .rdata (spi_rx),
      .busy (spi_busy), .done (spi_done),
      .sck (sck), .mosi (mosi), .miso (miso)
  );

  logic       b_req, b_ack, b_run;
  logic [7:0] b_tx, b_rx;

  always_ff @(posedge clk) begin
    b_ack     <= 1'b0;
    spi_start <= 1'b0;
    if (rst) begin
      b_run <= 1'b0;
    end else if (b_req) begin
      spi_tx    <= b_tx;
      spi_start <= 1'b1;
      b_run     <= 1'b1;
    end else if (b_run && spi_done) begin
      b_rx  <= spi_rx;
      b_ack <= 1'b1;
      b_run <= 1'b0;
    end
  end

  // --------------------------------------------------------------- sequencer
  typedef enum logic [3:0] {
    F_IDLE, F_WREN, F_WREN_HI, F_CMD, F_DATA_W, F_DATA_R, F_DESEL,
    F_POLL_CMD, F_POLL_RD, F_POLL_HI, F_DONE
  } fst_t;

  fst_t        st;
  logic [1:0]  cur_op;
  logic [7:0]  cmdbuf [0:3];
  logic [2:0]  cmd_len, cmd_idx;
  logic [9:0]  cnt, want;
  logic        pending;

  wire needs_wren = (cur_op == OP_ERASE) || (cur_op == OP_PROG);
  wire needs_poll = needs_wren;

  always_ff @(posedge clk) begin
    b_req  <= 1'b0;
    rvalid <= 1'b0;
    wnext  <= 1'b0;
    done   <= 1'b0;

    if (rst) begin
      st      <= F_IDLE;
      busy    <= 1'b0;
      cs_n    <= 1'b1;
      pending <= 1'b0;
      cnt     <= '0;
    end else begin
      unique case (st)

        F_IDLE: begin
          busy <= 1'b0;
          cs_n <= 1'b1;
          if (start) begin
            busy    <= 1'b1;
            cur_op  <= op;
            want    <= len;
            cnt     <= '0;
            cmd_idx <= '0;
            pending <= 1'b0;
            unique case (op)
              OP_ID: begin
                cmdbuf[0] <= 8'h9F; cmd_len <= 3'd1;
                st <= F_CMD;
              end
              OP_READ: begin
                cmdbuf[0] <= 8'h03;
                cmdbuf[1] <= addr[23:16];
                cmdbuf[2] <= addr[15:8];
                cmdbuf[3] <= addr[7:0];
                cmd_len   <= 3'd4;
                st <= F_CMD;
              end
              OP_ERASE: begin
                cmdbuf[0] <= 8'h20;
                cmdbuf[1] <= addr[23:16];
                cmdbuf[2] <= addr[15:8];
                cmdbuf[3] <= addr[7:0];
                cmd_len   <= 3'd4;
                st <= F_WREN;                    // 06h first, in its own frame
              end
              OP_PROG: begin
                cmdbuf[0] <= 8'h02;
                cmdbuf[1] <= addr[23:16];
                cmdbuf[2] <= addr[15:8];
                cmdbuf[3] <= addr[7:0];
                cmd_len   <= 3'd4;
                st <= F_WREN;
              end
            endcase
          end
        end

        // ---- 06h WREN as a complete CS-low/CS-high transaction ----
        F_WREN: begin
          cs_n <= 1'b0;
          if (!pending) begin
            b_req   <= 1'b1;
            b_tx    <= 8'h06;
            pending <= 1'b1;
          end else if (b_ack) begin
            pending <= 1'b0;
            st      <= F_WREN_HI;
          end
        end

        F_WREN_HI: begin
          cs_n <= 1'b1;                          // the latch sets on this edge
          st   <= F_CMD;
        end

        // ---- opcode (+ address) ----
        F_CMD: begin
          cs_n <= 1'b0;
          if (!pending) begin
            b_req   <= 1'b1;
            b_tx    <= cmdbuf[cmd_idx];
            pending <= 1'b1;
          end else if (b_ack) begin
            pending <= 1'b0;
            if (cmd_idx + 3'd1 == cmd_len) begin
              if (cur_op == OP_ERASE)      st <= F_DESEL;
              else if (cur_op == OP_PROG)  st <= F_DATA_W;
              else                         st <= F_DATA_R;
            end else begin
              cmd_idx <= cmd_idx + 3'd1;
            end
          end
        end

        // ---- program payload ----
        F_DATA_W: begin
          if (cnt == want) begin
            st <= F_DESEL;
          end else if (!pending) begin
            b_req   <= 1'b1;
            b_tx    <= wdata;
            wnext   <= 1'b1;                     // producer may advance now
            pending <= 1'b1;
          end else if (b_ack) begin
            pending <= 1'b0;
            cnt     <= cnt + 10'd1;
          end
        end

        // ---- read payload (also serves OP_ID, want = 3) ----
        F_DATA_R: begin
          if (cnt == want) begin
            st <= F_DESEL;
          end else if (!pending) begin
            b_req   <= 1'b1;
            b_tx    <= 8'hFF;
            pending <= 1'b1;
          end else if (b_ack) begin
            pending <= 1'b0;
            rvalid  <= 1'b1;
            rdata   <= b_rx;
            cnt     <= cnt + 10'd1;
          end
        end

        // ---- CS high: this is what actually launches an erase/program ----
        F_DESEL: begin
          cs_n <= 1'b1;
          st   <= needs_poll ? F_POLL_CMD : F_DONE;
        end

        F_POLL_CMD: begin
          cs_n <= 1'b0;
          if (!pending) begin
            b_req   <= 1'b1;
            b_tx    <= 8'h05;                    // RDSR
            pending <= 1'b1;
          end else if (b_ack) begin
            pending <= 1'b0;
            st      <= F_POLL_RD;
          end
        end

        F_POLL_RD: begin
          if (!pending) begin
            b_req   <= 1'b1;
            b_tx    <= 8'hFF;
            pending <= 1'b1;
          end else if (b_ack) begin
            pending <= 1'b0;
            if (!b_rx[0]) st <= F_POLL_HI;       // BUSY clear -> finished
          end
        end

        F_POLL_HI: begin
          cs_n <= 1'b1;
          st   <= F_DONE;
        end

        F_DONE: begin
          cs_n <= 1'b1;
          busy <= 1'b0;
          done <= 1'b1;
          st   <= F_IDLE;
        end

        default: st <= F_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
