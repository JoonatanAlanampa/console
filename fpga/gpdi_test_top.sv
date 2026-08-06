`default_nettype none
//
// gpdi_test_top.sv - RUNG 0: does this monitor accept the ULX3S GPDI output?
//
// Standalone DVI colour-bar generator, 640x480@60. No SoC, no memory, no Pmod.
// Its only job is to answer one question before rungs 1-3 are built on top of
// it: the ULX3S drives TMDS from LVCMOS33D pseudo-differential pins, which is
// NOT spec-compliant TMDS, and a picky monitor is entitled to refuse it.
//
// This is DVI signalling on an HDMI connector: video only, no audio islands.
// That is fine here - console's audio goes out the onboard 3.5 mm jack.
//
// Clocking: ONE domain. The PLL makes 125 MHz and a mod-5 counter derives the
// 25 MHz pixel enable from it, so there is no clock-domain crossing anywhere.
// 10 TMDS bits per pixel / 2 bits per DDR clock = 5 clocks. 125 MHz DDR =
// 250 Mbit/s per channel = 25 Mpixel/s. That is the whole arithmetic.
//
//   led[0]    heartbeat        - the 125 MHz domain is running
//   led[1]    PLL locked
//   led[7:2]  frame counter    - vsync is happening, even if the screen is dark
//
// If the monitor shows nothing but the LEDs count, the generator is fine and
// the problem is the link (levels, cable, EDID). That distinction is the
// reason the LEDs are wired at all.
//
module gpdi_test_top (
    input  wire        clk_25mhz,
    input  wire  [6:0] btn,
    output wire  [7:0] led,
    output wire  [3:0] gpdi_dp
);

  // ------------------------------------------------------------------ clocks
  wire clk_shift, pll_lock;
  pll_25_125 pll (.clkin(clk_25mhz), .clkout0(clk_shift), .locked(pll_lock));

  // Reset, synchronised into the shift domain. It must come out of a FLOP, not
  // straight off a pad through a LUT: this design occupies a tiny corner of an
  // 85F, so any net that fans out to everything crosses most of the die, and
  // measured routing on such a hop is >5 ns against an 8 ns period.
  reg [1:0] rst_sync;
  always @(posedge clk_shift) rst_sync <= {rst_sync[0], ~(pll_lock & btn[0])};
  wire rst = rst_sync[1];               // BTN0 (PWR) is active low

  // mod-5 phase: one pixel per 5 shift clocks.
  reg [2:0] ph;
  always @(posedge clk_shift) begin
    if (rst)             ph <= 3'd0;
    else if (ph == 3'd4) ph <= 3'd0;
    else                 ph <= ph + 3'd1;
  end

  // pce is REGISTERED, and that is the whole timing fix. Combinationally it was
  // ph -> LUT -> (5.3 ns across the die) -> LUT -> enable, 8.44 ns against an
  // 8.00 ns period: 118.53 MHz, FAIL. Out of a flop the same long wire becomes
  // flop-to-flop with a full period to cross. It costs one shift clock of
  // phase, which is invisible because EVERY consumer (encoders, serialiser
  // load) uses this one signal, so the whole pipeline shifts together and the
  // 5-clock cadence is unchanged.
  reg pce;
  always @(posedge clk_shift) pce <= !rst && (ph == 3'd4);

  // ------------------------------------------------------- 640x480@60 timing
  // Identical numbers to src/vga_timing.sv, so this proves the same raster the
  // console engine produces: 800 x 525 at 25 MHz = 59.52 Hz.
  localparam [9:0] H_VIS = 10'd640, H_FP = 10'd16, H_SY = 10'd96, H_BP = 10'd48;
  localparam [9:0] V_VIS = 10'd480, V_FP = 10'd10, V_SY = 10'd2,  V_BP = 10'd33;
  localparam [9:0] H_TOT = H_VIS + H_FP + H_SY + H_BP;   // 800
  localparam [9:0] V_TOT = V_VIS + V_FP + V_SY + V_BP;   // 525

  reg [9:0] hc, vc;
  always @(posedge clk_shift) begin
    if (rst) begin
      hc <= 10'd0; vc <= 10'd0;
    end else if (pce) begin
      if (hc == H_TOT - 10'd1) begin
        hc <= 10'd0;
        vc <= (vc == V_TOT - 10'd1) ? 10'd0 : vc + 10'd1;
      end else begin
        hc <= hc + 10'd1;
      end
    end
  end

  wire de    = (hc < H_VIS) && (vc < V_VIS);
  // DVI wants ACTIVE-LOW sync for 640x480@60, so assert = 0.
  wire hsync = !((hc >= H_VIS + H_FP) && (hc < H_VIS + H_FP + H_SY));
  wire vsync = !((vc >= V_VIS + V_FP) && (vc < V_VIS + V_FP + V_SY));

  // frame counter, for the LEDs and for the moving marker
  reg [7:0] frame;
  reg       vs_q;
  always @(posedge clk_shift) if (pce) begin
    vs_q <= vsync;
    if (!vsync && vs_q) frame <= frame + 8'd1;   // falling edge = start of sync
  end

  // ------------------------------------------------------------- test pattern
  // Eight 80-pixel colour bars, a 2-pixel white border to prove the whole
  // raster arrives, and a white line that walks down one row per frame to
  // prove frames are advancing rather than one still image being latched.
  reg [2:0] bar;
  always @* begin
    if      (hc < 10'd80)  bar = 3'd0;
    else if (hc < 10'd160) bar = 3'd1;
    else if (hc < 10'd240) bar = 3'd2;
    else if (hc < 10'd320) bar = 3'd3;
    else if (hc < 10'd400) bar = 3'd4;
    else if (hc < 10'd480) bar = 3'd5;
    else if (hc < 10'd560) bar = 3'd6;
    else                   bar = 3'd7;
  end

  reg [7:0] br, bg, bb;
  always @* begin
    case (bar)
      3'd0: begin br = 8'hFF; bg = 8'hFF; bb = 8'hFF; end  // white
      3'd1: begin br = 8'hFF; bg = 8'hFF; bb = 8'h00; end  // yellow
      3'd2: begin br = 8'h00; bg = 8'hFF; bb = 8'hFF; end  // cyan
      3'd3: begin br = 8'h00; bg = 8'hFF; bb = 8'h00; end  // green
      3'd4: begin br = 8'hFF; bg = 8'h00; bb = 8'hFF; end  // magenta
      3'd5: begin br = 8'hFF; bg = 8'h00; bb = 8'h00; end  // red
      3'd6: begin br = 8'h00; bg = 8'h00; bb = 8'hFF; end  // blue
      3'd7: begin br = 8'h00; bg = 8'h00; bb = 8'h00; end  // black
    endcase
  end

  wire border = (hc < 10'd2) || (hc >= H_VIS - 10'd2) ||
                (vc < 10'd2) || (vc >= V_VIS - 10'd2);
  wire marker = (vc[7:0] == frame);      // walks down one line per frame

  wire [7:0] px_r = (border || marker) ? 8'hFF : br;
  wire [7:0] px_g = (border || marker) ? 8'hFF : bg;
  wire [7:0] px_b = (border || marker) ? 8'hFF : bb;

  // Register the pattern before the encoders. Everything downstream is
  // constrained at the full 125 MHz even though it only advances every 5th
  // clock - a clock ENABLE does not relax static timing - so the path
  // hc -> bar -> colour -> encoder must not be one combinational run.
  reg [7:0] pr, pg, pb;
  reg       pde, phs, pvs;
  always @(posedge clk_shift) if (pce) begin
    pr  <= px_r; pg <= px_g; pb <= px_b;
    pde <= de;   phs <= hsync; pvs <= vsync;
  end

  // ---------------------------------------------------------- TMDS encoders
  // Channel 0 = Blue and carries {vsync,hsync} during blanking; 1 = Green,
  // 2 = Red, both with control 00. That assignment is fixed by the DVI spec.
  wire [9:0] tq0, tq1, tq2;
  tmds_encoder e0 (.clk(clk_shift), .ce(pce), .rst(rst),
                   .d(pb), .c({pvs, phs}), .de(pde), .q(tq0));
  tmds_encoder e1 (.clk(clk_shift), .ce(pce), .rst(rst),
                   .d(pg), .c(2'b00),      .de(pde), .q(tq1));
  tmds_encoder e2 (.clk(clk_shift), .ce(pce), .rst(rst),
                   .d(pr), .c(2'b00),      .de(pde), .q(tq2));

  // ------------------------------------------------------------- serialisers
  // TMDS goes LSB first. Load at the pixel boundary, then shift 2 bits per
  // clock; ODDRX1F emits bit 0 on the rising edge and bit 1 on the falling.
  // The clock channel is a fixed 5-high/5-low word = a square wave at pixel
  // rate. If the monitor will not lock, inverting this word shifts the clock
  // phase half a bit and is the first thing to try.
  localparam [9:0] CLK_WORD = 10'b1111100000;

  reg [9:0] s0, s1, s2, s3;
  always @(posedge clk_shift) begin
    if (rst) begin
      s0 <= 10'd0; s1 <= 10'd0; s2 <= 10'd0; s3 <= CLK_WORD;
    end else if (pce) begin
      s0 <= tq0; s1 <= tq1; s2 <= tq2; s3 <= CLK_WORD;
    end else begin
      s0 <= {2'b00, s0[9:2]};
      s1 <= {2'b00, s1[9:2]};
      s2 <= {2'b00, s2[9:2]};
      s3 <= {2'b00, s3[9:2]};
    end
  end

  // Only the _p pin is driven: IO_TYPE=LVCMOS33D makes the ECP5 drive the
  // paired _n site with the complement automatically.
  ODDRX1F o0 (.D0(s0[0]), .D1(s0[1]), .SCLK(clk_shift), .RST(1'b0), .Q(gpdi_dp[0]));
  ODDRX1F o1 (.D0(s1[0]), .D1(s1[1]), .SCLK(clk_shift), .RST(1'b0), .Q(gpdi_dp[1]));
  ODDRX1F o2 (.D0(s2[0]), .D1(s2[1]), .SCLK(clk_shift), .RST(1'b0), .Q(gpdi_dp[2]));
  ODDRX1F o3 (.D0(s3[0]), .D1(s3[1]), .SCLK(clk_shift), .RST(1'b0), .Q(gpdi_dp[3]));

  // ------------------------------------------------------------------- LEDs
  reg [26:0] hb;
  always @(posedge clk_shift) hb <= hb + 27'd1;
  assign led = { frame[5:0], pll_lock, hb[26] };

endmodule


// ---------------------------------------------------------------------------
// DVI 1.0 TMDS encoder, PIPELINED IN THREE STAGES.
//
// Stage 1 minimises transitions (XOR or XNOR chain), stage 2 keeps the line
// DC-balanced with a running disparity counter. Done as one combinational run
// this misses 125 MHz badly - measured 90.28 MHz post-route on an 85F, because
// popcount -> 8-deep XOR chain -> popcount -> disparity compare is far more
// than 8 ns. The clock ENABLE does not help: static timing knows nothing about
// it and constrains every path at the full clock period.
//
// Splitting costs 3 pixels of latency, which is invisible and identical on all
// three channels, and there are 5 clocks per pixel to spend anyway.
// ---------------------------------------------------------------------------
module tmds_encoder (
    input  wire        clk,
    input  wire        ce,
    input  wire        rst,
    input  wire [7:0]  d,
    input  wire [1:0]  c,
    input  wire        de,
    output reg  [9:0]  q
);
  // ---- stage 1: how many ones, and therefore XOR or XNOR
  wire [3:0] n1d = {3'b0, d[0]} + {3'b0, d[1]} + {3'b0, d[2]} + {3'b0, d[3]}
                 + {3'b0, d[4]} + {3'b0, d[5]} + {3'b0, d[6]} + {3'b0, d[7]};
  wire use_xnor_c = (n1d > 4'd4) || ((n1d == 4'd4) && (d[0] == 1'b0));

  reg [7:0] d1;
  reg       use_xnor, de1;
  reg [1:0] c1;
  always @(posedge clk) if (ce) begin
    d1 <= d; use_xnor <= use_xnor_c; de1 <= de; c1 <= c;
  end

  // ---- stage 2: the transition-minimised word, and its balance
  wire [8:0] qm_c;
  assign qm_c[0] = d1[0];
  genvar i;
  generate
    for (i = 1; i < 8; i = i + 1) begin : g_qm
      assign qm_c[i] = use_xnor ? ~(qm_c[i-1] ^ d1[i]) : (qm_c[i-1] ^ d1[i]);
    end
  endgenerate
  assign qm_c[8] = ~use_xnor;           // 1 = XOR was used, 0 = XNOR

  wire [3:0] n1q_c = {3'b0, qm_c[0]} + {3'b0, qm_c[1]} + {3'b0, qm_c[2]}
                   + {3'b0, qm_c[3]} + {3'b0, qm_c[4]} + {3'b0, qm_c[5]}
                   + {3'b0, qm_c[6]} + {3'b0, qm_c[7]};

  reg [8:0]        qm;
  reg signed [5:0] diff;
  reg              de2;
  reg [1:0]        c2;
  always @(posedge clk) if (ce) begin
    qm   <= qm_c;
    diff <= $signed({2'b00, n1q_c}) - $signed({2'b00, 4'd8 - n1q_c});
    de2  <= de1;
    c2   <= c1;
  end

  // ---- stage 3: DC balance and output
  reg signed [5:0] cnt;                 // running disparity

  always @(posedge clk) begin
    if (rst) begin
      cnt <= 6'sd0;
      q   <= 10'b1101010100;
    end else if (ce) begin
      if (!de2) begin
        // Control period: fixed words, and the disparity resets.
        cnt <= 6'sd0;
        case (c2)
          2'b00:   q <= 10'b1101010100;
          2'b01:   q <= 10'b0010101011;
          2'b10:   q <= 10'b0101010100;
          default: q <= 10'b1010101011;
        endcase
      end else if ((cnt == 6'sd0) || (diff == 6'sd0)) begin
        q[9]   <= ~qm[8];
        q[8]   <=  qm[8];
        q[7:0] <=  qm[8] ? qm[7:0] : ~qm[7:0];
        cnt    <=  qm[8] ? (cnt + diff) : (cnt - diff);
      end else if (((cnt > 6'sd0) && (diff > 6'sd0)) ||
                   ((cnt < 6'sd0) && (diff < 6'sd0))) begin
        q[9]   <= 1'b1;
        q[8]   <= qm[8];
        q[7:0] <= ~qm[7:0];
        cnt    <= cnt - diff + (qm[8] ? 6'sd2 : 6'sd0);
      end else begin
        q[9]   <= 1'b0;
        q[8]   <= qm[8];
        q[7:0] <= qm[7:0];
        cnt    <= cnt + diff - (qm[8] ? 6'sd0 : 6'sd2);
      end
    end
  end
endmodule
`default_nettype wire
