# QSPI memory arbiter — specification

**Status: DRAFT — REVIEWED 2026-07-21, see
[`qspi-arbiter-review.md`](qspi-arbiter-review.md).** The arbitration
policy (§5) passed review and may go to RTL. Four items must be fixed
first: **§3's "no line buffer" conclusion is wrong** (the cost was
overstated 3-5x and compared against the wrong tile budget — the decision
is re-opened), **§4/§6 budget averages where peak is required** (120 B,
not 60 B, on a fetching line), **sprites are missing from the bandwidth
model entirely**, and **§7 has no write-data channel**. Do not commit RTL
against §3, §4 or §7 until they are revised.

---

## 1. The problem

The console has one memory bus. A TinyTapeout tile has no RAM, so every
byte the machine touches — program code, level data, sprite patterns,
audio samples — arrives over the QSPI link on `uio`, shared between one
flash (ROM) and one PSRAM (RAM), exactly as the cartridge Pmod wires it.

Three masters want that bus at once:

| master | pattern | consequence of being late |
|---|---|---|
| video | strictly periodic, hard deadline, large | visible corruption on screen, every frame |
| audio | periodic, soft deadline, tiny | click or dropout, audible |
| CPU | bursty, no deadline | game runs slower |

Only one of them has a deadline that the user sees instantly. That
single fact determines the whole policy.

## 2. Bus bandwidth, measured in the units that matter

At a 25 MHz system clock:

| mode | bits/clk | ns per byte | bytes per 640-pixel scanline (32 µs) |
|---|---|---|---|
| 1-bit SPI | 1 | 320 | 100 |
| quad SPI | 4 | 80 | 400 |

The horizontal blanking interval — the "free" window between visible
lines — is only 160 pixel clocks, **6.4 µs**, i.e. 20 bytes single-bit
or 80 bytes quad. That is nowhere near a scanline's worth of graphics,
which is the first hard conclusion:

> **The video fetch cannot live in blanking.** It must run continuously,
> fetching line *n+1* while the beam draws line *n*, using the whole
> 32 µs line time. `vga_timing.line_fetch` marks the start of that
> window and `next_y` names the line to prepare (src/vga_timing.sv).

## 3. Why there is no line buffer

The obvious answer — buffer a scanline, fill it during blanking — needs
640 px × 2 bpp = 1280 flip-flops. On the measured cell economics of this
project (CORDIC-1: 921 cells for 191 flops, i.e. ~4.8 cells per flop) a
1280-bit line buffer alone is ~6100 cells, five times the entire 1x2
tile that the vertical slice occupies. A line buffer is not affordable
at any tile count we would actually buy.

So pixels are produced as the beam arrives, from a *small* working set:
a handful of tile indices and pattern bytes held in flops, refilled
continuously. The arbiter's job is to keep that trickle unbroken.

## 4. Video bandwidth by mode (the decision this document exists for)

Assume 8×8 tiles, 2 bits per pixel, one tile-map byte and two pattern
bytes per tile per scanline.

| video mode | tiles/line | bytes/line | quad time | % of a 32 µs line |
|---|---|---|---|---|
| 640×480, 1:1 | 80 | 240 | 19.2 µs | 60 % |
| 320×240, pixel-doubled | 40 | 120, reused for 2 lines → **60** | 4.8 µs | **15 %** |
| 640×480, 4 bpp chunky (no tiles) | — | 320 | 25.6 µs | 80 % |

**Recommendation: 320×240 pixel-doubled tiles.** It leaves ~85 % of the
bus to the CPU, it is the resolution class the Atari-2600/early-80s
target implies anyway, and the vertical doubling halves the fetch rate
for free (a tile row fetched for line *n* is still valid for line *n+1*).
640×480 1:1 is possible but starves the CPU to a crawl; the chunky mode
is a demo, not a console.

**Quad mode is mandatory in every row of that table.** At 1-bit even the
320×240 mode needs 19.2 µs of a 32 µs line. This is the concrete
justification for backlog item 2 (Quad-SPI v2) — and the reason its MMIO
fallback to 1-bit must exist, because a chip that can only boot in quad
mode is a chip that a flash QE-bit misfire can brick.

