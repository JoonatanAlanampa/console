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

### It is not a yes/no — it is a depth, and the cost is linear

Framing this as "line buffer or not" is the spec's second mistake, and
mine in the first draft of this review. What is actually being bought is
**how many bytes of fetch run ahead of the beam**, and the price scales
with that depth.

Video consumes 120 B per source line over two displayed lines (51.2 µs
visible), i.e. **one byte per ~430 ns**. So depth converts directly into
stall immunity:

| depth | flops | ~cells | absorbs | survives |
|---|---|---|---|---|
| today's "small working set" | ~30 | ~50 | ~1.3 µs | one CPU burst, marginally |
| **~20 bytes** | 160 | **~240** | **8.6 µs** | **the 8 µs tCEM PSRAM stall** |
| half line (~60 B) | 320 | ~480 | ~26 µs | any single stall within half a line |
| full line, ping-pong | 1280 | ~1900 | a whole line | everything; full decoupling |

Two corrections to earlier numbers in this document:

- A *usable* full-line buffer must be **ping-pong** — line n+1 cannot be
  written into the buffer line n is being read from — so it is ~1280 flops
  / ~1900 cells (~2.6 % of a 14-tile console), not the ~960 quoted above.
- The interesting entry is not the full line. **~240 cells buys immunity
  to the one stall whose size is actually known** (tCEM, 8 µs, documented
  in `pmod-cartridge/fpga/README.md`). That is a rounding error against
  any console tile budget.

### The real gap: the working-set depth is never specified

§3 says video runs from "a handful of tile indices and pattern bytes held
in flops" and never says how many. Every safety claim in §5 and §6 depends
on that number:

- to survive one 16 B CPU burst (1.28 µs) video needs **≥ 3 bytes** buffered;
- to survive a tCEM-bounded PSRAM stall (8 µs) it needs **≥ 19 bytes**.

As written, the design may already be safe against the first and is almost
certainly not safe against the second — but nobody can tell, because the
depth is not in the document. **Specify the working-set depth in bytes,
and state which stalls it covers.** That single number is more important
than the line-buffer decision itself, because it is what makes §6's margin
either real or decorative.

**Recommendation:** replace the closed "no line buffer" conclusion with an
explicit depth choice. The engineering recommendation is **≥ 20 bytes**
(~240 cells) as the floor, because it is cheap and it covers the only
stall with a known magnitude; going to a full ping-pong line buffer
(~1900 cells) is a further, defensible purchase that converts video from a
hard-real-time master into a throughput one and would simplify §5. Both
are affordable; "none" is the only option the corrected arithmetic does
not support.

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

---

# Addendum — 2026-07-22, reconciliation with `research/console-architecture.md`

The review above was written against the project's own measured data. This
addendum brings a cited deep-research report (real 8/16-bit console
hardware + shipped TinyTapeout QSPI-video ASIC + the APS6404 datasheet) to
bear on it. **Net: the review above holds. External evidence *corroborates*
its most contested call (F1), *resolves* two of its open items, adds one
new blocking item (page-wrap), and exposes one coupling the review states
inconsistently (quantum ↔ buffer depth).**

## A1 — F1's line-buffer thesis is confirmed by shipped silicon and by history

F1 argued, against the spec, that a race-the-beam design *should* carry an
elastic buffer and that "none" is unsupported. Two independent external
data points confirm it:

- **A shipped TT09 ASIC does exactly this and no more.**
  `tt_um_MichaelBell_rle_vga` generates 640×480@60 VGA directly from QSPI
  flash with no framebuffer and no line buffer — carrying **only a small
  internal FIFO**, and imposing minimum-run constraints precisely to keep
  that FIFO from depleting. Same Sky130/TT/QSPI regime as this console.
  This is the concrete existence proof F1 was reasoning toward. [research
  Finding 7]
- **Every real 8/16-bit machine carried a buffer** — but at tile/attribute
  granularity, not pixels (VIC-II 40×12-bit filled on Bad Lines and reused
  8 lines; ANTIC 48-byte). "Zero storage" is stronger than anything real
  hardware did; a *pixel* line buffer is stronger than necessary. F1's
  "depth is a spectrum" framing is exactly right, and history says buffer
  the **working set**, not the pixels. [research Finding 1]

The one refinement: the spec's own claim (a) "prefetch line n+1
continuously" and claim (b) "no line buffer" are **mutually contradictory**
— prefetching a line needs somewhere to hold it. The historical/rle_vga
resolution is **just-in-time fetch into a small FIFO keyed to the current
scan position**, not whole-line prefetch. Adopt that framing in the spec;
it dissolves the contradiction and is the same object F1 calls "depth."

## A2 — F7 sharpened: tCEM is a data-CORRUPTION limit, not a stall to absorb — and the grade is now resolved

F7 correctly cited tCEM as an upper bound on the quantum. Two corrections
from the primary APS6404 datasheet:

