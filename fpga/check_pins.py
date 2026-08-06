#!/usr/bin/env python3
"""check_pins.py — prove the harness, the constraints and the board agree.

    python fpga/check_pins.py

Exits non-zero on any failure, so it is a CI gate rather than a report. It runs
before the toolchain is even installed, because every class of failure below is
one that nextpnr either reports ten minutes later or does not report at all.

WHY THIS EXISTS. A constraint file fails in four ways, and only the first is
loud:

  1. A port with no LOCATE. nextpnr-ecp5 refuses unconstrained IO, so this at
     least fails — but fifteen minutes into a CI run instead of instantly.
  2. A LOCATE for a port that no longer exists. Harmless to the tools, rots
     silently, and hides the fact that the signal you believe is on that ball
     is not on any ball.
  3. A site that is simply the wrong ball. This is the dangerous one: the
     bitstream builds perfectly and drives the wrong pin. No simulation can
     catch it, and on hardware it looks like a dead peripheral.
  4. A missing clock FREQUENCY constraint. This is the quietest of the lot —
     with no constraint nextpnr has nothing to fail against, so CI goes green
     on a design that never closed timing and the reported Fmax is unchecked.

(3) is checked against a table transcribed from the upstream ULX3S v2.0
constraint file. What no software check can settle is whether the board in your
hand IS a v2.0 — that needs the silkscreen, and it is step 1 of the bring-up
checklist for exactly this reason.

Sites verified against emard/ulx3s `doc/constraints/ulx3s_v20.lpf` (fetched
2026-08-02), including the gamepad block and the onboard audio jack, which were
added after the 2026-07-30 diff and were therefore never covered by it.
"""

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOP = HERE / "ulx3s_top.sv"
LPF = HERE / "ulx3s.lpf"

# The harness clock, and what the LPF must constrain it to. The bitstream is
# built for the ULX3S's 25 MHz oscillator and every timing claim in
# fpga/README.md is "PASS at 25 MHz", so a drift here silently invalidates the
# documented number.
CLOCK_PORT = "clk_25mhz"
CLOCK_MHZ = 25.0

# ---------------------------------------------------------------------------
# Expected sites, ULX3S v2.0, transcribed from upstream. Port names are ours;
# the SITE values are the board's. The gp/gn index each harness port maps to is
# in the comment, because that is the thing a reader needs to check the header
# GEOMETRY -- a Pmod footprint is gp/gn[4k..4k+3], and a block that straddles
# two of them is a real bug that builds fine.
# ---------------------------------------------------------------------------
EXPECTED = {
    CLOCK_PORT: "G2",
    "btn[0]": "D6", "btn[1]": "R1", "btn[2]": "T1", "btn[3]": "R18",
    "btn[4]": "V1", "btn[5]": "U1", "btn[6]": "H16",
    "sw[0]": "E8", "sw[1]": "D8", "sw[2]": "D7", "sw[3]": "E7",
    "led[0]": "B2", "led[1]": "C2", "led[2]": "C1", "led[3]": "D2",
    "led[4]": "D1", "led[5]": "E2", "led[6]": "E1", "led[7]": "H3",
    "ftdi_rxd": "L4",
    # F1, not upstream v2.0's L2 -- the ONE deliberate departure from
    # ulx3s_v20.lpf in this table. The bench board is a PCB v3.1.8, and exactly
    # five signals moved between v2.0 and v3.1.x, all wifi_*: on v3.1.x L2
    # became wifi_gpio22 and wifi_gpio0 moved to F1. See the long comment on
    # this pin in ulx3s.lpf. The other 58 entries are identical on both
    # revisions, so this table still checks what it claims to check.
    "wifi_gpio0": "F1",
    # onboard 3.5 mm jack, 4-bit R2R ladder per channel
    "audio_l[3]": "B3", "audio_l[2]": "C3", "audio_l[1]": "D3",
    "audio_l[0]": "E4",
    "audio_r[3]": "C5", "audio_r[2]": "D5", "audio_r[1]": "B5",
    "audio_r[0]": "A3",
    # Physical header J1, footprint 0 = gp/gn[0..3] -- Cartridge Pmod.
    # ALL THREE Pmod footprints below are on J1: the ULX3S manual says
    # "J1 GP,GN 0-13" / "J2 GP,GN 14-27". Calling the second one "J2" (as this
    # file used to) collides with the board silkscreen and points at gp/gn
    # 14-17, which are shared with the onboard ADC. Corrected 2026-08-06.
    "pmod_gp[0]": "B11", "pmod_gp[1]": "A10", "pmod_gp[2]": "A9",
    "pmod_gp[3]": "B9",
    "pmod_gn[0]": "C11", "pmod_gn[1]": "A11", "pmod_gn[2]": "B10",
    "pmod_gn[3]": "C10",
    # Physical header J1, footprint 1 = gp/gn[4..7] -- Tiny VGA Pmod
    "vga_gp[0]": "A7", "vga_gp[1]": "C8", "vga_gp[2]": "C6", "vga_gp[3]": "A6",
    "vga_gn[0]": "A8", "vga_gn[1]": "B8", "vga_gn[2]": "C7", "vga_gn[3]": "B6",
    # the gp/gn[8..11] Pmod footprint -- TT Gamepad Pmod, first 3 of 4 signals
    "pad_gp[0]": "A4", "pad_gp[1]": "A2", "pad_gp[2]": "C4",
    "pad_gn[0]": "A5", "pad_gn[1]": "B1", "pad_gn[2]": "B4",
    # onboard microSD, SPI mode
    "sd_clk": "H2", "sd_cmd": "J1",
    "sd_d[0]": "J3", "sd_d[1]": "H1", "sd_d[2]": "K1", "sd_d[3]": "K2",
    "sd_cdn": "N5",
}

