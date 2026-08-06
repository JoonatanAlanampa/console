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
