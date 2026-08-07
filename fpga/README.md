# Console prototype on the ULX3S 85F — first power-up

This is the procedure for the day the board arrives. **Nothing in this
directory has ever been on hardware.** Everything below is rehearsed in
simulation and place-and-routed in CI, which is exactly why the checklist is
ordered the way it is: each step is chosen so that the *next* step's failure
has only one plausible cause left.

What is already proven, and what is not:

| Proven | How |
| --- | --- |
| The design fits and closes timing | CI `fpga` workflow: **64.27 MHz post-route, PASS at 25 MHz**; 6401 LUT (7 %) and 2493 FF (2 %) of the 85F |
| Card -> loader -> flash -> XIP boot -> running game | `python test/run.py rehearse`, using the real `sw/game.bin` and the real `tools/sdwrite.py` |
| The loader's awkward cases | `python test/run.py sdload` — empty slot, foreign card, bad checksum, second-boot skip, card-detect unwired |
| **The header permutation and the straps** | `python test/run.py fpga` — the only suite that elaborates `ulx3s_top`; boots through the J1 wires in both seatings, checks J2 against the VGA bit order, and requires a *wrong* SW1 to fail |
| Every pin is constrained, on the right ball | `python fpga/check_pins.py`, also a CI gate: 59 ports, 59 LOCATEs, all 59 sites diffed against upstream `emard/ulx3s doc/constraints/ulx3s_v20.lpf` (2026-08-02), clock constrained, no Pmod straddling two footprints |
| **The card writer aims at the right sectors** | `python -m pytest tools/test_sdwrite.py`, also a CI gate: whole-disk targets only, volume and partition paths refused by name. The format was always tested; *where the bytes land* was not, and was wrong — see step 4 |
| **ANSWERED: it is a v3.1.8, NOT a v2.0** | silkscreen, read by eye 2026-08-06. 58 of 59 sites are unaffected; `wifi_gpio0` moved L2 → F1 and is fixed in `ulx3s.lpf` |
| **The clock, LEDs, buttons, DIP switch and onboard audio DAC all work** | first power-up 2026-08-06 — see below |
| **NOT proven: any Pmod wire or connector** | **J1/J2 ship UNPOPULATED** — nothing can be plugged in until headers are soldered |
| The flasher works | **`fujprog`**, bundled in oss-cad-suite. Load `environment.ps1` first (step 0) |
| **NOT NEEDED: Zadig / WinUSB** | `fujprog` reaches the FT231X through FTDI's stock D2XX driver, so **the COM port survives**. `openFPGALoader` would need WinUSB and would destroy it |

## FIRST POWER-UP — 2026-08-06. What the board actually did.

The ULX3S arrived and this checklist was run for real. Everything below is
observed, not simulated. **The first design this project has ever run on
hardware.**

| Step | Result |
| --- | --- |
| Board revision | **v3.1.8** (silkscreen). ⚠ The FT231X EEPROM string says `ULX3S FPGA 85K v3.0.8` and is **stale factory data** |
| JTAG | **`IDCODE 0x41113043`** = LFE5U-85F, read off the chip |
| Configuration | `console.bit` → SRAM in **55.69 s**; status register **`DONE=1`, `FAIL=0`**, no BSE or exec error |
| **Step 2 PASS** | **all 8 LEDs cycling = the frame counter** — the loader completed its no-card path *and* vsync is pulsing, i.e. video timing is running |
| Onboard audio | **works** — proven separately with `tune_top.sv` (below) |
| Steps 3-6 | **BLOCKED**, see below |

### 🔴 The blocker nobody predicted: J1 and J2 ship UNPOPULATED

They are **bare plated through-holes**. Radiona ships the ULX3S without GPIO
headers so the buyer chooses the type. **No Pmod can be attached to this board
at all** until 2.54 mm **female** sockets are soldered — female because the
Cartridge Pmod and both TT Pmods have male pins.

This blocks steps 3-6 here *and* koti's bring-up, since both designs put every
Pmod on J1. It does **not** block anything above: the whole first power-up ran
with no header, no Pmod and no card. Parts are logged in `ASIC/SHOPPING.md`.

### 🪤 Traps found the hard way, all of which cost time

- **`fujprog -i` LIES.** It reports `FPGA IDCODE: FFFFFFFF` on a perfectly
  healthy board, **and exits 0**. It uses the legacy ULX2S pin map, where TDO
  is DCD; the ULX3S map has TDO on CTS. Programming is completely unaffected.
  ⛔ Never use `-i` as a health check, and never gate on its exit code.
  (`fujprog -d` segfaults, `0xC0000005`.)