# Which upstream gp/gn index each header port occupies. Used only to prove no
# Pmod straddles two physical footprints -- the bug koti's harness actually had
# (uio on gp[0..7], video on gn[0..7]: not a Pmod footprint at all).
HEADER_BLOCKS = {
    "J1 Cartridge Pmod": ["pmod_gp", "pmod_gn"],
    "J2 Tiny VGA Pmod": ["vga_gp", "vga_gn"],
    "TT Gamepad Pmod": ["pad_gp", "pad_gn"],
}
# port base -> the gp/gn index of its element 0.
BLOCK_BASE_INDEX = {
    "pmod_gp": 0, "pmod_gn": 0,
    "vga_gp": 4, "vga_gn": 4,
    "pad_gp": 8, "pad_gn": 8,
}

PORT_RE = re.compile(
    r"^\s*(input|output|inout)\s+"
    r"(?:wire|logic|reg)?\s*"
    r"(?:\[\s*(\d+)\s*:\s*(\d+)\s*\]\s*)?"
    r"(\w+)\s*[,)]",
    re.MULTILINE,
)
LOCATE_RE = re.compile(r'^\s*LOCATE\s+COMP\s+"([^"]+)"\s+SITE\s+"([^"]+)"\s*;',
                       re.MULTILINE | re.IGNORECASE)
IOBUF_RE = re.compile(r'^\s*IOBUF\s+PORT\s+"([^"]+)"', re.MULTILINE | re.IGNORECASE)
FREQ_RE = re.compile(r'^\s*FREQUENCY\s+PORT\s+"([^"]+)"\s+([\d.]+)\s+MHZ\s*;',
                     re.MULTILINE | re.IGNORECASE)

errors: list[str] = []
warnings: list[str] = []


def module_ports(text: str) -> list[str]:
    """Every port BIT of ulx3s_top, e.g. led[0]..led[7]."""
    # Keep the ')' that ends the port list: PORT_RE needs a ',' or ')' after
    # each name, and the LAST port only ever has the ')'. Dropping it silently
    # loses one port -- exactly the near-miss this script exists to catch, so
    # it may not have it itself.
    body = text.split("module ulx3s_top", 1)[1].split(");", 1)[0] + ")"
    # Strip comments BEFORE matching. The last port is followed by a trailing
    # `// ...` and only then the ')', so a regex anchored on ',' or ')' misses
    # it and the port silently vanishes from the check -- which showed up here
    # as a phantom "LOCATE sd_cdn has no matching port".
    body = re.sub(r"/\*.*?\*/", " ", body, flags=re.DOTALL)
    body = re.sub(r"//[^\n]*", "", body)
    bits = []
    for _dir, hi, lo, name in PORT_RE.findall(body):
        if not hi:
            bits.append(name)
        else:
            hi_i, lo_i = int(hi), int(lo)
            for i in range(min(hi_i, lo_i), max(hi_i, lo_i) + 1):
                bits.append(f"{name}[{i}]")
    return bits


