#!/usr/bin/env python3
"""mkhex.py — split a cartridge image into the two byte lanes bram_cart reads.

    python tools/mkhex.py sw/game.bin fpga/build/game_lo.hex fpga/build/game_hi.hex

fpga/bram_cart.sv stores the flash as TWO 8-bit arrays rather than one 16-bit
one, so that a byte write needs no byte-enable and, more importantly, so that
both bytes of a 16-bit word arrive together: the console's 03h read has no dummy
cycles, so the model has to issue its BRAM read one clock BEFORE addr[0] has
arrived and pick the lane afterwards. Even byte addresses land in the _lo file,
odd ones in _hi.

GENERATED, NEVER COMMITTED. Both builders run this from sw/game.bin, because a
checked-in hex file is a second copy of the game that can drift from the first —
and it would drift silently, as a console that boots the program you edited
yesterday.

Padding: $readmemh leaves any address the file does not reach at X, and an X on
MISO propagates into the CPU and looks like a broken CPU rather than an empty
cartridge. So both lanes are padded to the full array size with FF, which is
also what an erased flash actually reads.
"""

import sys
from pathlib import Path

FLASH_BYTES = 65536  # must equal bram_cart.sv's FLASH_BYTES parameter


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    src, lo_path, hi_path = (Path(a) for a in argv[1:])
    image = src.read_bytes()

    if len(image) > FLASH_BYTES:
        print(
            f"error: {src} is {len(image)} bytes, more than the {FLASH_BYTES}-byte "
            f"flash bram_cart.sv models. Raise FLASH_BYTES in BOTH places or shrink "
            f"the image.",
            file=sys.stderr,
        )
        return 1

    padded = image + b"\xff" * (FLASH_BYTES - len(image))

    for path, lane in ((lo_path, padded[0::2]), (hi_path, padded[1::2])):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(f"{b:02x}\n" for b in lane))

    print(
        f"{src} ({len(image)} bytes) -> {lo_path} + {hi_path}, "
        f"{FLASH_BYTES // 2} words each, padded with FF"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
