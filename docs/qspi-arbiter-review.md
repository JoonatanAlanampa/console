# Design review — `qspi-arbiter-spec.md`

Reviewed 2026-07-21 against the project's own measured data (vertical-slice
P&R results, tt-riscv XIP measurements, pmod-cartridge hardware facts).

**Verdict: the arbitration policy (§5) is sound and can go to RTL. The
bandwidth model (§2) is arithmetically correct. Two things must change
before RTL: the §3 line-buffer conclusion is wrong and inverts an
architectural decision, and the §4/§6 budget uses average where a
hard-deadline system requires peak. The §7 interface has a hole.**

---

## F1 — §3 "no line buffer" is wrong by 3-5x, and mis-framed (blocking)

The spec rejects a line buffer as "~6100 cells, five times the entire 1x2
tile". Both the cost and the comparison are wrong, and the conclusion
flips when they are corrected.

**The cost.** 4.8 cells/flop is CORDIC-1's *whole-design* ratio (921 cells
/ 191 flops) — it counts all that design's combinational logic, not the
marginal cost of a storage bit. A race-the-beam line buffer is written
sequentially as the fetch arrives and read sequentially as the beam
advances, i.e. a shift register: ~1 cell per flop plus small control,
call it 1.5 for safety. Not 4.8.

**The comparison.** The vertical slice places **3450 cells in a 1x2 tile
at 47.6 % utilization** — that tile holds ~5400 cells at the 74 % the
fabricated CORDIC-1 achieved. So even the spec's own inflated 6100 cells
is ~1.1 tiles, not five.

**The size.** §3 computes for 640 px, but §4 recommends the 320-wide mode.
That halves it again.

Corrected, for the recommended mode:

| | flops | cells @1.5 | share of one 1x2 | share of a 14-tile console |
|---|---|---|---|---|
| 320 px x 2 bpp | 640 | ~960 | ~18 % | **~1.3 %** |
| 640 px x 2 bpp | 1280 | ~1920 | ~36 % | ~2.6 % |

A line buffer is **affordable at the tile count this console will actually
buy.** The spec compares against a 1x2 because that is what the vertical
slice happened to be; the console is a 12-16 tile machine.

**The mis-framing matters more than the arithmetic.** §3 evaluates a line
buffer as a way to *confine fetching to blanking* — and correctly shows
that fails (6.4 µs of blanking cannot carry a 9.6 µs fetch). But that is
not why a race-the-beam design carries one. Its real function is
**elasticity**: it converts video's deadline from "a byte must arrive
before the pixel that needs it" into "a line must be complete before the
line starts". With a buffer, a PSRAM refresh stall or an unlucky burst
collision costs nothing visible; without one, it is a visible tear, every
frame it happens.

That is precisely the risk §6 spends its large margin defending against.
Buying ~1.3 % of the tile budget removes the need for that defence and
simplifies §5 from a hard-real-time problem to a throughput problem.

**Recommendation:** re-open the line-buffer decision as an explicit
architectural fork. It costs money (tiles) so it is the user's call, but
the spec should present it as a live option with corrected numbers, not a
closed one.

## F2 — §4/§6 conflate average with peak (blocking)

320x240 pixel-doubled fetches **120 bytes for a source line, used by two
displayed lines**. §4 divides that to 60 B/line and §6 budgets 4.8 µs of
fetch and "~26 µs slack". Those are averages. The peak — what a hard
deadline is budgeted against — is 120 B = **9.6 µs on the fetching line**,
leaving 32 − 9.6 − 1.28 = **~21 µs**, not 26.

Still comfortable, so the conclusion survives; but a deadline budget
written in averages will mislead whoever tunes it later, and it hides the
design question underneath:

**Unresolved: is the fetch confined to one line time or spread over two?**
Fetching line k+1's 120 B during the *first* of the two displayed lines is
simplest but doubles peak demand; spreading it across both halves the peak
and needs the video master to hold its request across a `line_fetch`
boundary. The spec's §2 hook description implies per-displayed-line
fetching. Pick one explicitly — it changes the RTL and the arbiter's
worst-case blocking analysis.

## F3 — sprites are absent from the entire bandwidth model (blocking)

§4 budgets tile-map + pattern bytes only. A console without sprites is not
the console in `PLAN.md` (SNES pads, games). Sprite fetch is per-scanline
and competes in exactly the window this document is about: 8 sprites/line
at 2 pattern bytes + attributes is roughly +32-40 B/line, i.e. **+50-65 %
on top of the 60 B average** — enough to move 320x240 from 15 % of the bus
to ~25 %, and enough to matter for F2's peak.

The mode recommendation may well survive; it is not currently *supported*
because the dominant per-line cost of a sprite engine was never counted.

## F4 — §6 "CPU share ≈ 85 % ≈ 10.6 MB/s" ignores the overhead §8.3 cites

§8.3 correctly notes each burst costs command+address ≈ 8 bytes of bus
time, i.e. ~33 % overhead at a 16 B quantum. §6 then reports the CPU's
share as raw bus percentage. Corrected: 12.5 MB/s x 0.85 x 0.67 ≈
**7 MB/s of actual payload**, and lower for scattered accesses.

