// sd_loader.sv — microSD -> cartridge-flash game loader (HARNESS ONLY).
//
// WHY THIS LIVES IN fpga/ AND NOT IN src/
// ---------------------------------------
// The console chip has no pin to spare: all 8 `uo` are the Tiny VGA Pmod, all
// 8 `uio` are the cartridge Pmod, and `ui` is input-only. An SD card therefore
// cannot exist on the silicon at all. It exists on the ULX3S because the FPGA
// has spare I/O, and it is confined to the harness so that
// `tt_um_joonatanalanampa_console` stays bit-identical to what gets hardened.
//
// WHAT IT DOES
// ------------
// While the SoC is held in reset this block owns the cartridge QSPI bus and
// copies a game image from the microSD card into the cartridge flash — the
// same flash the chip XIPs from at address 0, so the SoC boots exactly as
// silicon would and never learns an SD card was involved.
//
//   microSD block 0        16-byte image header (below)
//   microSD block 1..N     the game binary, padded to a block boundary
//   flash 0x000000..       the game binary   <- the CPU boots here
//   flash 0xFFF000         a copy of the header (last 4 KiB sector)
//
// The resident header copy is what makes repeat power-ons instant: if the
// card's header and the flash's header are byte-identical the image is already
// there, so the loader releases reset in about a millisecond instead of
// reprogramming 16 MiB of flash. Change the card or rebuild the game and the
// headers differ, so it reflashes. Nothing to press, nothing to remember.
//
// HEADER (16 bytes, little-endian), written by tools/sdwrite.py:
//   0..3   magic 'C','T','G','1'
//   4..7   image length in bytes
//   8..11  entry point (informational — the core always boots at 0)
//   12..15 sum32 of the image bytes
//
// The checksum is recomputed from what actually came off the card and compared
// before the header is committed, so a bad card fails loudly instead of
// leaving a half-written game that crashes in a way nobody can diagnose. The
// header is written LAST for the same reason: an interrupted load leaves a
// mismatched header, so the next boot retries rather than trusting a partial
// image.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module sd_loader #(
    parameter int CLK_HZ = 25_000_000
) (
    input  wire        clk,
    input  wire        rst,

    // ---- microSD ----
    output logic       sd_cs_n,
    output logic       sd_sck,
    output logic       sd_mosi,
    input  wire        sd_miso,
    input  wire        sd_present,          // card detect, active high

    // ---- cartridge flash (valid only while `owns_bus`) ----
    output logic       cart_cs_n,
    output logic       cart_sck,
    output logic       cart_mosi,
    input  wire        cart_miso,

    // ---- handshake with the harness ----
    output logic       owns_bus,            // 1 = loader drives the cart pins
    output logic       done,                // 1 = the SoC may leave reset
    output logic       error,
    output logic [7:0] status
);

  localparam [23:0] HDR_ADDR     = 24'hFF_F000;
  localparam int    SECTOR_BYTES = 4096;
  localparam int    PAGE_BYTES   = 256;

  localparam [1:0] OP_ID = 2'd0, OP_READ = 2'd1, OP_ERASE = 2'd2, OP_PROG = 2'd3;

  localparam [7:0] ST_INIT  = 8'h01, ST_HDR   = 8'h02, ST_CHECK = 8'h03,
                   ST_ERASE = 8'h04, ST_PROG  = 8'h05, ST_COMMIT= 8'h06,
                   ST_DONE  = 8'h80, ST_SKIP  = 8'h81, ST_NOCARD= 8'h82,
                   ST_E_SD  = 8'hE0, ST_E_MAGIC = 8'hE1, ST_E_SUM = 8'hE2;

  // -------------------------------------------------------------- sub-blocks
  logic        sd_init, sd_rd, sd_ready, sd_busy, sd_err, sd_rvalid, sd_rdone;
  logic [7:0]  sd_rdata;
  logic [31:0] sd_blk;

  sd_spi #(.CLK_HZ(CLK_HZ)) sd (
      .clk (clk), .rst (rst),
      .init (sd_init), .rd (sd_rd), .blk (sd_blk),
      .ready (sd_ready), .busy (sd_busy), .err (sd_err),
      .rvalid (sd_rvalid), .rdata (sd_rdata), .rdone (sd_rdone),
      .cs_n (sd_cs_n), .sck (sd_sck), .mosi (sd_mosi), .miso (sd_miso)
  );

  logic        fl_start, fl_wnext, fl_rvalid, fl_busy, fl_done;
  logic [1:0]  fl_op;
  logic [23:0] fl_addr;
  logic [9:0]  fl_len;
  logic [7:0]  fl_rdata;
  logic [7:0]  fl_wdata;

  spi_flash #(.DIV(0)) fl (
      .clk (clk), .rst (rst),
      .start (fl_start), .op (fl_op), .addr (fl_addr), .len (fl_len),
      .wnext (fl_wnext), .wdata (fl_wdata),
      .rvalid (fl_rvalid), .rdata (fl_rdata),
      .busy (fl_busy), .done (fl_done),
      .cs_n (cart_cs_n), .sck (cart_sck), .mosi (cart_mosi), .miso (cart_miso)
  );

  // ------------------------------------------------------------ block buffer
  // One SD block in, one flash page out. Yosys infers a BRAM.
  logic [7:0] blkbuf [0:511];
  logic [8:0] wa, ra;
  logic [7:0] rd_q;

  // ONE write port. The header bytes are staged through the same port so the
  // flash write stream reads them back exactly as it reads game data — two
  // always blocks writing one array would be a second driver on the memory.
  always_ff @(posedge clk) begin
    if (sd_rvalid)
      blkbuf[wa] <= sd_rdata;
    else if (st == L_CMT_PRE && hdr_i < 5'd16)
      blkbuf[9'(hdr_i)] <= hdr_sd[hdr_i];
    rd_q <= blkbuf[ra];
  end

  assign fl_wdata = rd_q;

  // --------------------------------------------------------------- registers
  logic [7:0]  hdr_sd [0:15];
  logic [7:0]  hdr_fl [0:15];
  logic [4:0]  hdr_i;
  logic [31:0] img_len, img_sum, run_sum, img_off;
  logic [31:0] blk_idx, blk_last;
  logic [23:0] er_addr;
  logic [23:0] prog_base;
  logic        page;
  logic [1:0]  dly;

  typedef enum logic [4:0] {
    L_RESET, L_INIT, L_INIT_W, L_HDR_RD, L_HDR_W, L_HDR_CHK,
    L_FLH_RD, L_FLH_W, L_CMP,
    L_ER, L_ER_W, L_BLK_RD, L_BLK_W, L_PG_PRE, L_PG, L_PG_W,
    L_SUM, L_CMT_ER, L_CMT_ER_W, L_CMT_PRE, L_CMT, L_CMT_W,
    L_DONE, L_ERR
  } lst_t;

  lst_t st;

  wire [31:0] nblocks = (img_len + 32'd511) >> 9;

  // Header comparison as pure combinational logic rather than a blocking loop
  // inside the sequential block.
  logic hdr_match;
  always_comb begin
    hdr_match = 1'b1;
    for (int k = 0; k < 16; k++)
      if (hdr_fl[k] != hdr_sd[k]) hdr_match = 1'b0;
  end

  always_ff @(posedge clk) begin
    sd_init  <= 1'b0;
    sd_rd    <= 1'b0;
    fl_start <= 1'b0;

    if (rst) begin
      st       <= L_RESET;
      owns_bus <= 1'b1;
      done     <= 1'b0;
      error    <= 1'b0;
      status   <= ST_INIT;
      wa       <= '0;
      ra       <= '0;
      hdr_i    <= '0;
      run_sum  <= '0;
      img_off  <= '0;
    end else begin

      // ---- buffer write pointer follows the SD byte stream ----
      if (sd_rvalid) wa <= wa + 9'd1;

      // ---- capture the first 16 bytes of whatever block is being read ----
      if (sd_rvalid && hdr_i < 5'd16 && st == L_HDR_W) begin
        hdr_sd[hdr_i] <= sd_rdata;
        hdr_i         <= hdr_i + 5'd1;
      end

      // ---- checksum the image bytes as they arrive ----
      if (sd_rvalid && st == L_BLK_W) begin
        if (img_off < img_len) run_sum <= run_sum + 32'(sd_rdata);
        img_off <= img_off + 32'd1;
      end

      // ---- flash read stream fills hdr_fl ----
      if (fl_rvalid && st == L_FLH_W && hdr_i < 5'd16) begin
        hdr_fl[hdr_i] <= fl_rdata;
        hdr_i         <= hdr_i + 5'd1;
      end

      // ---- buffer read pointer follows the flash write stream ----
      if (fl_wnext) ra <= ra + 9'd1;

      unique case (st)

        L_RESET: begin
          status <= ST_INIT;
          if (!sd_present) begin
            // No card is not a failure: boot whatever is already in flash.
            status <= ST_NOCARD;
            st     <= L_DONE;
          end else begin
            sd_init <= 1'b1;
            st      <= L_INIT;
          end
        end

        L_INIT:   st <= L_INIT_W;                 // let sd_busy assert
        L_INIT_W: if (sd_err) begin
                    status <= ST_E_SD; st <= L_ERR;
                  end else if (sd_ready) begin
                    status  <= ST_HDR;
                    sd_blk  <= 32'd0;
                    wa      <= '0;
                    hdr_i   <= '0;
                    sd_rd   <= 1'b1;
                    st      <= L_HDR_RD;
                  end

        L_HDR_RD: st <= L_HDR_W;
        L_HDR_W:  if (sd_err) begin
                    status <= ST_E_SD; st <= L_ERR;
                  end else if (sd_rdone) begin
                    st <= L_HDR_CHK;
                  end

        L_HDR_CHK: begin
          if (hdr_sd[0] != "C" || hdr_sd[1] != "T" ||
              hdr_sd[2] != "G" || hdr_sd[3] != "1") begin
            status <= ST_E_MAGIC;
            st     <= L_ERR;
          end else begin
            img_len <= {hdr_sd[7],  hdr_sd[6],  hdr_sd[5],  hdr_sd[4]};
            img_sum <= {hdr_sd[15], hdr_sd[14], hdr_sd[13], hdr_sd[12]};
            hdr_i   <= '0;
            fl_op   <= OP_READ;
            fl_addr <= HDR_ADDR;
            fl_len  <= 10'd16;
            fl_start<= 1'b1;
            st      <= L_FLH_RD;
          end
        end

        L_FLH_RD: st <= L_FLH_W;
        L_FLH_W:  if (fl_done) st <= L_CMP;

        L_CMP: begin
          status <= ST_CHECK;
          if (hdr_match) begin
            status <= ST_SKIP;                    // already resident
            st     <= L_DONE;
          end else begin
            status   <= ST_ERASE;
            er_addr  <= 24'd0;
            st       <= L_ER;
          end
        end

        // ---- erase every sector the image will occupy ----
        L_ER: begin
          if ({8'd0, er_addr} >= img_len) begin
            status    <= ST_PROG;
            blk_idx   <= 32'd1;                   // block 0 was the header
            blk_last  <= nblocks;
            prog_base <= 24'd0;
            run_sum   <= '0;
            img_off   <= '0;
            st        <= L_BLK_RD;
          end else begin
            fl_op    <= OP_ERASE;
            fl_addr  <= er_addr;
            fl_len   <= 10'd0;
            fl_start <= 1'b1;
            st       <= L_ER_W;
          end
        end

        L_ER_W: if (fl_done) begin
                  er_addr <= er_addr + 24'(SECTOR_BYTES);
                  st      <= L_ER;
                end

        // ---- one SD block -> two flash pages ----
        L_BLK_RD: begin
          if (blk_idx > blk_last) begin
            st <= L_SUM;
          end else begin
            sd_blk <= blk_idx;
            wa     <= '0;
            sd_rd  <= 1'b1;
            st     <= L_BLK_W;
          end
        end

        L_BLK_W: if (sd_err) begin
                   status <= ST_E_SD; st <= L_ERR;
                 end else if (sd_rdone) begin
                   page <= 1'b0;
                   ra   <= '0;
                   dly  <= 2'd2;                  // let rd_q catch up
                   st   <= L_PG_PRE;
                 end

        // The BRAM read is registered, so `fl_wdata` must already hold the
        // first byte before spi_flash asks for it.
        L_PG_PRE: if (dly == 0) st <= L_PG; else dly <= dly - 2'd1;

        L_PG: begin
          fl_op    <= OP_PROG;
          fl_addr  <= prog_base + (page ? 24'(PAGE_BYTES) : 24'd0);
          fl_len   <= 10'(PAGE_BYTES);
          fl_start <= 1'b1;
          st       <= L_PG_W;
        end

        L_PG_W: if (fl_done) begin
                  if (page) begin
                    prog_base <= prog_base + 24'd512;
                    blk_idx   <= blk_idx + 32'd1;
                    st        <= L_BLK_RD;
                  end else begin
                    page <= 1'b1;
                    dly  <= 2'd2;
                    st   <= L_PG_PRE;
                  end
                end

        // ---- verify before committing the header ----
        L_SUM: begin
          if (run_sum != img_sum) begin
            status <= ST_E_SUM;
            st     <= L_ERR;
          end else begin
            status   <= ST_COMMIT;
            fl_op    <= OP_ERASE;
            fl_addr  <= HDR_ADDR;
            fl_len   <= 10'd0;
            fl_start <= 1'b1;
            st       <= L_CMT_ER;
          end
        end

        L_CMT_ER:   st <= L_CMT_ER_W;
        L_CMT_ER_W: if (fl_done) begin
                      // stage the 16 header bytes at the base of the buffer
                      hdr_i <= '0;
                      ra    <= '0;
                      st    <= L_CMT_PRE;
                    end

        // Write hdr_sd into the buffer one byte per cycle, then program it.
        L_CMT_PRE: begin
          if (hdr_i == 5'd16) begin
            ra  <= '0;
            dly <= 2'd2;
            st  <= L_CMT;
          end else begin
            hdr_i <= hdr_i + 5'd1;
          end
        end

        L_CMT: if (dly != 0) begin
                 dly <= dly - 2'd1;
               end else begin
                 fl_op    <= OP_PROG;
                 fl_addr  <= HDR_ADDR;
                 fl_len   <= 10'd16;
                 fl_start <= 1'b1;
                 st       <= L_CMT_W;
               end

        L_CMT_W: if (fl_done) st <= L_DONE;

        L_DONE: begin
          owns_bus <= 1'b0;                       // hand the bus to the SoC
          done     <= 1'b1;
          if (status != ST_SKIP && status != ST_NOCARD) status <= ST_DONE;
        end

        L_ERR: begin
          owns_bus <= 1'b0;                       // let it try to boot anyway
          error    <= 1'b1;
          done     <= 1'b1;
        end

        default: st <= L_ERR;
      endcase
    end
  end

endmodule

`default_nettype wire
