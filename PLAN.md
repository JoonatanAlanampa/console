# Console — plan

The grand-goal finale: a game console SoC built, as far as possible, out
of self-designed parts. TinyRV32 CPU + race-the-beam video + audio + two
SNES pads + the custom cartridge Pmod, eventually hardened on the
self-designed standard-cell library and eventually mixed-signal with the
analog leg's own DAC/op-amp.

This is an **integration** project, not a new-block project. Nearly every
block is already proven somewhere in this workspace; the new engineering
is the glue — one memory bus shared by everything, and video that cannot
wait.

## Where the pieces already are

| piece | state | where |
|---|---|---|
| RV32 core | working silicon-shaped design, 40/40 rv32ui + C, boots from cartridge in sim | `tt-riscv` |
| cartridge Pmod (flash + 8 MB PSRAM + audio chain) | fabricated, ordered, bring-up bitstream simulated | `pmod-cartridge` |
| chiptune synth voices | designed as chip-#3 candidate, not built | CLAUDE.md |
| own cell library | 16 cells, DRC/LVS clean, hardening converging | `stdcells` (other session) |
| CORDIC-1 on own cells | gate netlist exists, now **executes** — see phase 0 | here |
| SNES pad reader | **done, verified** | `src/snes_pad.sv` |
| video timing + fetch hooks | **done, verified** | `src/vga_timing.sv` |
| memory arbiter | spec drafted, review pending | `docs/qspi-arbiter-spec.md` |

## Phase 0 — kickoff (DONE, 2026-07-21)

Everything reachable without hardware and without touching another
session's repo:

- **Gate-level twin.** The vendored gate netlist of CORDIC-1 mapped onto
  the self-designed cells now runs: cycle-exact equivalent to the RTL in
  simulation (5 tests), and it builds into a ULX3S bitstream (600 LUT4,
  207 DFF, Fmax 130 MHz) that plays a 440 Hz tone out of a netlist made
  of our own gates. Nothing had ever executed that netlist before.
- **SNES pad reader**, two pads on a shared bus, protocol-timed from
  `CLK_HZ`, checked against a behavioural pad model (5 tests).
- **VGA race-the-beam timing core**, 640×480@60 with the three hooks the
  fetch engine needs, checked against the VESA raster (6 tests).
- **QSPI arbiter spec**, with the bandwidth arithmetic that decides the
  video mode.

## Phase 1 — the arbiter (needs review first)

1. Review `docs/qspi-arbiter-spec.md` §5–§8; settle the video mode and
   the burst quantum.
2. Quad-mode QSPI controller with the **MMIO fallback to 1-bit** that
   backlog item 2 requires — a QE-bit misfire must not strand silicon.
3. Arbiter RTL against the reviewed interface, with a cocotb harness
   that models flash/PSRAM latency and asserts the video deadline is
   never missed under worst-case CPU load.

## Phase 2 — video engine

Tile/sprite scanline renderer behind the `vga_testpat` socket: tile map
+ pattern fetch through the arbiter, sprite overlay, no framebuffer and
no line buffer (see spec §3 for why neither is affordable).

## Phase 3 — audio

Chiptune voices (square/tri/noise + envelopes) into the sigma-delta
output the cartridge Pmod's RC chain filters — the same output stage
CORDIC-1 already ships and the twin already demonstrates.

## Phase 4 — SoC integration on the ULX3S

CPU + video + audio + pads + cartridge, one bitstream, one bus. This is
the real prototype: it must use the actual cartridge Pmod hardware, so
that the same board later plugs into the console chip.

## Phase 5 — silicon shape

TinyTapeout-template the design, decide the tile count, harden on the
own-cell library, and decide whether it is submitted. Not before the
ULX3S prototype plays a game.

---

## Pinout notes

**SNES pads cost N+2 pins, not 3 for two pads.** LATCH and CLK are
shared by every controller — that is how the original console wires its
two ports — so one pad is 3 pins and two pads are 4. The earlier
planning line ("2 pads, 3 ui pins") was counting one pad's worth. The
budget still fits: 4 of the 8 `ui` pins.

**Video takes all 8 `uo` pins** (Tiny VGA Pmod) and the cartridge takes
all 8 `uio`, which is exactly why the cartridge Pmod puts the audio
output on `uio[7]` instead of a second PSRAM chip select. That pinout is
frozen and fabricated.

## Constraints that shape everything

- **No RAM on a TT tile.** Every byte comes over QSPI. Flops cost about
  4.8 cells each (measured on CORDIC-1), so anything buffer-shaped has
  to justify itself in cells.
- **One bus.** Video has a hard deadline on it; see the spec.
- **Zero foundry content is the long-term goal** — the own-cell library
  is consumed as a pinned release tag, never from its working tree.