## F5 — §7 has no write-data channel (blocking, trivial)

The interface declares `we` and a read path (`rdata`/`rvalid`) but nothing
carries write data. A CPU write cannot be expressed. Add `wdata`/`wvalid`
(and decide whether writes are single-beat only — PSRAM writes are, in
practice, the only writes this machine makes).

## F6 — §7 address map truncates the flash

`addr[23]` selecting flash vs PSRAM splits a 24-bit space into 8 MB + 8 MB.
The cartridge carries a **16 MB** W25Q128 and an 8 MB APS6404, so half the
flash becomes unaddressable. Either widen to 25 bits, or map flash 0-16 MB
and PSRAM above it with a comparator rather than a single bit.

## F7 — tCEM is a known bound, not an unmeasured risk (answers part of §8)

§6 defers PSRAM refresh as "not yet measured". It is a datasheet
constraint already documented in this project:
`pmod-cartridge/fpga/README.md` — *"The APS6404 tCEM (8 us max CS-low) is
respected by keeping bursts to..."*. It gives the burst quantum a hard
**upper** bound independent of arbitration fairness, and the 16 B quantum
(1.28 µs) sits comfortably inside it. Cite it rather than re-deriving.

## F8 — audio should fetch in blocks, not single bytes

§5.4 fetches one byte per 125 µs. At ~8 bytes of command overhead that is
**~9x overhead per useful byte** — negligible in absolute terms (still
<1 % of the bus) but free to fix: fetch 16-32 B per audio refill at 1/16
the rate. It also reduces the number of preemption points, which is worth
more than the bandwidth.

## F9 — the real performance risk is CPU fetch, and it is not in this document

`tt-riscv/PLAN.md` states plainly: *"XIP over SPI flash at ~clk/2 with no
cache means multi-cycle fetches: CPI will be dominated by memory, ~10-20x
slower than the FPGA build."* §5.5 calls the CPU "elastic" — true for
*correctness*, and the arbiter is right to treat it that way. But the
console's actual failure mode is not a torn scanline; it is a CPU too slow
to run game logic within a frame while the bus is busy.

This document should state that boundary explicitly and hand it to
whoever designs the fetch path (burst-2 already measured at +22 %; an
instruction buffer or small cache is the lever). It is out of scope for
the arbiter, but the arbiter's "everything left over is the CPU's"
sentence currently reads as if that were sufficient.

---

## Confirmed correct (do not re-litigate)

- **§2 bandwidth arithmetic.** 25 MHz, 1 bit/clk → 320 ns/B; quad →
  80 ns/B; 32 µs line → 100 B / 400 B. All correct, as is the 6.4 µs
  blanking figure (160 pixel clocks).
- **"The video fetch cannot live in blanking"** — correct and load-bearing.
- **"Quad mode is mandatory"** — correct, and *stronger* than stated: at
  1-bit the 320x240 mode needs 120 B = 38.4 µs against a 32 µs line, so it
  does not merely starve the CPU, it **cannot meet the deadline at all**
  without two-line spreading. Say that; it is the better argument for
  backlog item 2 and for the MMIO 1-bit fallback being a survival mode
  rather than a performance mode.
- **§5 policy**: fixed priority, atomic transactions, quantized bursts,
  video self-capping. Sound. The ordering video > audio > CPU is right for
  the stated failure costs.
- **16 B quantum**: defensible, and F7 shows it is safe against tCEM.

## Answers to §8's open questions

1. **CPU floor?** Not needed as specified — video self-caps at ~30 % of a
   line worst case (F2) and audio at <1 %, so the CPU cannot be starved
   below ~60 %. **Re-check after sprites are budgeted (F3).**
2. **Double working set?** Moot if a line buffer is adopted (F1) — that is
   the cleaner answer than a bespoke second working set. Without one,
   21 µs corrected slack (F2) covers an 8 µs tCEM-bounded stall but leaves
   less headroom than §6 implies.
3. **Burst quantum?** Bounded above by tCEM (F7), below by command
   overhead (§8.3). 16 B is inside both; measure real quad command+dummy
   cycles before fixing, and note flash and PSRAM differ.
4. **Audio during vblank?** Moot, as suspected — video does not request.
   Delete the question.
5. **Cross-device switch cost?** Not free: a CS change forces a new
   command+address, i.e. exactly one burst's overhead (~8 B). Consequence
   for the arbiter: **prefer grouping consecutive grants by device** when
   priorities are equal, and count a device switch as part of the
   preemption cost.

## Recommended sequence

1. Decide the line-buffer fork (F1) — user call, changes tile budget.
2. Add a sprite line to the §4 model (F3) and re-run the mode choice.
3. Fix §4/§6 to peak-basis and state the one-line-vs-two-line fetch
   policy (F2).
4. Patch §7 (F5, F6) — mechanical.
5. Then RTL: quad QSPI controller with the MMIO 1-bit fallback, then the
   arbiter.
