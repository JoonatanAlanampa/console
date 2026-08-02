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
| **NOT proven: that this board is a v2.0** | needs the board — see step 1 |
| **NOT proven: any wire, connector or signal integrity** | needs the board |

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

| Needed for | Bought | In hand |
| --- | --- | --- |
| **ULX3S 85F** | ✅ 2026-07-19 | ❌ **not yet arrived** — nothing below runs without it |
| **Cartridge Pmod** (steps 3-4, 7) | ✅ | ✅ board #1 passed the pre-power bench check |
| **Monitor + VGA cable** (step 5) | ✅ | ✅ |
| **microSD card** (step 4) | ✅ | ❔ confirm it is **microSDHC**, not full-size, not SDXC |
| **Tiny VGA Pmod** (steps 5, 7) | ✅ | ❔ |
| **TT Gamepad Pmod** (step 6) | ✅ | ❔ was out of stock 2026-07-29 — check the order actually shipped |
| **3.5 mm cable + speakers** (step 7) | ✅ | ❔ |

The two SNES pads are bought, but on their own they are **not a controller
path**: they plug into the Gamepad Pmod, and `src/snes_pad.sv` is not
instantiated anywhere in the harness. See "If the Gamepad Pmod does not turn
up" below — on an FPGA that is a solvable problem, and it was not solvable on
silicon, which is why the design looks the way it does.

So the honest reading: **the blocker is now delivery, not money.** Everything
below is a procedure waiting on boxes. When the ULX3S lands with only the
cartridge Pmod attached, you get step 2 — LEDs walking the loader status codes
and then counting frames. That is a real result (the design is alive and video
timing is running) but it is not a game on a screen; steps 4-6 need the card
and the two Pmods.

`ui_in` is driven from the gamepad receiver and an absent Pmod reads as *no
buttons* rather than as garbage (tested — `test/run.py fpga`), so a missing
Pmod degrades safely. It also means **`sw/game.c` gates its tone on holding
B**, so with no controller the demo is silent as well as motionless — do not
read that as an audio fault.

### If the Gamepad Pmod does not turn up

It was out of stock on 2026-07-29 with no restock date, so this is worth
knowing: **the reason the raw SNES pads cannot be used is a silicon
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
bought, and duplicating the controller front end costs an afternoon plus tests
that would be wasted if the Pmod ships. This section exists so that if the
order turns out to have been cancelled for being out of stock, nobody has to
re-derive that a fallback is possible — it is, the pins are free, and the RTL
is already written and tested.

## 0. Build the bitstream

Do not run place-and-route locally (project compute policy). Either grab the
`console-fpga` artifact from the `fpga` workflow, or:

```
gh workflow run fpga.yaml && gh run watch
```

`powershell -File fpga\synth.ps1 -SynthOnly` is the local *fast check* — it
stops after yosys and only tells you the design still elaborates.

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

Expected: the LEDs show a **loader status code** (see the table below), and
with no card inserted it should settle at **0x82 (`ST_NOCARD`)** and then the
LEDs start **counting** — the frame counter, which means video timing is
running. Counting LEDs at this stage is the single best "the design is alive"
signal, and it needs no Pmod at all.

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
python tools/sdwrite.py sw/game.bin --device <DEV> --yes
```

Do the `--out` run first — it produces the exact bytes that would go on the
card, so you can check the reported length and sum32 before anything is
written to a real device.

`sdwrite.py` refuses to touch anything that is not a removable device, and
refuses anything over 64 GiB. Both guards are deliberate; if it refuses, check
the device rather than removing the guard.

Insert the card, press BTN0, and watch the LEDs walk the status codes:
`0x01 -> 0x02 -> 0x03 -> 0x04 -> 0x05 -> 0x06 -> 0x80`. A **second** press should give
**`0x81` (`ST_SKIP`) almost immediately** — that is the resident-header compare
working, and it is the difference between a one-second boot and a minute of
needless flash wear.

## 5. Tiny VGA Pmod on J2 — ⚠ NOT BOUGHT YET (€15, in stock)

Only now add video, on **J2 = gp/gn 4-7** — sites that have never been on
hardware. **SW2** flips the VGA row mapping the same way SW1 does for the
cartridge.

What *is* settled without the Pmod: the J2 sites are diffed against upstream
(`fpga/check_pins.py`), and `test/run.py fpga` checks that `uo_out` reaches
`vga_gp`/`vga_gn` in the order the Tiny VGA Pmod expects, under both SW2
settings. What is not settled is everything past the connector.

## 6. TT Gamepad Pmod — ⚠ NOT BOUGHT, AND OUT OF STOCK

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

The Pmod is **not owned and was still out of stock on 2026-07-29**, with no
restock date, so none of this has met its hardware and this step is not
skippable-by-effort — there is nothing to plug in. Everything up to the
connector is checked twice over: the protocol against the designer's own
reference receiver (`vendor/gamepad_pmod.v`, vendored verbatim, 8 tests in
`test/run.py gamepad`), and the SW3 row selection plus the SW4 LED aid at the
pin level in `test/run.py fpga`. That is the strongest evidence available short
of the real thing, and it is still not evidence about the real thing.

**The console is playable without it only in the trivial sense**: the game runs
and draws, but nothing moves, because `ui_in` is all zeros. Ordering this Pmod
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