## 5. Arbitration policy

Fixed priority, preemptive at transaction boundaries only:

```
   video  >  audio  >  CPU instruction fetch  >  CPU data
```

Rules:

1. **Transactions are atomic.** A QSPI burst is never abandoned
   mid-word — the flash has no way to be interrupted and resumed
   cheaply. Preemption happens between bursts.
2. **Bursts are quantized** to bound the blocking time a low-priority
   master can inflict on a high-priority one. Maximum burst: 16 bytes
   (1.28 µs quad). Video's worst-case wait is therefore one in-flight
   CPU burst, 1.28 µs, against a per-line slack of 32 − 4.8 = 27 µs.
3. **Video may not be starved, and cannot starve others.** Video's own
   demand is capped at its mode's byte count per line; once the line's
   fetch is complete the video master drops its request until the next
   `line_fetch`.
4. **Audio is small and periodic**: one sample fetch per audio tick
   (≈ 8 kHz → one byte per 125 µs, 0.06 % of the bus). It sits above the
   CPU only so that a long CPU burst train cannot make it click.
5. **The CPU is the elastic master.** Everything left over is its. It
   sees a variable-latency memory, which its existing req/ack handshake
   already tolerates (TinyRV32 ships with exactly that interface).

## 6. Latency budget (320×240 mode, quad, 25 MHz)

| item | time | note |
|---|---|---|
| line period | 32.0 µs | 800 pixel clocks |
| video fetch per line | 4.8 µs | 60 B, every other line 0 B |
| worst-case blocking by a CPU burst | 1.28 µs | 16 B quantum |
| video slack | ~26 µs | > 5× the fetch itself |
| audio share | 0.06 % | one byte per 125 µs |
| CPU share, typical | ≈ 85 % | ~10.6 MB/s effective |

The margin is deliberately large. Race-the-beam designs fail *visibly*
and *every frame* when the margin is thin, and this one has to survive
PSRAM refresh stalls and flash access latency that are not yet measured.

## 7. Interfaces (RTL contract, to be reviewed)

```systemverilog
// one per master; the arbiter multiplexes them onto the QSPI controller
input  wire        req;      // hold high until ack
input  wire        we;       // 0 = read, 1 = write (CPU data only)
input  wire [23:0] addr;     // byte address; bit 23 selects flash/PSRAM
input  wire [4:0]  len;      // burst length in bytes, 1..16
output wire        ack;      // one cycle, burst accepted
output wire [7:0]  rdata;    // streamed, one byte per rvalid
output wire        rvalid;
```

Video and audio are read-only masters; only the CPU may write.

## 8. Open questions for review

1. Is fixed priority enough, or does the CPU need a guaranteed floor
   (e.g. one burst granted per line, no matter what) to avoid pathological
   starvation during full-screen scrolling?
2. Does the video master need a *double* working set (fetch line n+2
   while drawing n) to absorb PSRAM refresh, or is 26 µs of slack enough?
3. Burst quantum: 16 B is a guess balancing blocking time against QSPI
   command overhead (each burst costs a command + address ≈ 8 bytes of
   bus time — 33 % overhead at 16 B, 60 % at 4 B). Measure before fixing.
4. Should audio outrank video during vertical blanking, where video is
   idle anyway? (Probably moot — video does not request there.)
5. Flash and PSRAM are separate chip selects on one bus: does a
   cross-device switch cost anything beyond the CS toggle, and does that
   change the burst quantum?

## 9. What is already proven

Not speculation — these exist and pass:

- TinyRV32 boots from the cartridge flash by XIP through its req/ack
  memory interface, in simulation, both plug orientations (`tt-riscv/fpga`).
- The cartridge Pmod carries flash + 8 MB PSRAM + the audio RC chain, is
  fabricated and ordered, and its bring-up bitstream is simulated.
- The video timing core and its fetch hooks exist and are verified here
  (`src/vga_timing.sv`, `test/test_vga_timing.py`).

What does not exist yet is the arbiter itself, and the quad-mode QSPI
controller it assumes.