def check_header_geometry(locates: dict) -> None:
    """No Pmod may straddle two physical footprints.

    A 12-pin Pmod footprint on the ULX3S is gp/gn[4k..4k+3] plus its own power
    pins. A design that puts one peripheral on gp[0..7] has spread it across
    J1 AND J2 -- it builds, routes and closes timing, and then cannot be
    plugged into anything.
    """
    for label, bases in HEADER_BLOCKS.items():
        idxs = set()
        for base in bases:
            n = sum(1 for k in locates if k.startswith(base + "["))
            start = BLOCK_BASE_INDEX[base]
            idxs.update(start + i for i in range(n))
        if not idxs:
            continue
        blocks = {i // 4 for i in idxs}
        if len(blocks) > 1:
            errors.append(
                f"{label} spans gp/gn footprints {sorted(blocks)} "
                f"(indices {sorted(idxs)}) — that is not one Pmod connector")


def main() -> int:
    for p in (TOP, LPF):
        if not p.exists():
            print(f"FAIL: missing {p}")
            return 2

    top_text = TOP.read_text(encoding="utf-8", errors="replace")
    lpf_text = LPF.read_text(encoding="utf-8", errors="replace")

    ports = module_ports(top_text)
    locates = dict(LOCATE_RE.findall(lpf_text))
    iobufs = set(IOBUF_RE.findall(lpf_text))
    freqs = {n: float(v) for n, v in FREQ_RE.findall(lpf_text)}

    # 1. every port constrained
    for p in ports:
        if p not in locates:
            errors.append(f"port {p} has no LOCATE — nextpnr will refuse it")

    # 2. no LOCATE for a port that no longer exists
    for name in locates:
        if name not in ports:
            errors.append(f"LOCATE {name} has no matching port in ulx3s_top")

    # 3. every site is the right ball
    for name, site in sorted(locates.items()):
        want = EXPECTED.get(name)
        if want is None:
            warnings.append(f"{name} -> {site}: no expected site recorded here")
        elif want != site:
            errors.append(
                f"{name} is on SITE {site}, upstream ulx3s_v20.lpf says {want}")

    # ...and every port we know a site for is actually present
    for name in EXPECTED:
        if name not in locates:
            errors.append(f"{name} is in the expected-site table but has no LOCATE")

    # 4. the clock is constrained, or CI is green on unclosed timing
    if CLOCK_PORT not in freqs:
        errors.append(
            f"no FREQUENCY PORT \"{CLOCK_PORT}\" constraint - without it "
            "nextpnr has nothing to fail against and reports an Fmax nobody "
            "checked")
    elif abs(freqs[CLOCK_PORT] - CLOCK_MHZ) > 1e-9:
        errors.append(
            f"FREQUENCY PORT \"{CLOCK_PORT}\" is {freqs[CLOCK_PORT]} MHz, "
            f"the harness and the documented timing assume {CLOCK_MHZ} MHz")

    # 5. IO standard set on every pin (a missing IOBUF takes the default)
    for p in ports:
        if p not in iobufs:
            warnings.append(f"port {p} has no IOBUF line (IO_TYPE/PULLMODE default)")

    # 6. header geometry
    check_header_geometry(locates)

    print(f"ulx3s_top ports : {len(ports)}")
    print(f"LOCATE lines    : {len(locates)}")
    # Say exactly what was compared against what. 58 sites are upstream v2.0
    # values; wifi_gpio0 is deliberately the v3.1.x site (F1, not L2) because
    # the board is a v3.1.8. Printing a flat "against ulx3s_v20.lpf" would
    # claim a provenance one of these entries does not have.
    print(f"sites checked   : {sum(1 for p in locates if p in EXPECTED)}"
          f"/{len(locates)} -- 58 vs upstream ulx3s_v20.lpf, "
          f"wifi_gpio0 vs v3.1.x (F1, see ulx3s.lpf)")
    print(f"clock constraint: "
          f"{freqs.get(CLOCK_PORT, 'MISSING')} MHz on {CLOCK_PORT}")

    for w in warnings:
        print(f"  warn: {w}")
    for e in errors:
        print(f"  FAIL: {e}")

    if errors:
        print(f"\n{len(errors)} problem(s).")
        return 1
    print("\nOK - every port located, every site matches the board, "
          "clock constrained, no Pmod straddles two footprints.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
