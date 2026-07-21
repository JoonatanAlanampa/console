// ulx3s_top.sv — the gate-level twin on real hardware.
//
// This bitstream contains NO RTL. It runs the GATE NETLIST of CORDIC-1
// mapped onto the self-designed standard-cell library, with the cells
// replaced by their behavioural models (vendor/own_cells_beh.v). The
// ECP5 therefore executes the same graph of INV/BUF/NAND2/NOR2/DFF/TIE
// instances that the stdcells hardening lays out in silicon: same
// structure, same flop count, same logic — only the physics is FPGA.
//
// Why bother, when the RTL already runs on this board? Because the
// netlist is the artifact that becomes a chip, and until now nothing
// has ever EXECUTED it. Simulation proves equivalence in an event
// simulator (test/test_cordic_twin.py, cycle-exact); this proves it in
// a clocked machine, with a real 25 MHz crystal, real reset, and an
// audible output — you hear a 440 Hz tone out of the netlist that the
// cell library produced. If the mapping were wrong, the ear would know
// before any tool did.
//
//   BTN0 (PWR)   reset (held low = reset, as on the other harnesses)
//   SW1..SW4     frequency code bits 0..3 -> codes 0..15
//                (code 0 = the 440 Hz wake-up tone)
//   LED0         heartbeat, ~1.5 Hz — the "netlist is alive" pilot light
//   LED5..LED1   live sine level bar
//   LED6         phase-locked square sync
//   LED7         sigma-delta sine (looks half-lit; it is a bit stream)
//   GP0          sigma-delta sine  -> Audio Pmod / RC filter -> speaker
//   GP1          square sync       -> scope trigger
//
// Build: powershell -File fpga\synth.ps1     Flash: openFPGALoader -b ulx3s
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module ulx3s_top (
    input  wire        clk_25mhz,
    input  wire  [6:0] btn,
    input  wire  [3:0] sw,
    output wire  [7:0] led,
    output wire  [3:0] pmod_gp,
    output wire  [3:0] pmod_gn,
    output wire        wifi_gpio0
);

  assign wifi_gpio0 = 1'b1;   // keep the ESP32 out of the way

  // Power-on reset: the library's flop has no reset pin, so every reset
  // in this design is synchronous logic — it needs a few clocks of rst_n
  // low after configuration before the netlist's state is defined.
  reg [15:0] por = 16'd0;
  always @(posedge clk_25mhz) if (!(&por)) por <= por + 16'd1;
  wire rst_n = btn[0] && (&por);

  wire [7:0] uo_out, uio_out, uio_oe;
  wire [7:0] ui_in = {4'b0000, sw};   // frequency code 0..15

  tt_um_joonatanalanampa_cordic twin (
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (8'h00),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (1'b1),
      .clk    (clk_25mhz),
      .rst_n  (rst_n)
  );

  assign led     = uo_out;
  assign pmod_gp = {2'b00, uo_out[6], uo_out[7]};  // GP1 square, GP0 sine
  assign pmod_gn = 4'b0000;

  wire _unused = &{uio_out, uio_oe, btn[6:1], 1'b0};

endmodule

`default_nettype wire
