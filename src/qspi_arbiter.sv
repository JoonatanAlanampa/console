// qspi_arbiter.sv — the console's one-bus memory arbiter.
//
// Four masters share the single QSPI controller (and thus the cartridge Pmod's
// flash + PSRAM). Fixed priority, highest first (docs/qspi-arbiter-spec.md §5):
//
//     video  >  audio  >  CPU instruction fetch  >  CPU data
//       0        1              2                       3
//
// Only one of them (video) has a deadline the user sees, so it outranks all.
// The CPU is the elastic master: it gets whatever is left (spec §5.5).
//
// --------------------------------------------------------------------------
// Atomicity, quantum and preemption. A QSPI burst cannot be abandoned mid-word
// (§5.1), so preemption happens only between controller transactions. Each
// master issues ONE logical request (req held with {we,dev,addr,len} until
// ack); the arbiter holds that master's grant for the whole request and
// re-arbitrates only when it completes. Masters self-limit len to the burst
// QUANTUM (default 96 B), so a lower-priority master blocks a higher one for at
// most one quantum — the ~8.2 us wait the video FIFO (~20 B) is sized against
// (review A3). Video and audio, being higher priority, may of course be granted
// back-to-back.
//
// --------------------------------------------------------------------------
// Device rules baked in (the align/split the review A2/A4 assigns to the
// arbiter — a flat memory model never exercises these):
//   * PSRAM tCEM: CS-low must stay < 8 us or refresh starves and RAM CORRUPTS.
//     The arbiter chops a PSRAM request so no single controller transaction
//     exceeds PSRAM_TCEM_Q bytes in quad (88 B = 7.88 us) or PSRAM_TCEM_S in
//     1-bit (20 B = 7.72 us). Flash has no tCEM.
//   * PSRAM 1 KB page wrap: a linear PSRAM burst that crosses a 1024-byte page
//     re-reads the page start. The arbiter splits a PSRAM request at the next
//     1 KB boundary. Flash reads (03h/6Bh) run continuously — no split.
// A chopped request still streams its rdata/wnext continuously to the master
// across the pieces; the master sees one ack at the end and never learns it was
// split. Progress (g_addr/g_rem) is tracked for the CURRENT grant only.
//
// Master ports are flattened vectors (index i: [i*W +: W]) so this elaborates
// on plain iverilog. i=0 video, 1 audio, 2 ifetch, 3 data. Only `data` writes.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module qspi_arbiter #(
    parameter [6:0] QUANTUM      = 7'd96,  // max bytes a master may request
    // A quad PSRAM burst holds CS# low for (21 + 2N) clocks at 40 ns/clk
    // (cmd 8 + qaddr 5 + dummy 7 + data 2N + deselect 1). tCEM is a HARD 8 us
    // (=200 clocks) ceiling — cross it and the APS6404 refresh starves and the
    // RAM corrupts. N=90 gives 201 clocks = 8.04 us, just over; N=88 gives 197
    // clocks = 7.88 us, inside with margin (Codex C5 — review A3's own table had
    // already computed 8.24 us at ~96 B yet the prose called it "inside").
    parameter [6:0] PSRAM_TCEM_Q = 7'd88,  // quad PSRAM burst cap (<= 8 us)
    // A 1-bit PSRAM burst is (33 + 8N) clocks (cmd+addr 32 serial + data 8N +
    // deselect 1). N=20 -> 193 clocks = 7.72 us, inside.
    parameter [6:0] PSRAM_TCEM_S = 7'd20   // 1-bit PSRAM burst cap (<= 8 us)
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [1:0]  cfg,               // to compute the PSRAM tCEM cap
    // Race-the-beam lock: while high, only the video master (0) is eligible, so
    // a lower-priority master cannot start a burst in the gaps between video's
    // many small line-fetch requests (priority alone loses those gaps because a
    // served master must drop req before re-winning). The video engine raises it
    // for the duration of a line fetch; the CPU runs the rest of the line time.
    input  logic        vid_lock,

    // master request ports (4), priority = index (0 highest)
    input  logic [3:0]  m_req,
    input  logic [3:0]  m_we,              // only m_we[3] (data) is ever 1
    input  logic [3:0]  m_dev,             // 0 = flash, 1 = PSRAM
    input  logic [95:0] m_addr,            // 4 x 24-bit byte address
    input  logic [27:0] m_len,             // 4 x 7-bit length (1..QUANTUM)
    input  logic [31:0] m_wdata,           // 4 x 8-bit write byte
    output logic [3:0]  m_ack,             // 1 cycle: this master's request done
    output logic [3:0]  m_wnext,           // routed controller wnext
    output logic [3:0]  m_rvalid,          // routed controller rvalid
    output logic [7:0]  m_rdata,           // shared; qualify with m_rvalid[i]

    // downstream QSPI controller
    output logic        c_req,
    output logic        c_we,
    output logic        c_dev,
    output logic [23:0] c_addr,
    output logic [6:0]  c_len,
    output logic [7:0]  c_wdata,
    input  logic        c_wnext,
    input  logic        c_ack,
    input  logic [7:0]  c_rdata,
    input  logic        c_rvalid
);

  localparam [1:0] S_ARB = 2'd0, S_ISSUE = 2'd1, S_RUN = 2'd2;

  logic [1:0]  st;
  logic [1:0]  grant;
  logic [23:0] g_addr;
  logic [6:0]  g_rem;
  logic        g_we, g_dev;
  // a master whose request has just been served stays ineligible until it drops
  // req, so holding req one cycle past ack cannot re-issue the same transaction
  logic [3:0]  served;

  // highest-priority eligible requester (lowest index wins)
  logic [1:0] sel;
  logic       any;
  always_comb begin
    sel = 2'd0;
    any = 1'b0;
    for (int i = 3; i >= 0; i--)
      if (m_req[i] && !served[i] && (!vid_lock || i == 0)) begin
        sel = i[1:0];
        any = 1'b1;
      end
  end

  // size the next controller transaction for the current grant: min of the
  // remaining bytes, the tCEM cap, and (PSRAM only) the bytes left in the page
  wire [6:0]  tcem = g_dev ? (cfg[1] ? PSRAM_TCEM_Q : PSRAM_TCEM_S) : QUANTUM;
  wire [10:0] prem = 11'd1024 - {1'b0, g_addr[9:0]};       // 1..1024
  wire [10:0] capp = g_dev ? prem : 11'd127;               // flash: no page cap
  wire [6:0]  m1   = (g_rem < tcem) ? g_rem : tcem;
  wire [10:0] sub11 = ({4'd0, m1} < capp) ? {4'd0, m1} : capp;
  wire [6:0]  sub_len = sub11[6:0];

  // route the granted master's write data down, and the controller's streamed
  // read/write beats back up to whichever master holds the grant
  assign c_wdata = m_wdata[grant*8 +: 8];
  assign m_rdata = c_rdata;
  always_comb begin
    m_rvalid = 4'd0;
    m_wnext  = 4'd0;
    if (st == S_RUN) begin
      m_rvalid[grant] = c_rvalid;
      m_wnext[grant]  = c_wnext;
    end
  end

  always_ff @(posedge clk)
    if (rst) begin
      st     <= S_ARB;
      grant  <= 2'd0;
      g_addr <= 24'd0;
      g_rem  <= 7'd0;
      g_we   <= 1'b0;
      g_dev  <= 1'b0;
      c_req  <= 1'b0;
      c_we   <= 1'b0;
      c_dev  <= 1'b0;
      c_addr <= 24'd0;
      c_len  <= 7'd0;
      m_ack  <= 4'd0;
      served <= 4'd0;
    end else begin
      m_ack <= 4'd0;                          // pulse
      served <= served & m_req;               // clear eligibility once req drops

      case (st)
        S_ARB:
          if (any) begin
            grant  <= sel;
            g_addr <= m_addr[sel*24 +: 24];
            g_rem  <= m_len[sel*7 +: 7];
            g_we   <= m_we[sel];
            g_dev  <= m_dev[sel];
            st     <= S_ISSUE;
          end

        S_ISSUE: begin                        // launch one controller transaction
          c_req  <= 1'b1;
          c_we   <= g_we;
          c_dev  <= g_dev;
          c_addr <= g_addr;
          c_len  <= sub_len;
          st     <= S_RUN;
        end

        S_RUN:
          if (c_ack) begin
            c_req <= 1'b0;
            if (g_rem == c_len) begin         // whole logical request done
              m_ack[grant]  <= 1'b1;
              served[grant] <= 1'b1;          // ineligible until this req drops
              st            <= S_ARB;
            end else begin                    // more: advance and re-issue
              g_addr <= g_addr + {17'd0, c_len};
              g_rem  <= g_rem - c_len;
              st     <= S_ISSUE;
            end
          end

        default: st <= S_ARB;
      endcase
    end

endmodule
