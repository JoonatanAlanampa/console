`default_nettype none
`timescale 1ns / 1ps

// tb_bram_cart.v — the fabric cartridge against the REAL controller.
//
//   iverilog -g2012 -o tb_bram_cart.vvp -s tb_bram_cart \
//       src/qspi_ctrl.sv fpga/bram_cart.sv test/tb_bram_cart.v && vvp tb_bram_cart.vvp
//
// Run it from the repo root: bram_cart's $readmemh paths are relative, and
// $readmemh failing to find a file is silent -- the array stays X and the
// symptom is a CPU that appears to execute garbage.
//
// WHY THIS BENCH AND NOT A COCOTB ONE. The point is not to check that the model
// answers *some* protocol; it is to check it answers the protocol that
// src/qspi_ctrl.sv actually speaks, byte for byte and edge for edge. So the
// controller is instantiated unmodified and driven through its request port,
// and the bench compares what comes back against the same image the model was
// loaded from. A hand-written stimulus generator could only ever check the
// protocol I *believe* the controller speaks, which is the belief under test.
//
// The interesting cases are the ones where the model's one-clock-early BRAM
// read could go wrong: an odd start address (the lane select comes off the wire
// rather than a register), a burst crossing a 16-bit word boundary, and a read
// immediately after a write to the same place.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

