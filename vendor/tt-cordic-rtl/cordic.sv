// cordic.sv — BIT-SERIAL 16-iteration CORDIC engine, built to fit a
// single TinyTapeout tile (the parallel version measured 194% of one).
//
// x, y, z are 20-bit shift registers circulating LSB-first through three
// 1-bit full adders. The classic serial trick: because operand and
// result shift in lockstep, "the other register >> i" is simply a FIXED
// TAP at bit position i — the parallel version's two 20-bit barrel
// shifters become two 16:1 bit-muxes. Once the tap index runs past the
// old MSB, a sign latch (captured as that MSB crosses position i)
// supplies the arithmetic extension.
//
// Schedule: each iteration = 1 decision cycle (k=0: steering direction
// and subtract-carries latched from fully settled registers) + W=20
// shift cycles. 16 iterations + a 21-cycle equalization pass (serial
// negate when the fold was applied, idle otherwise) + capture = a
// CONSTANT 359-clock operation period, independent of the input:
// ~69.6k ops/s at 25 MHz, and zero data-dependent DDS sample jitter.
//
// Interface identical to the parallel version except latency, plus:
// vector mode accepts the RIGHT half-plane only (xi >= 0); the caller
// folds the left half-plane in software (negate x,y; add half a turn to
// the result angle) — hardware vector folding would cost a second
// negate path for no coprocessor value.
//
// Angle format: 16-bit signed, full turn = 65536. Layout of the 20-bit
// registers: [19:18] sign head, [17:2] value, [1:0] guard/fraction bits
// (the atan ROM is scaled x4 to match).
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module cordic (
    input  logic               clk,
    input  logic               rst,

    input  logic               start,
    input  logic               mode,      // 0 = rotate, 1 = vector (xi >= 0)
    input  logic signed [15:0] zi,        // rotate: target angle
    input  logic signed [15:0] xi,        // vector inputs
    input  logic signed [15:0] yi,

    output logic               done,      // 1-cycle pulse
    output logic signed [15:0] cos_o,     // rotate: cos; vector: K*magnitude
    output logic signed [15:0] sin_o,     // rotate: sin
    output logic signed [15:0] zo         // vector: atan2 (right half-plane)
);

  localparam W = 20;

  // atan(2^-i) * 4, bit b of entry i (serial ROM)
  function automatic logic atan_bit(input logic [3:0] i, input logic [4:0] b);
    logic [17:0] v;
    case (i)
      4'd0:  v = 18'd32768;
      4'd1:  v = 18'd19344;
      4'd2:  v = 18'd10221;
      4'd3:  v = 18'd5188;
      4'd4:  v = 18'd2604;
      4'd5:  v = 18'd1303;
      4'd6:  v = 18'd652;
      4'd7:  v = 18'd326;
      4'd8:  v = 18'd163;
      4'd9:  v = 18'd81;
      4'd10: v = 18'd41;
      4'd11: v = 18'd20;
      4'd12: v = 18'd10;
      4'd13: v = 18'd5;
      4'd14: v = 18'd3;
      default: v = 18'd1;
    endcase
    atan_bit = (b < 5'd18) ? v[b] : 1'b0;
  endfunction

  localparam [W-1:0] X0 = 20'd79584;      // (K*32767 - margin) << 2

  localparam [1:0] S_IDLE = 2'd0, S_ITER = 2'd1, S_NEG = 2'd2, S_CAP = 2'd3;

  logic [1:0]   st;
  logic         mode_q, fold_q, ccw;
  logic [3:0]   i;
  logic [4:0]   k;                        // 0 = decision, 1..W = shifts
  logic [W-1:0] x, y, z;
  logic         cx, cy, cz;
  logic         ysgn, xsgn;

  // steering, valid on the k=0 cycle (registers fully settled)
  wire ccw_now = mode_q ? y[W-1] : ~z[W-1];

  // taps: during shift cycle k (1-based) the old bit (k-1)+i of the other
  // register sits at fixed position i, until the old MSB passes (k > W-i)
  wire tap_live = ({1'b0, k} <= 6'(W) - {2'b0, i});
  wire ytap = tap_live ? y[i] : ysgn;
  wire xtap = tap_live ? x[i] : xsgn;

  // lane operand bits: ccw = {x -= y>>i, y += x>>i, z -= atan}
  wire xb = ccw ? ~ytap : ytap;
  wire yb = ccw ? xtap : ~xtap;
  wire ab = atan_bit(i, k - 5'd1);
  wire zb = ccw ? ~ab : ab;

  wire xs_ = x[0] ^ xb ^ cx;  wire xco = (x[0] & xb) | (x[0] & cx) | (xb & cx);
  wire ys_ = y[0] ^ yb ^ cy;  wire yco = (y[0] & yb) | (y[0] & cy) | (yb & cy);
  wire zs_ = z[0] ^ zb ^ cz;  wire zco = (z[0] & zb) | (z[0] & cz) | (zb & cz);

  // serial negate pass: r <= 0 - r = ~r + 1
  wire xn = ~x[0] ^ cx;  wire xnco = ~x[0] & cx;
  wire yn = ~y[0] ^ cy;  wire ynco = ~y[0] & cy;

  wire signed [15:0] zfold = zi ^ 16'h8000;
  wire do_fold = !mode && (zi[15] ^ zi[14]);
  wire signed [15:0] zinit = do_fold ? zfold : zi;

  always_ff @(posedge clk)
    if (rst) begin
      st <= S_IDLE; done <= 1'b0;
      mode_q <= 1'b0; fold_q <= 1'b0; ccw <= 1'b0;
      i <= 4'd0; k <= 5'd0;
      x <= '0; y <= '0; z <= '0;
      cx <= 1'b0; cy <= 1'b0; cz <= 1'b0;
      ysgn <= 1'b0; xsgn <= 1'b0;
      cos_o <= 16'sd0; sin_o <= 16'sd0; zo <= 16'sd0;
    end else begin
      done <= 1'b0;

      case (st)
        S_IDLE:
          if (start) begin
            mode_q <= mode;
            fold_q <= do_fold;
            i <= 4'd0; k <= 5'd0;
            if (mode) begin
              x <= {{2{xi[15]}}, xi, 2'b00};
              y <= {{2{yi[15]}}, yi, 2'b00};
              z <= '0;
            end else begin
              x <= X0;
              y <= '0;
              z <= {{2{zinit[15]}}, zinit, 2'b00};
            end
            st <= S_ITER;
          end

        S_ITER:
          if (k == 5'd0) begin             // decision cycle: no shift
            ccw <= ccw_now;
            cx  <= ccw_now;                // subtract lanes carry-in 1
            cy  <= ~ccw_now;
            cz  <= ccw_now;
            k   <= 5'd1;
          end else begin
            x <= {xs_, x[W-1:1]};
            y <= {ys_, y[W-1:1]};
            z <= {zs_, z[W-1:1]};
            cx <= xco; cy <= yco; cz <= zco;
            if ({1'b0, k} == 6'(W) - {2'b0, i}) begin
              ysgn <= y[i];                // old MSB is crossing tap i
              xsgn <= x[i];
            end
            if (k == 5'(W)) begin
              k <= 5'd0;
              if (i == 4'd15)
                st <= S_NEG;      // ALWAYS: constant-time equalization pass
              else
                i <= i + 4'd1;
            end else
              k <= k + 5'd1;
          end

        S_NEG:
          // every op spends 21 cycles here: negating x/y when the fold was
          // applied, idling otherwise — so the operation period is a
          // CONSTANT 359 cycles regardless of input angle. Data-dependent
          // timing would phase-modulate the DDS sample rate and put
          // fold-correlated harmonics in the sine (measured risk, killed).
          if (k == 5'd0) begin
            cx <= 1'b1; cy <= 1'b1;        // +1 of the two's complement
            k  <= 5'd1;
          end else begin
            if (fold_q) begin
              x <= {xn, x[W-1:1]};
              y <= {yn, y[W-1:1]};
              cx <= xnco; cy <= ynco;
            end
            if (k == 5'(W)) begin
              k  <= 5'd0;
              st <= S_CAP;
            end else
              k <= k + 5'd1;
          end

        default: begin                     // S_CAP
          cos_o <= x[17:2];
          sin_o <= y[17:2];
          zo    <= z[17:2] + {15'b0, z[1]};
          done  <= 1'b1;
          st    <= S_IDLE;
        end
      endcase
    end

`ifdef FORMAL
  // ------------------------------------------------------------- formal
  // SymbiYosys harness (formal/cordic.sby). The control schedule is exact
  // and these invariants are inductive: the engine provably cannot hang,
  // overrun its 358-cycle worst case, or pulse done outside a completed
  // operation — from ANY reachable state, under ANY input sequence.
  reg f_valid;
  initial f_valid = 1'b0;
  always @(posedge clk) f_valid <= 1'b1;

  reg [8:0] f_ctr;                        // cycles since the op was accepted
  initial f_ctr = 9'd0;
  always @(posedge clk)
    if (rst || st == S_IDLE) f_ctr <= 9'd0;
    else                     f_ctr <= f_ctr + 9'd1;

  reg [1:0] f_st_q;
  initial f_st_q = S_IDLE;
  always @(posedge clk) f_st_q <= st;

  always @(posedge clk) if (f_valid && !rst) begin
    assert (k <= 5'd20);
    assert (f_ctr <= 9'd358);
    // the exact schedule, state by state
    if (st == S_ITER) assert (f_ctr == 9'(i) * 9'd21 + 9'(k));
    if (st == S_NEG)  assert (f_ctr == 9'd336 + 9'(k));
    if (st == S_CAP)  assert (f_ctr == 9'd357);   // constant-time: always
    if (st == S_IDLE) assert (done || f_ctr == 9'd0);
    // done discipline: one cycle, only after capture, engine back in idle
    if (done) assert (f_st_q == S_CAP);
    if (done) assert (st == S_IDLE);
    assert (!(done && $past(done)));
  end

  // reachability witnesses: full operations complete on both paths.
  // Guarded by f_valid && !rst — unguarded covers get "reached" at step 1
  // via free pre-reset register state (fake witnesses; measured).
  always @(posedge clk) if (f_valid && !rst) begin
    cover (done && !fold_q);
    cover (done && fold_q);
  end
`endif

endmodule
