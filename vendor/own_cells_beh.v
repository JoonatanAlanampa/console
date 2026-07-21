// own_cells_beh.v — behavioural models of the self-designed standard
// cells, for SIMULATION and FPGA synthesis of the gate-level twin.
//
// PROVENANCE / OWNERSHIP: the cells themselves (layout, SPICE, Liberty,
// LEF) live in the `stdcells` repo, which is owned by another session
// and is READ-ONLY from here. This file is not a second source of truth
// for the library — it is the minimum functional shim that lets the
// GATE NETLIST of CORDIC-1-on-own-cells run in an event simulator and
// on an ECP5. Pin names and functions were taken from stdcells
// out/own.lib (INV/BUF/NAND2/NOR2/DFF) and flow/run_lvs_all.py (TIE,
// which has HI and LO outputs and no inputs):
//
//   INV_X1  A -> Y = !A            NAND2_X1 A,B -> Y = !(A&B)
//   BUF_X2  A -> Y = A             NOR2_X1  A,B -> Y = !(A|B)
//   DFF_X1  CLK,D -> Q             TIE_X1   -> HI = 1, LO = 0
//
// DFF_X1 has NO reset pin — the library's flop is a plain positive-edge
// D flop, so every reset in the design is synchronous logic in front of
// it. That is why the twin can be compared against the RTL cycle for
// cycle after a single reset pulse (see test/test_cordic_twin.py).
//
// If the library ever renames a cell or changes a pin, this file breaks
// loudly (unknown module) rather than silently — which is the intent.
//
// Copyright (c) 2026 Joonatan Alanampa
// SPDX-License-Identifier: Apache-2.0

`default_nettype none
`timescale 1ns / 1ps

module INV_X1 (input wire A, output wire Y);
  assign Y = ~A;
endmodule

module INV_X2 (input wire A, output wire Y);
  assign Y = ~A;
endmodule

module INV_X4 (input wire A, output wire Y);
  assign Y = ~A;
endmodule

module BUF_X1 (input wire A, output wire Y);
  assign Y = A;
endmodule

module BUF_X2 (input wire A, output wire Y);
  assign Y = A;
endmodule

module BUF_X4 (input wire A, output wire Y);
  assign Y = A;
endmodule

module NAND2_X1 (input wire A, input wire B, output wire Y);
  assign Y = ~(A & B);
endmodule

module NOR2_X1 (input wire A, input wire B, output wire Y);
  assign Y = ~(A | B);
endmodule

module DFF_X1 (input wire CLK, input wire D, output reg Q);
  always @(posedge CLK) Q <= D;
endmodule

module TIE_X1 (output wire HI, output wire LO);
  assign HI = 1'b1;
  assign LO = 1'b0;
endmodule

`default_nettype wire
