# console

A game console SoC, built as far as possible out of self-designed parts:
an RV32 CPU, race-the-beam video, chiptune audio, two SNES controllers
and a custom cartridge board — with the long-term goal of hardening it on
a standard-cell library designed from device physics up, in this same
workspace.

This repository is the integration project. The plan, the phase list and
the constraints that shape the design are in [PLAN.md](PLAN.md).

## What runs today

```
python test/run.py          # all three suites, ~22 s
python test/run.py snes     # SNES pad controller        5 tests
python test/run.py vga      # VGA race-the-beam timing   6 tests
python test/run.py twin     # CORDIC-1 RTL vs own-cell netlist   5 tests
```

`make -C test BLOCK=snes` runs one suite if you prefer make;
`make -C test blocks` runs all three.

### The gate-level twin

The headline result of the kickoff. `vendor/cordic_gates.v` is the
fabricated CORDIC-1 design mapped onto the **self-designed** standard-cell
library — six cell types, 969 instances, 191 flops. Until now nothing had
ever executed it: the cell library's flow proves DRC, LVS and routing,
but never simulates the design.

`test/test_cordic_twin.py` runs that netlist and the original RTL side by
side off one clock and compares `uo_out` **on every cycle**, across
frequency codes, resets and reserved pins. They are identical.

`fpga/synth.ps1` then builds the netlist — no RTL in the bitstream — for
the ULX3S:

```
powershell -File fpga\synth.ps1
openFPGALoader -b ulx3s fpga\build\cordic_twin.bit
```

600 LUT4, 207 DFF (191 netlist flops + 16 power-on-reset), Fmax 130 MHz.
The board plays a 440 Hz tone out of a design made of our own gates.

### Blocks

- `src/snes_pad.sv` — N controllers on the shared LATCH/CLK bus, timing
  derived from `CLK_HZ`, one sample per video frame. Verified against a
  behavioural model of the pad's 4021-style shift register.
- `src/vga_timing.sv` — 640×480@60, plus the hooks a framebuffer-less
  console needs: `line_fetch`/`next_y` (what to fetch and when),
  `pre_line` (early warning), `frame_start`.
- `src/vga_testpat.sv` — placeholder pixel source that defines the socket
  the real tile engine must fit.

### Documents

- [PLAN.md](PLAN.md) — phases, what already exists, pinout arithmetic.
- [docs/qspi-arbiter-spec.md](docs/qspi-arbiter-spec.md) — the one hard
  problem: a single memory bus with a video master that has a deadline.
  **Draft, review pending.**

## Layout

```
src/        console RTL
test/       cocotb suites + run.py (no make required) + Makefile
fpga/       ULX3S harness for the gate-level twin
vendor/     read-only copies from other repos, with provenance
docs/       specifications
```

`vendor/` is never edited here — see [vendor/README.md](vendor/README.md)
for what each file is, where it came from, and which commit.

## Requirements

Icarus Verilog 12+, Python 3.12+, `pip install -r test/requirements.txt`.
The FPGA build additionally needs oss-cad-suite (yosys / nextpnr-ecp5 /
ecppack) in `%USERPROFILE%\opt\oss-cad-suite`.

## License

Apache-2.0. See [LICENSE](LICENSE).