1. **Holding CS# low past tCEM does not stall — it corrupts stored data**,
   by starving the self-managed refresh. Obeyed, refresh is fully hidden
   and there is **no** periodic "refresh stall" to absorb; violated, RAM is
   silently wrong. So the arbiter needs a **hard invariant**: no grant may
   hold CS# low longer than tCEM, *regardless of priority or fairness* —
   this outranks every §5 rule. [research Finding 6]
2. **The grade question is resolved.** The fabricated board's part is
   `APS6404L-3SQR-SN` (`pmod-cartridge/bom.csv:19`) — the **-SN
   standard/industrial grade** — and the project's own bring-up doc records
   **tCEM = 8 µs** (`pmod-cartridge/fpga/README.md:96`). So the standard
   ~100 B/burst budget applies; the extended-grade 3 µs / ~37 B cap the
   research flagged as a risk does **not** bind this board. Record this in
   the spec so a future respin to an extended-grade part is a conscious
   re-derivation, not a silent brick.

## A3 — the coupling F1/F7 state inconsistently: quantum **is** buffer depth

This is the one real internal tension in the review above, worth making
explicit because it drives both the tile budget and the arbiter.

Worst-case time video waits for the bus (highest priority, preemption at
burst boundaries only) = **one in-flight foreign burst** = the quantum.
For a Q-byte quad burst: (2Q + 14 command clocks) × 40 ns. Video consumes
120 B / 51.2 µs visible ≈ **1 byte / 427 ns** (F1's own rate). So the
required video buffer depth falls straight out of the quantum:

| quantum Q | worst-case block | buffer needed | bus efficiency |
|---|---|---|---|
| **16 B** (spec §5, endorsed by F7) | 1.84 µs | **~4–5 B** | ~70 % |
| ~64 B | 5.68 µs | ~13 B | ~82 % |
| ~96 B (near tCEM max) | 8.24 µs | **~20 B** | ~87 % |

F1 recommends **~20 bytes** of buffer; that figure silently assumes a
**~96 B quantum**, not the 16 B the same review endorses in F7 and §5. With
a 16 B quantum you need only ~4–5 B and F1's "one CPU burst, marginally"
row is the operative one. **Pick the pair together:** the research's
command-overhead math (14 clocks/burst → 16 B ≈ 70 %, larger is better)
pushes toward a **~64–96 B quantum**, which is what *justifies* F1's 20-byte
buffer and lands ~85 % efficient while staying inside the 8 µs / ~100 B
tCEM ceiling. Recommend replacing the spec's 16 B with **~64–96 B** and
sizing the video FIFO to one quantum's worth of consumption (~13–20 B).
This makes A1's "small FIFO" and F1's "depth" the *same* number as the
quantum — one decision, not three.

## A4 — NEW blocking item (F10): 1 KB page-wrap silently corrupts a linear fetch

Not in the review above and invisible in any flat sim model. APS6404 read
bursts **wrap within a 1024-byte page**: a linear scanline fetch that
crosses a 1 KB boundary silently **re-reads the start of the same page**
instead of continuing. [research Finding 6] Two fixes, pick one in RTL:

- **align** each scanline's data to PSRAM 1 KB pages (pad the layout), or
- **split** at the boundary in the arbiter/QSPI controller — any burst
  crossing a 1024 B line becomes two commands.

Either way this must be a **cocotb test against a bit-level PSRAM model**
that reproduces the wrap. A flat `mem[addr]` Verilator/cocotb model passes
the buggy design and the fault appears only in silicon. `tt-riscv/fpga`
already ships APS6404/W25Q state machines that model CS/SCK edges — reuse
that model here rather than a flat array. (Same lesson the review's testing
should carry for the tCEM invariant in A2: a flat model never violates it.)

## A5 — NEW: the fetch-hook budget is stated two incompatible ways (blocking, ties to F2 / §8.2)

Reading the actual timing core: `src/vga_timing.sv:20–26` states the fetch
engine has **6.4 µs of blanking** to land a full line, and `line_fetch`
fires at `hcnt == H_VIS` (start of h-blank) naming `next_y = vcnt+1`
(`vga_timing.sv:92–93`). But spec §2 says the fetch needs the **whole
32 µs line** and asserts "`line_fetch` marks the start of that window." At
`hcnt == H_VIS` only the 6.4 µs blanking remains before `next_y`'s visible
window — **not** 32 µs. The two documents disagree, and the correct one
(§2: 6.4 µs is provably too short) is contradicted by its own RTL.

The only way to actually get 32 µs is to fetch line k during the *drawing*
of line k−1, i.e. the engine runs **one line behind** and `line_fetch(k)`
means "you have a full line to prepare k." That is a real, unstated **1-line
pipeline latency** (and `next_y` must then be offset, or the image shifts
down one scanline). This is the same question as F2 (one-line vs two-line
fetch) and §8.2 (double working set), made concrete in the RTL. **Pin the
pipeline depth down before any worst-case arbiter analysis** — every number
in §6 and A3 depends on which line the fetch is actually racing.

## A6 — schedule vs arbiter: the demand arbiter is a deliberate departure, not the norm (non-blocking, but say so)

Every real machine allocated the shared bus by a **fixed positional
time-slot schedule** keyed to raster position (VIC-II cycles 15–54 +
static per-sprite slots; ANTIC's fixed cycle map; Amiga's 226-slot
4+3+4+16+80), **not** a request/grant priority arbiter with burst quanta.
[research Findings 2, 3] The spec's fixed-priority demand arbiter is a
*forced adaptation* to QSPI's atomic-burst nature (you cannot interleave
half a quad burst the way a cycle-steal interleaves φ1/φ2) and to a
**bursty** CPU (unlike the fixed-rate 6502/68000, a stalled RV32 XIP fetch
has no fixed cadence to slot into). Both make the demand arbiter
defensible. But two things are worth importing from the historical answer:

