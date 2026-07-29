# Build cartridge images for the console.
#   python sw/build.py            # -> sw/game.bin
#   python sw/build.py game       # same, explicitly
#
# Produces <name>.bin: a self-contained flash image holding code, rodata, the
# tile pattern table at 0x8000 and the .data load image. crt0 relocates .data
# and zeroes .bss at boot, so this file alone boots the machine — which is what
# sd_loader writes into the cartridge flash byte for byte.
#
# RV32E ABI is mandatory: the core is instantiated with NREGS=16, and only
# -march=rv32e -mabi=ilp32e stops GCC allocating x16..x31.
#
# Copyright (c) 2026 Joonatan Alanampa
# SPDX-License-Identifier: Apache-2.0

import os
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
XPACK = Path(os.environ.get(
    "XPACK", HOME / "opt" / "xpack-riscv-none-elf-gcc-15.2.0-1" / "bin"))
SW = Path(__file__).parent

EXE = ".exe" if os.name == "nt" else ""

# Must match console_soc's PATTERN_BASE parameter and link.ld.
PATTERN_BASE = 0x8000
PATTERN_BYTES = 4096


def build(name):
    elf = SW / f"{name}.elf"
    binf = SW / f"{name}.bin"

    subprocess.run([str(XPACK / f"riscv-none-elf-gcc{EXE}"),
                    "-march=rv32e", "-mabi=ilp32e", "-Os",
                    "-ffreestanding", "-fno-builtin",
                    "-nostdlib", "-nostartfiles", "-static",
                    "-T", str(SW / "link.ld"),
                    str(SW / "crt0.S"), str(SW / f"{name}.c"),
                    "-lgcc", "-o", str(elf)], check=True)
    subprocess.run([str(XPACK / f"riscv-none-elf-objcopy{EXE}"),
                    "-O", "binary", str(elf), str(binf)], check=True)

    image = binf.read_bytes()

    # The layout is only correct if the pattern table really landed where the
    # hardware will look for it. objcopy pads the gap with zeros, so a program
    # that overran 32 KiB would push the table along and silently produce a
    # screen full of noise — check rather than hope.
    if len(image) <= PATTERN_BASE:
        raise SystemExit(
            f"{name}.bin is {len(image)} bytes: the pattern table at "
            f"0x{PATTERN_BASE:X} is missing entirely")
    table = image[PATTERN_BASE:PATTERN_BASE + PATTERN_BYTES]
    if not any(table):
        raise SystemExit(
            f"the 4 KiB at 0x{PATTERN_BASE:X} is all zeros — .patterns did not "
            "land there (check link.ld and the section attribute)")

    text_end = _section_end(elf)
    if text_end > PATTERN_BASE:
        raise SystemExit(
            f"code+rodata end at 0x{text_end:X}, past the pattern table at "
            f"0x{PATTERN_BASE:X}")

    print(f"{name}.bin: {len(image)} bytes "
          f"(code+rodata to 0x{text_end:X}, patterns at 0x{PATTERN_BASE:X})")


def _section_end(elf):
    """Highest LMA end among the flash-resident code/rodata sections."""
    out = subprocess.run([str(XPACK / f"riscv-none-elf-objdump{EXE}"), "-h",
                          str(elf)], check=True, capture_output=True, text=True)
    end = 0
    for line in out.stdout.splitlines():
        f = line.split()
        if len(f) >= 6 and f[1] in (".text", ".rodata"):
            end = max(end, int(f[4], 16) + int(f[2], 16))   # LMA + size
    return end


if __name__ == "__main__":
    for name in (sys.argv[1:] or ["game"]):
        build(name)