- **All eight LEDs dark is a NORMAL state, not a dead board.** `ulx3s_top.sv`
  has `if (sw[3]) led = pad_btn[7:0]`, so with **DIP switch 4 ON** and no
  Gamepad Pmod the receiver correctly reports *no buttons* → `0x00`. ⇒ **Set
  all four DIP switches OFF before reading anything into the LEDs.** `0x00`
  appears nowhere in the status table below, which is the tell.
- **`openFPGALoader` cannot reach the board** with FTDI's stock driver — it
  needs libusb/WinUSB, and fails at `usb_open()`. Binding WinUSB with Zadig
  would work *and would destroy the COM port*, which is koti's kernel console.
  Use `fujprog`; it also has `-t` for a terminal, so one tool covers both.
- **The two rows of "Max frequency" again.** Take the **last**.

## ✅ RUNG 0 PASSED — **HDMI WORKS. The Tiny VGA Pmod is off the video critical path.**

**New scope, user directive 2026-08-06: a console that needs no Pmod at all** —
FPGA BRAM instead of the cartridge Pmod, the onboard 3.5 mm jack instead of the
Pmod's, **GPDI/HDMI instead of the Tiny VGA Pmod**, and the ULX3S buttons
instead of the Gamepad Pmod. ⛔ **Nothing is deleted.** Every Pmod path stays,
behind a build-time flag, so the Pmods can still be tested when they arrive.

| Rung | What | State |
| --- | --- | --- |
| **0** | standalone GPDI colour bars, no SoC | ✅ **PASSED on hardware 2026-08-06** |
| **1** | GPDI fed from the real video engine | ✅ **PASSED on hardware 2026-08-07** |
| **2** | BRAM memory so the SoC boots `game.bin` | ✅ **PASSED on hardware 2026-08-07** |
| **3** | UP/DOWN/LEFT/RIGHT + B1/B2 → `ui_in` | ✅ **PASSED on hardware 2026-08-07** |

## 🎮 THE CONSOLE IS PLAYABLE WITH NO PMOD ATTACHED (2026-08-07)

Picture on the GPDI socket, code and data in the 85F's own block RAM, sound out
the onboard 3.5 mm jack, controls on the board's six buttons. Observed on the
bench: the game's brick border, scattered tiles and four ship sprites on the
monitor; all four direction buttons moving the player sprite; FIRE1 playing a
tone whose pitch follows it.

**8 % LUT4, 95 of 208 block RAMs, 126.20 MHz post-route on the 125 MHz TMDS
clock and 61.47 MHz on the 25 MHz SoC clock.**