- **State it as a deliberate departure** in §5, with the QSPI-atomicity and
  bursty-CPU justification — don't present fixed-priority as the obvious
  choice; it isn't the one hardware reached for.
- A fixed **cyclic schedule** remains a live alternative worth a paragraph:
  it makes degradation **deterministic and testable** (the historical
  failure mode is deterministic sprite dropout — highest-numbered first on
  the Amiga — not random tearing [research Finding 5]), at the cost of
  flexibility against the bursty CPU. If the video mode and sprite count
  are fixed (they are), a static schedule may be simpler to verify than a
  priority arbiter. Not a blocker; a design fork to record.

Also confirmed by history and worth keeping: the review's atomicity rule
(§5.1, "never abort a burst mid-flight") has a direct hardware precedent —
the VIC-II deasserts BA three cycles ahead of AEC precisely to let the
CPU's in-flight writes drain before handover. [research Finding 4] Keep it;
for PSRAM it is not just correctness but the A2 anti-corruption invariant.

## A7 — F3 (sprites) stands; exact per-line numbers remain unverified

The research could **not** verify NES / Atari-2600 / Genesis / SNES
per-scanline sprite-fetch schedules (only C64/ANTIC/Amiga survived). So F3's
"+32–40 B/line" estimate is still an estimate — budget it conservatively
and do not cite a specific machine's number as settled. What *is* confirmed:
under bus pressure sprite dropout is **deterministic given the schedule**
(designable, cocotb-assertable), not random glitching. [research Findings
1, 5; caveats] If the design leans on a specific machine's sprite model, it
needs a dedicated primary-source pass (NESdev PPU/OAM, Genesis VDP docs).

## Consequences elsewhere (not edited — flagged for the owning sessions)

- **`PLAN.md` phase 2** says "no framebuffer and no line buffer (see spec §3
  for why neither is affordable)" (`PLAN.md:58`). That premise is the one
  F1 overturns. Update it once the line-buffer/quantum fork (A3) is decided
  — it currently instructs the video-engine phase to build the option the
  review rejects.
- **The spec §3 cell-cost** (4.8 cells/flop) is the whole-CORDIC ratio, not
  a storage-bit marginal cost — F1 already corrects this to ~1.5 for a
  shift-register buffer. Carry that correction into any tile-budget math.

## Decisions this review now puts to the user (costs money / picks a shape)

1. **Quantum + buffer depth as one choice (A3).** Recommended: **~64–96 B
   quantum + ~13–20 B video FIFO** (≈85 % bus, inside the 8 µs tCEM). The
   cheaper 16 B/4 B pair is valid but wastes ~30 % of the bus. This sets
   part of the tile budget.
2. **Line-buffer depth beyond the FIFO (F1 fork).** The ~20 B FIFO is
   nearly free; a full ping-pong line buffer (~1900 cells) converts video
   from hard-real-time to throughput and simplifies §5 — a real purchase
   against the tile count. User call, as F1 said.
3. **Pipeline depth of the fetch (A5).** One line behind (needs `next_y`
   offset) vs two-line spreading — changes the RTL and the deadline math.

## Updated recommended sequence (supersedes the list above)

1. Decide the **quantum + FIFO-depth pair (A3)** and the line-buffer fork
   (F1) together — they are one tile-budget decision, user call.
2. Pin the **fetch pipeline depth (A5)** and reconcile `vga_timing.sv` ↔
   spec §2 — mechanical once decided, but blocks the deadline math.
3. Add the **tCEM anti-corruption invariant (A2)** and **page-wrap
   handling (A4)** to §5/§7 as hard rules — these are device requirements,
   not tuning knobs.
4. Add a sprite line to §4 (F3), fix §4/§6 to peak-basis (F2), patch §7
   (F5, F6) — as the original list.
5. RTL: quad QSPI controller (MMIO 1-bit fallback), then the arbiter, with
   a **bit-level flash/PSRAM cocotb model** (reuse `tt-riscv/fpga`) that can
   actually exercise A2 and A4 — a flat memory model cannot.
