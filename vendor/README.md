# vendor/ — read-only copies from other repositories

Nothing in this directory is edited here. Each file is a verbatim copy,
recorded with the commit it came from, so that a stale copy can always be
detected and refreshed rather than quietly diverging.

Two of these repos are owned by other concurrent sessions
(see the session board): `stdcells` and `tt-cordic` are **never written
to** from this repository.

| file | source repo | path | commit |
|---|---|---|---|
| `cordic_gates.v` | `stdcells` | `harden/cordic_gates.v` | `1d2a3a0` (2026-07-21) |
| `tt-cordic-rtl/project.sv` | `tt-cordic` | `src/project.sv` | `b646d05` (2026-07-19, the fabricated revision) |
| `tt-cordic-rtl/cordic.sv` | `tt-cordic` | `src/cordic.sv` | `b646d05` |
| `own_cells_beh.v` | — | written here | see below |

## cordic_gates.v

The fabricated CORDIC-1 design synthesized onto the self-designed
standard-cell library: 969 cell instances of six types —
`NAND2_X1` ×759, `NOR2_X1` ×583, `INV_X1` ×229, `DFF_X1` ×191,
`BUF_X2` ×25, `TIE_X1` ×18. Kept byte-identical to what the stdcells
flow emitted; the equivalence test renames its module into a build
directory (`test/mkgates.py`) rather than editing it.

**Refresh check:** if the stdcells hardening is re-run, re-copy this file
and re-run `python test/run.py twin`. That test is the only thing in the
project that checks the mapped netlist still computes a sine.

## tt-cordic-rtl/

The RTL half of the equivalence test — the exact revision that was
submitted to TTSKY26c. It is the reference the netlist is compared
against, so it must stay pinned to `b646d05` even if `tt-cordic` moves.

## own_cells_beh.v

Written in this repository, not copied: functional Verilog models of the
library's cells, needed because a gate netlist cannot simulate or
synthesize without them. Pin names and functions taken from `stdcells`
`out/own.lib` and `flow/run_lvs_all.py`. Functional only — no timing;
timing is OpenSTA's job in the stdcells hardening and silicon's job in
the vertical slice.