module tb_bram_cart ();

  localparam integer FLASH_BYTES = 65536;

  reg clk = 1'b0;
  always #20 clk = ~clk;              // 25 MHz, matching the console
  reg rst = 1'b1;

  // ---- request port ----
  reg         req = 1'b0, we = 1'b0, dev = 1'b0;
  reg  [23:0] addr = 24'd0;
  reg  [6:0]  len  = 7'd1;
  wire        ack, wnext, rvalid;
  wire [7:0]  rdata;

  reg  [7:0]  wbuf [0:127];
  reg  [6:0]  widx = 7'd0;
  wire [7:0]  wdata = wbuf[widx];

  // ---- the bus ----
  wire       sck, cs_flash_n, cs_ram_n;
  wire [3:0] sd_out, sd_oe, sd_in;
  wire       bad_cmd;

  qspi_ctrl dut (
      .clk (clk), .rst (rst), .cfg (2'b00),
      .req (req), .we (we), .dev (dev), .addr (addr), .len (len),
      .wdata (wdata), .wnext (wnext), .ack (ack),
      .rdata (rdata), .rvalid (rvalid),
      .sck (sck), .sd_out (sd_out), .sd_oe (sd_oe), .sd_in (sd_in),
      .cs_flash_n (cs_flash_n), .cs_ram_n (cs_ram_n)
  );

  bram_cart cart (
      .clk (clk), .rst (rst),
      .cs_flash_n (cs_flash_n), .cs_ram_n (cs_ram_n),
      .sd_out (sd_out), .sd_oe (sd_oe), .sd_in (sd_in),
      .bad_cmd (bad_cmd)
  );

  // The master advances its write byte when the controller says it consumed
  // one. wnext is registered, so wdata was sampled at the edge ENTERING the
  // cycle in which wnext is high -- advancing here is one edge later, and the
  // next byte is not sampled for another eight.
  always @(posedge clk) if (wnext) widx <= widx + 7'd1;

  // ---- reference image, loaded from the same files the model reads ----
  reg [7:0] ref_lo [0:FLASH_BYTES/2-1];
  reg [7:0] ref_hi [0:FLASH_BYTES/2-1];
  initial $readmemh("fpga/build/game_lo.hex", ref_lo);
  initial $readmemh("fpga/build/game_hi.hex", ref_hi);

  function [7:0] flash_byte(input [23:0] a);
    flash_byte = a[0] ? ref_hi[a[15:1]] : ref_lo[a[15:1]];
  endfunction

  // ---- capture ----
  reg [7:0]  got [0:127];
  reg [6:0]  gidx = 7'd0;
  always @(posedge clk) if (rvalid) begin
    got[gidx] <= rdata;
    gidx      <= gidx + 7'd1;
  end

  integer errors = 0;
  integer errors_before = 0;
  integer k;

  // Stimulus is driven on the NEGEDGE, never on the edge the controller samples
  // on. Driving `we`/`dev`/`addr` at the posedge is a race with the DUT's own
  // always_ff, and it does not fail loudly: it made the controller latch the
  // PREVIOUS transaction's `we`, so the write went out as 03h and the read as
  // 02h, and the symptom was a memory model that looked broken while it was
  // faithfully answering the wrong question.
  task do_txn(input _we, input _dev, input [23:0] _addr, input [6:0] _len);
    begin
      @(negedge clk);
      gidx = 7'd0;
      widx = 7'd0;
      we   = _we;
      dev  = _dev;
      addr = _addr;
      len  = _len;
      req  = 1'b1;
      @(posedge clk);
      while (!ack) @(posedge clk);
      @(negedge clk);
      req = 1'b0;
      @(posedge clk);
    end
  endtask

  task check_flash(input [23:0] a, input [6:0] n);
    begin
      errors_before = errors;
      do_txn(1'b0, 1'b0, a, n);
      if (gidx !== n) begin
        $display("FAIL: flash read @%06h len %0d returned %0d bytes", a, n, gidx);
        errors = errors + 1;
      end
      for (k = 0; k < n; k = k + 1)
        if (got[k] !== flash_byte(a + k[23:0])) begin
          $display("FAIL: flash @%06h byte %0d = %02h, expected %02h",
                   a, k, got[k], flash_byte(a + k[23:0]));
          errors = errors + 1;
        end
      if (errors == errors_before)
        $display("  flash @%06h len %0d: ok", a, n);
    end
  endtask

  task check_ram_wr_rd(input [23:0] a, input [6:0] n, input [7:0] seed);
    begin
      errors_before = errors;
      for (k = 0; k < n; k = k + 1) wbuf[k] = seed + k[7:0];
      do_txn(1'b1, 1'b1, a, n);
      do_txn(1'b0, 1'b1, a, n);
      if (gidx !== n) begin
        $display("FAIL: psram read @%06h len %0d returned %0d bytes", a, n, gidx);
        errors = errors + 1;
      end
      for (k = 0; k < n; k = k + 1)
        if (got[k] !== (seed + k[7:0])) begin
          $display("FAIL: psram @%06h byte %0d = %02h, expected %02h",
                   a, k, got[k], seed + k[7:0]);
          errors = errors + 1;
        end
      if (errors == errors_before)
        $display("  psram @%06h len %0d write+read: ok", a, n);
    end
  endtask

  initial begin
    $dumpfile("tb_bram_cart.fst");
    $dumpvars(0, tb_bram_cart);

    repeat (8) @(posedge clk);
    rst = 1'b0;
    repeat (4) @(posedge clk);

    // The boot vector. If this one byte is wrong nothing else matters -- it is
    // the first instruction byte the CPU ever fetches.
    check_flash(24'h000000, 7'd4);

    // A burst long enough to cross many 16-bit words, from an EVEN address.
    check_flash(24'h000000, 7'd32);

    // ODD start address: the lane select for the first byte comes straight off
    // the wire rather than out of a register, so this is the case the
    // one-clock-early read is most likely to get wrong.
    check_flash(24'h000001, 7'd16);
    check_flash(24'h000003, 7'd5);

    // The tile pattern table, where the video engine fetches from.
    check_flash(24'h008000, 7'd16);
    check_flash(24'h008001, 7'd16);

    // A burst the arbiter would actually issue.
    check_flash(24'h001234, 7'd96);

    // PSRAM, including the tile map the game writes and the odd-address case.
    check_ram_wr_rd(24'h010000, 7'd20, 8'h40);
    check_ram_wr_rd(24'h010001, 7'd7,  8'h80);
    check_ram_wr_rd(24'h000000, 7'd16, 8'hA0);

    // Writes must not have disturbed the flash.
    check_flash(24'h000000, 7'd8);

    if (bad_cmd !== 1'b0) begin
      $display("FAIL: bad_cmd is set -- the model saw an opcode it does not implement");
      errors = errors + 1;
    end

    if (errors == 0) $display("tb_bram_cart: PASS");
    else begin
      $display("tb_bram_cart: FAIL (%0d errors)", errors);
      $fatal(1);
    end
    $finish;
  end

  // A transaction that never acks would otherwise hang the runner silently.
  initial begin
    #5_000_000;
    $display("tb_bram_cart: FAIL - timeout, a transaction never acked");
    $fatal(1);
  end

endmodule
`default_nettype wire