⚠ That TMDS margin is **1 %**, against 140 MHz on the build one commit earlier.
Nothing changed in the video path; the difference is placement — a small block
that must run at 125 MHz inside a design that mostly runs at 25 MHz gets
scattered differently by every edit. It is deterministic for a given input, so
CI will not flip randomly, but a future change *can* tip it under. If it does,
read the critical path before adding pipeline stages (see rung 0's lesson): the
last two times, the cost was routing, not logic.

`-Pmod` still builds the original Cartridge-Pmod + Gamepad-Pmod design. Nothing
was deleted, only made selectable, and CI synthesises that variant too — else
those branches would rot silently until the day headers get soldered on.

⚠ Rungs 1 and 3 swapped places on 2026-08-07 (user directive: HDMI, then memory,
then buttons). Video before memory is also the better ladder — it meant the
memory rung could be *watched* rather than inferred from LEDs.

ⓘ **Audio needed no work at all.** `ulx3s_top.sv:186` already drives `audio_l/r`
from the same `audio_bit` as the cartridge Pmod — both jacks are live at once,
by design. Confirmed audibly on hardware.

`fpga/gpdi_test_top.sv` + `fpga/gpdi.lpf` + `fpga/pll_25_125.v`: 640x480@60 DVI
colour bars, **458 LUT4 / 207 FF / 1 PLL**, `149.95 MHz` post-route against a
125 MHz requirement. Build exactly like `tune_top.sv` below, with
`pll_25_125.v` **and `tmds_encoder.sv`** added to the yosys `read_verilog` line
and `-top gpdi_test_top`. (The encoder moved out of `gpdi_test_top.sv` when
rung 1 needed the same one — two copies of a DC-balance state machine is a bug
waiting for someone to fix only one of them. Behaviour is unchanged.)

**What it retired:** the ULX3S drives TMDS from **LVCMOS33D pseudo-differential
pins, which is not spec-compliant**, and a monitor is entitled to refuse it.
This one does not — colour bars, border and the walking marker all appeared.
That was the whole point of doing rung 0 before rungs 1-3.

Still true, and unretired: this is **DVI signalling on an HDMI connector** —
video only, no audio islands. Console's audio goes out the 3.5 mm jack anyway.

### Two things this cost, worth not re-learning

- **A clock ENABLE does not relax static timing.** The TMDS encoder only
  advances every 5th clock, but every path in it is still constrained at the
  full 125 MHz. First build: **90.28 MHz, FAIL.** Pipelining the encoder into
  three stages got it to 118.53 MHz — still failing.
- **The real cost was routing, not logic: 1.42 ns logic against 7.02 ns
  routing.** This design occupies a tiny corner of an 85F, so `pce` — a net
  every flop needs — fanned out from (95,9) to (9,13), **5.30 ns on one hop**.
  Registering `pce` (and synchronising `rst`) turns that long wire into
  flop-to-flop with a whole period to cross: **149.95 MHz, PASS.** More
  pipelining would have kept optimising the wrong thing. ⇒ **Read the critical
  path report before adding pipeline stages.**

## ✅ RUNG 1 PASSED — **THE CONSOLE'S OWN VIDEO IS ON THE HDMI MONITOR** (2026-08-07)

`console.bit` now drives the GPDI socket from the same `uo_out` bits that feed
the Tiny VGA Pmod. Both outputs are live at once; nothing was removed. Observed
on the bench: eight colour bars, the 2-pixel border, the per-frame walking
marker, and the LED status byte reading healthy.

**135.87 MHz** post-route on the 125 MHz TMDS clock and **61.97 MHz** on the
25 MHz SoC clock — so HDMI cost about 2 MHz of the console's own margin
(64.27 → 61.97) and 467 LUT4 (6401 → 6868, 8 % of the 85F).

### The three things between `uo_out` and a monitor

1. **`de` does not exist on a pin.** The chip spends all eight outputs on
   RGB222 + syncs, and DVI needs display-enable to know when to send control
   words. It cannot be recovered from the syncs, because a black visible pixel
   and a porch pixel are the same eight bits. So `ulx3s_top` runs a **second
   `vga_timing`** on the same clock and the same reset as the one inside the
   SoC. Identical counters released from identical resets stay in lockstep for
   ever — and `led[5]` is the standing proof, latching high if the replica's
   syncs ever disagree with the chip's pins. It has stayed dark.
2. **The two clocks are phase-locked but separate.** The SoC closes at 62 MHz
   and cannot move into the 125 MHz shift domain, so `dvi_tx.sv` *measures* the
   offset instead of assuming it: a flop toggles once per pixel, two flops in
   the shift domain sample it, and the edge that comes out lands `pce` in the
   middle of the pixel. Nothing depends on the PLL's CPHASE, so retuning the
   PLL cannot silently break the picture.
3. **Something to look at before there is a game.** `video_en` resets to 0
   (`src/sysregs.sv`), so until software writes SYSCTL the console outputs black
   *on purpose* — and "black screen, syncs fine" is indistinguishable from half
   a dozen real faults. The harness therefore draws a test card until the SoC
   emits its first non-black pixel, then gets out of the way permanently.
   Nothing to set; `led[4]` is the handover.

### The LED status byte

| bit | meaning | healthy |
| --- | --- | --- |
| `led[7]` | PLL locked | steady ON |
| `led[6]` | `dvi_tx` phase watchdog (sticky) | OFF |
| `led[5]` | timing-replica mismatch (sticky) | OFF |
| `led[4]` | the SoC has drawn a non-black pixel | ON once the game runs |
| `led[3]` | `bram_cart` saw an unimplemented opcode (sticky) | OFF |
| `led[2:0]` | frame counter | counting — `led[0]` shimmers at 60 Hz |

In the `-Pmod` build there is no fabric cartridge to report, so `led[3]` returns
to the frame counter (`led[3:0]`) and the loader's status byte takes over the
whole display until it releases the bus. With `CART_BRAM` that bad-opcode bit is
worth more than a fourth frame bit — it is the one that told us the SD loader
was still on the bus.

**DIP 4** overrides all of it and shows `ui_in` — the eight button bits the chip
is actually being handed.

### 🪤 A status LED that has not acquired yet is a status LED that always lies

The phase watchdog lit on the very first hardware run, next to a **perfect**
picture. It was not measuring the clock ratio; it was measuring reset phase.
The mod-5 counter free-ran from zero while reset released at an arbitrary point
between pixel edges, so the first edge arrived at a random count and latched the
fault essentially every time. `wd_armed` now lets the first edge *define* the
phase and checks every edge after it against that.

⇒ Any counter that judges a periodic event must acquire before it judges. The
give-away was the contradiction — a fault lamp lit over a working picture — and
the cheapest possible fix confirmed it, because a genuine off-cadence event
still latches the same bit.

## ✅ RUNG 2 — **THE CARTRIDGE, IN FABRIC** (`fpga/bram_cart.sv`)

J1 is a row of bare holes, so the memory the SoC boots from lives in block RAM.
`bram_cart` is a QSPI **device** sitting where the Pmod would, on the same eight
`uio` wires — not a shortcut. The chip still boots by XIP from "flash" 0 and the
video engine still races the beam against the same shared bus through the same
arbiter. An `ifdef` swapping `qspi_ctrl` for a BRAM port would have been less
work and would have meant the arbiter and the race-the-beam fetch — which are
*the engineering of this project* — never ran on hardware at all.

It implements `03h` read and `02h` write in 1-bit mode, the whole set the
console uses (`cfg` resets to 0 and `sw/game.c:89` leaves it there). Everything
else raises `bad_cmd`, on `led[3]`. A model that silently returned zeroes for an
opcode it did not understand would look exactly like working hardware running a
broken program.

### Three things that had to be right

- **`03h` has no dummy cycles.** The controller captures the first data bit in
  the cycle *after* the last address bit, so a BRAM read issued then arrives one
  edge late. The arrays are therefore 16 bits wide — two byte lanes — and the
  read is issued one edge **early**, when `addr[23:1]` is known and only
  `addr[0]` is still in flight. Both candidates arrive in time and `addr[0]`
  picks between them. A real W25Q128 does the same thing with an async array.
- **Each array must own its output register.** Written as one register fed by a
  mux of two memory reads, neither memory can absorb the flop, so yosys needs an
  asynchronous read port, `DP16KD` has none, and all four arrays fall back to
  distributed LUT RAM: **1 DP16KD, 16468 `TRELLIS_DPR16X4`, 74840 LUT4** against
  an 85F that has 83640. Register first, mux afterwards → **94 DP16KD, 558 LUT4**.
- **Address aliasing is a feature.** Each device decodes only as many low bits as
  it has bytes, so the 8 MB PSRAM window aliases onto 128 KiB. That is what lets
  **one** `sw/game.bin` run on both the real cartridge and this model: `crt0`'s
  `sp = 0x01800000` first pushes to `0x017FFFFC`, which aliases to the top of the
  window and grows down toward the tile map — exactly the layout `link.ld`
  describes, 64× smaller. No software change, no FPGA-only binary to drift.

### 🪤 Two traps, both found on hardware

- **Gating the loader's reset is not the same as taking it off the bus.** With
  `CART_BRAM` the SoC runs from cycle one, so its opening flash fetch happened
  while `ldr_owns` was still high: the model saw the *loader's* chip select, then
  saw CS drop mid-stream and decoded the fragment as an opcode. `bad_cmd` lit
  beside a game that had booted perfectly — i.e. it went right by luck, which is
  the least durable way for a race to go.
- **yosys unrolls `initial` loops.** A two-line loop zeroing 65536 words turned a
  40-second synthesis into one that had not finished in five minutes. It is now
  behind `` `ifndef SYNTHESIS ``; the ECP5 powers block RAM up zeroed anyway.

### Testing it

`test/tb_bram_cart.v` drives the **real** `src/qspi_ctrl.sv` against the model
and checks every case where the one-edge-early read could go wrong: odd start
addresses, bursts crossing 16-bit words, the 96-byte burst the arbiter issues,
the pattern table, and read-after-write at both lane parities.

```
python tools/mkhex.py sw/game.bin fpga/build/game_lo.hex fpga/build/game_hi.hex
iverilog -g2012 -o tb_bram_cart.vvp -s tb_bram_cart \
    src/qspi_ctrl.sv fpga/bram_cart.sv test/tb_bram_cart.v && vvp tb_bram_cart.vvp
```

Run it **from the repo root** — `$readmemh` paths are relative, and a `$readmemh`
that finds nothing is silent: the array stays X and the symptom is a CPU that
looks broken. It is plain Verilog rather than cocotb so it runs on the Windows
host too, and that paid immediately: it caught a *bench* bug first, where driving
`we` on the same edge the controller samples made the controller latch the
previous transaction's value — sending `03h` for the write and `02h` for the
read. The model was faithfully answering the wrong question.

⇒ **Never drive stimulus on the edge the DUT samples on.** It does not fail
loudly; it fails as a DUT that looks wrong.

## ✅ RUNG 3 — the board's own buttons

`btn[1]`=FIRE1→**B**, `btn[2]`=FIRE2→**Y**, `btn[3..6]`=**UP/DOWN/LEFT/RIGHT**.
They drive the *same* eight `ui_in` bits the Gamepad Pmod does, so the chip's
decode, the register map and `sw/console.h` are untouched — a different source
for `ui_in`, not a different interface. Select and Start have no button on this
board and read 0; `btn[0]` is PWR and is the reset.

`btn[1..6]` are `PULLMODE=DOWN`, so open reads 0 and pressed reads 1 — no
inversion. Two synchroniser flops first, because these are asynchronous
mechanical inputs and a metastable sample reaching the CPU's MMIO read is not
something anyone would diagnose as a button; then a ~2.6 ms sampling tick as a
debounce cheap enough to be obviously correct.

**DIP 4 now shows `ui_in` itself**, whichever source it came from — so "press a
button, watch an LED" separates a dead button from a dead decode from a dead
game, for the onboard buttons exactly as it did for the Pmod.

### `tune_top.sv` — the bring-up aid that needs no header

`fpga/tune_top.sv` + `fpga/tune.lpf` are a standalone ~200-LUT design, separate
from the console build (they are deliberately **not** in `sources.txt`). They
exist because they exercise the one signal path that works on a board with bare
J1/J2, which is the state this board is in:

```
yosys -q -p "read_verilog -sv fpga/tune_top.sv; synth_ecp5 -top tune_top -json tune.json"
nextpnr-ecp5 --85k --package CABGA381 --json tune.json --lpf fpga/tune.lpf --textcfg tune.config --freq 25
ecppack tune.config tune.bit && fujprog tune.bit
```

Hold **F1** for a melody, **F2** for a 440 Hz reference tone, the four
direction buttons for single notes; **DIP 1/2 set volume** (00 = full). `led[0]`
is a heartbeat, `led[6:1]` mirror the buttons, `led[7]` says a note is
sounding — so if the audio fails, the LEDs still separate "design not running"
from "button not arriving" from "oscillator silent".

⚠ Beware `Select-Object -First N` on a nextpnr pipeline in PowerShell: it
terminates the pipeline and **kills nextpnr mid-run**, printing plausible stats
while never writing the `.config`. Redirect to a log instead.

### About that Fmax, because it has been quoted three different ways

**64.27 MHz is the number.** It is the post-route figure from the `fpga`
workflow on `main`. Two wrong values were in circulation and both are
explainable, so they are recorded here rather than silently overwritten:

- **62.71 MHz** — correct once, for the commit *before* the Gamepad Pmod
  receiver and the onboard audio jack landed (6800 LUT / 2522 FF). Those two
  commits changed the design; the number moved with it.
- **61.95 MHz** — same story, one commit later (6405 LUT / 2493 FF).
- **53.72 MHz** — *not* a stale number but a different measurement. nextpnr
  prints `Max frequency for clock` **twice**: once straight after placement,
  from estimated wire delays, and again after routing, from the real ones. The
  post-placement estimate is the pessimistic one here, and an unlabelled grep
  of the log returns it first. The `report` step in `.github/workflows/fpga.yaml`
  now labels both and puts the post-route figure first, so the next person
  reads the right one off the job summary.

If you are re-deriving it: `grep "Max frequency for clock" nextpnr.log | tail -1`.
The first hit is the estimate, the last is the answer.

## Before you start: what you can actually run today

Per SHOPPING.md as of 2026-08-02, **everything this checklist needs is
bought**. What is *bought* and what is *in your hand* are still two different
columns, and this table keeps them apart on purpose — a delivery date is not a
verification.

✅ **UPDATE 2026-08-06: THE ULX3S ARRIVED, and so did the microSD card, the
3.5 mm cable and the speakers.** The one row that read "nothing below runs
without it" is now green, so this checklist has stopped being a plan and
started being a procedure. Start at step 1 and work down. **The only ❔ left is
the two TT Pmods** — everything else in the table is physically on the bench.

| Needed for | Bought | In hand |
| --- | --- | --- |
| **ULX3S 85F** | ✅ 2026-07-19 | ✅ **ARRIVED 2026-08-06** — the blocker is gone; everything below is runnable work |
| **Cartridge Pmod** (steps 3-4, 7) | ✅ | ✅ board #1 passed the pre-power bench check |
| **Monitor + VGA cable** (step 5) | ✅ | ✅ |
| **microSD card** (step 4) | ✅ | ✅ **2026-08-06** — SKU is Hama **microSDHC** 32 GB, i.e. the tested path; still worth reading the card face once |
| **Tiny VGA Pmod** (steps 5, 7) | ✅ | ❔ **still in transit** |
| **TT Gamepad Pmod** (step 6) | ✅ | ❔ **still in transit** — in stock again as of 2026-08-03, so the out-of-stock worry is closed |
| **3.5 mm cable + speakers** (step 7) | ✅ | ✅ **2026-08-06** |

The two SNES pads are bought, but on their own they are **not a controller
path**: they plug into the Gamepad Pmod, and `src/snes_pad.sv` is not
instantiated anywhere in the harness. See "If the Gamepad Pmod does not turn
up" below — on an FPGA that is a solvable problem, and it was not solvable on
silicon, which is why the design looks the way it does.

So the honest reading, as of 2026-08-06: **the ULX3S has landed and the two TT
Pmods have not.** That is exactly the case this section was written for — with
the board plus the cartridge Pmod you already have, you get step 2 today: LEDs
walking the loader status codes and then counting frames. That is a real result
(the design is alive and video timing is running) but it is not a game on a
screen; steps 4-6 need the card and the two Pmods.

`ui_in` is driven from the gamepad receiver and an absent Pmod reads as *no
buttons* rather than as garbage (tested — `test/run.py fpga`), so a missing
Pmod degrades safely. It also means **`sw/game.c` gates its tone on holding
B**, so with no controller the demo is silent as well as motionless — do not
read that as an audio fault.

### If the Gamepad Pmod does not turn up

**Largely moot as of 2026-08-03: the Pmod is in stock again**, so the order has
somewhere to come from. Kept because the underlying point is worth knowing
regardless: **the reason the raw SNES pads cannot be used is a silicon
constraint, and the console is no longer going to silicon.**

A bare SNES pad needs LATCH and CLK as *outputs*. TT's `ui` pins are
input-only, so on a chip the Gamepad Pmod (whose CH32V003 is the master) is
the only path that can exist — that is why `snes_pad.sv` was un-instantiated
on 2026-07-30. On the ULX3S none of that applies: `gp/gn[11..13]` are free and
can be driven as outputs, and `src/snes_pad.sv` is still in the tree, still
verified by five tests.

Re-instantiating it in the harness needs no Pmod, only a way to reach the pad's
7-pin plug — an extension cable to cut (~€12), or a socket breakout onto the
jumper wires already owned. `gp/gn[20..23]` is a free Pmod footprint with no
wifi or ADC sharing, so there is clean room for two pads (LATCH and CLK can be
shared; that is 2 outputs + 2 data inputs).

**Decision 2026-08-02: not building it. The Gamepad Pmod is the path.** It is
bought and back in stock, and duplicating the controller front end costs an
afternoon plus tests that would be wasted. This section stays only so that
nobody has to re-derive that a fallback exists — it does, the pins are free,
and the RTL is already written and tested.

## 0. Build the bitstream — and install the thing that flashes it

Do not run place-and-route locally (project compute policy). Either grab the
`console-fpga` artifact from the `fpga` workflow, or:

```
gh workflow run fpga.yaml && gh run watch
```

`powershell -File fpga\synth.ps1 -SynthOnly` is the local *fast check* — it
stops after yosys and only tells you the design still elaborates.

**`openFPGALoader` is already on this machine — but not on `PATH`.** It ships
inside oss-cad-suite (`~/opt/oss-cad-suite`, suite 20260717, openFPGALoader
**v1.1.1**, which is the current release). Nothing to download.

Run it directly and it dies with a bare `0xC0000135`, which is Windows for
*a DLL is missing* and reads like a corrupt install. It is not: the binary
needs the suite's own libraries. Load the environment first, in the same
shell:

```powershell
. "$env:USERPROFILE\opt\oss-cad-suite\environment.ps1"
openFPGALoader --version            # verified: openFPGALoader v1.1.1
```

Every flashing command below assumes you have done that in the shell you are
typing into. `environment.bat` is the cmd.exe equivalent; `start.bat` opens a
pre-configured shell.

**What genuinely cannot be done before the board arrives:** the ULX3S's FT231X
needs a **WinUSB** driver for openFPGALoader to claim it, and Zadig binds a
driver *to a connected device* — so this waits for hardware. It normally costs
you the board's virtual COM port, and normally that hurts; **here it does
not**, because this design does not use the FTDI UART at all (`ftdi_rxd` is
tied high in `ulx3s_top.sv` — all `uo` bits are VGA). There is no serial
console to lose.

- If you would rather not swap the driver, `fujprog` (the ULX3S-specific
  programmer) is bundled too and uses FTDI's own D2XX driver instead of
  WinUSB. It does **not** run as shipped: it needs `ftd2xx.dll` from FTDI's
  driver package, which oss-cad-suite does not include (verified — it fails
  with the same `0xC0000135`). That is the trade: Zadig once, or install the
  FTDI D2XX package.
- WSL is not a route: no USB access without `usbipd`. Flash from Windows.
- First thing with the board plugged in: `openFPGALoader --detect`. It should
  report an ECP5 idcode. If that works, USB, driver, cable and FTDI chip are
  all proven and any later failure is the design's, not the plumbing's.

## 1. Confirm the board revision BEFORE plugging anything in

Every pin site in `ulx3s.lpf` comes from the **v2.0** constraint file. If this
board is a different revision, some sites move, and the ones that move are the
ones nothing has validated.

- Find the revision silkscreen on the PCB.
- If it is not v2.0, diff `ulx3s.lpf` against the constraint file for that
  revision before continuing. Do not skip this because the bitstream builds —
  a wrong site builds perfectly and drives the wrong ball.

## 2. Power the board alone — no Pmods

Load the bitstream with nothing plugged into J1 or J2:

```
openFPGALoader -b ulx3s fpga/build/console.bit        # SRAM, volatile
```

**This one is gone at power-off.** It configures the FPGA directly and is what
you want while iterating. For a console you can simply switch on — no PC
attached — write it to the board's SPI configuration flash instead:

```
openFPGALoader -b ulx3s -f fpga/build/console.bit     # persistent
```

Do the volatile load first and get through this checklist with it; commit to
flash once the board behaves. A bad image in config flash is recoverable
(reflash it), but it boots on every power-up until you do.

⚠ **Set all four DIP switches OFF first** (away from the side marked `ON`).
**DIP 4 ON puts the gamepad buttons on the LEDs** (`if (sw[3]) led = pad_btn`),
and with no Gamepad Pmod that reads as *no buttons* — **all eight LEDs dark**,
which looks exactly like a dead board and is in fact correct behaviour. `0x00`
is not in the status table below; that is how you tell.

Expected: the LEDs show a **loader status code** (see the table below), and
with no card inserted it should settle at **0x82 (`ST_NOCARD`)** and then the
LEDs start **counting** — the frame counter, which means video timing is
running. Counting LEDs at this stage is the single best "the design is alive"
signal, and it needs no Pmod at all.
✅ **Observed 2026-08-06: the LEDs count.** This step passes on real hardware.

If the LEDs sit at `0x01` forever, the loader is stuck in SD init — that is a
microSD wiring/revision problem (step 1), not a logic problem.

## 3. Cartridge Pmod on J1, orientation strap

The Cartridge Pmod (`../../pmod-cartridge`, board #1 — the one that passed the
bench check) goes on **J1 = gp/gn 0-3**. Those four sites are the ones already
proven by an earlier bitstream, which is why the cartridge goes first.

- **SW1 selects the row mapping.** If the cartridge is not detected, flip SW1
  and re-check before suspecting the board: the strap exists precisely because
  the plug orientation is ambiguous. This is a switch flip, not a re-flash.
- Reset is **BTN0 (PWR), active low** — press to re-run the loader.

## 4. Write a card and load a game

```
python sw/build.py                                   # produces sw/game.bin
python tools/sdwrite.py sw/game.bin --out card.img   # dry run: no device touched
python tools/sdwrite.py --list                       # which disk is the card?
python tools/sdwrite.py sw/game.bin --device \\.\PhysicalDrive2 --yes
```

Do the `--out` run first — it produces the exact bytes that would go on the
card, so you can check the reported length and sum32 before anything is
written to a real device.

**The target is the whole disk, never a drive letter.** This is a correctness
rule before it is a safety one, and it is worth understanding rather than
copying: `sd_loader.sv` reads its header with CMD17 at block address 0 — the
first sector of the *card*. On Windows `\\.\E:` is the *volume*, whose sector 0
is the first sector of the *partition*, and an SD-spec-formatted SDHC card puts
that partition thousands of sectors in. Writing there succeeds, verifies, looks
perfect, and leaves the board reporting `0xE1 ST_E_MAGIC` — an error that
accuses the card. `/dev/sdb1` instead of `/dev/sdb` is the same mistake in
Linux spelling. `sdwrite.py` now refuses both by name and says why.

Run `--list` first to get the disk number: it prints every disk with its size,
bus type and drive letters, and marks the ones it would refuse. It needs no
elevation, so you can find the number before opening an Administrator shell —
which the write itself does need.

Other guards, all deliberate: the disk must be removable or on a USB/SD/MMC
bus, `PhysicalDrive0` is refused outright, anything over 64 GiB is refused, and
every byte written is **read back and compared** before the tool claims
success. On Windows the tool also locks and dismounts the card's volumes first;
without that, Windows refuses sector writes to a mounted filesystem even for an
Administrator, and the error it gives you says "access denied" as though you
had forgotten to elevate.

Insert the card, press BTN0, and watch the LEDs walk the status codes:
`0x01 -> 0x02 -> 0x03 -> 0x04 -> 0x05 -> 0x06 -> 0x80`. A **second** press should give
**`0x81` (`ST_SKIP`) almost immediately** — that is the resident-header compare
working, and it is the difference between a one-second boot and a minute of
needless flash wear.

## 5. Tiny VGA Pmod — the SECOND footprint on J1, gp/gn 4-7

⛔ **NOT the connector silkscreened `J2`.** The ULX3S manual is explicit:
`J1 GP,GN 0-13`, `J2 GP,GN 14-27`. gp/gn 4-7 is the second Pmod footprint along
the *same* header the cartridge sits on. This section used to say "J2 = gp/gn
4-7", which would put the Pmod on gp/gn 14-17 — **pins shared with the onboard
ADC**. It would plug in happily and produce no picture, and the Pmod would get
the blame. Corrected 2026-08-06.

Only now add video, on **gp/gn 4-7** — sites that have never been on hardware.
**SW2** flips the VGA row mapping the same way SW1 does for the cartridge.

What *is* settled without the Pmod: the J2 sites are diffed against upstream
(`fpga/check_pins.py`), and `test/run.py fpga` checks that `uo_out` reaches
`vga_gp`/`vga_gn` in the order the Tiny VGA Pmod expects, under both SW2
settings. What is not settled is everything past the connector.

## 6. TT Gamepad Pmod — bought 2026-08-02, but confirm it shipped

The Pmod goes on the **gp/gn[8..10]** block. All three signals (latch, clock,
data) are **inputs** — the Pmod's CH32V003 is the master. That is not a
convenience: `ui` is input-only on the chip, so a controller the chip must
clock itself can never work, and this Pmod is the only path that reaches
silicon. The decoder therefore lives in the **harness**, and the chip takes 8
already-decoded buttons.

- **SW3** flips the gamepad row mapping, same as SW1/SW2. Try it before
  suspecting the Pmod.
- **SW4 is the bring-up aid**: it puts `btn1[7:0]` straight on the LEDs.
  Press B, watch LED0. With a black-box Pmod and no cable to meter, this is
  the cheapest proof the controller path works end to end — do it before
  trusting a game to it.
- An unplugged port reports all 1s, which the receiver decodes as **not
  present, zero buttons**. If LEDs light up with nothing connected, that is
  wrong and worth stopping for.

The Pmod was **bought on 2026-08-02 and is in stock again as of 2026-08-03**,
so the earlier back-order worry is closed. Nothing here has met its hardware
either way. Everything up to the connector is checked
twice over: the protocol against the designer's own reference receiver
(`vendor/gamepad_pmod.v`, vendored verbatim, 8 tests in `test/run.py gamepad`),
and the SW3 row selection plus the SW4 LED aid at the pin level in
`test/run.py fpga`. That is the strongest evidence available short of the real
thing, and it is still not evidence about the real thing.

**The console is playable without it only in the trivial sense**: the game runs
and draws, but nothing moves, because `ui_in` is all zeros. This Pmod arriving
is the last thing between the current state and grand goal 1.

## 7. Sound — two jacks, same signal

The console has one audio source: a sigma-delta bit on `uio[7]`. It comes out
of **two** places at once, carrying an identical waveform:

| Output | What it is | Why you'd use it |
| --- | --- | --- |
| **Cartridge Pmod jack** | `uio[7]` into the Pmod's RC filter + amp + 3.5 mm jack | **The path the silicon will use.** Test here to validate the real analog chain. |
| **ULX3S onboard jack** | 4-bit R2R ladder per channel, driven full-scale from the same bit | Hear the console with no cartridge Pmod attached. |

Both need a 3.5 mm male-male cable into **powered** speakers or a line input;
neither drives a passive speaker meaningfully. The source is mono, so both
channels of the onboard jack carry the same signal.

Both go silent while the loader owns the bus, so sound starting up is itself a
sign the SoC was released. If the onboard jack is too loud, drive fewer of the
low `audio_l`/`audio_r` bits in `ulx3s_top.sv` to attenuate.

## Loader status codes (LED value)

While the loader is running or has errored, `led = ldr_status`. Once it
finishes cleanly the LEDs switch to a **frame counter**, so *counting LEDs
means video is alive*.

| Code | Meaning |
| --- | --- |
| `0x01` | `ST_INIT` — initialising the SD card |
| `0x02` | `ST_HDR` — reading the header block |
| `0x03` | `ST_CHECK` — comparing against the resident header |
| `0x04` | `ST_ERASE` — erasing cartridge flash |
| `0x05` | `ST_PROG` — programming |
| `0x06` | `ST_COMMIT` — writing the resident header (last, on purpose) |
| `0x80` | `ST_DONE` — image loaded, SoC released |
| `0x81` | `ST_SKIP` — already resident, nothing rewritten |
| `0x82` | `ST_NOCARD` — no usable card; booting whatever is in flash |
| `0xE0` | `ST_E_SD` — SD failed *after* init (a genuinely bad card) |
| `0xE1` | `ST_E_MAGIC` — the card is not ours (no `CTG1`) |
| `0xE2` | `ST_E_SUM` — checksum mismatch; header deliberately NOT committed |

`0x82` is not an error. Card detect (`sd_cdn`, N5) is marked *not connected*
in the ULX3S v2.0 constraint file, so the loader ignores it
(`USE_CARD_DETECT = 0`) and discovers an empty slot by init timing out
instead. If a card is inserted and you still get `0x82`, that is a real SD
problem — not the detect pin.

## Things that will look like bugs and are not

- **LEDs counting instead of showing a code** — that is success (step 2).
- **`0x82` with no card** — correct, by design.
- **Cartridge not found until SW1 is flipped** — expected; the strap is the
  orientation control.
- **A second boot finishing instantly with `0x81`** — that is the skip path
  working, not a failure to load.
