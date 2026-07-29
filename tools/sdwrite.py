#!/usr/bin/env python3
"""sdwrite.py — put a game image on a microSD card for the ULX3S console.

The card layout is RAW SECTORS, not a filesystem: block 0 is a 16-byte header
and blocks 1.. are the binary. The gateware that reads it back is
`fpga/sd_loader.sv`; the header format is documented there and mirrored here.

    block 0    'CTG1' | length (u32 LE) | entry (u32 LE) | sum32 (u32 LE)
    block 1..  the game binary, zero-padded to a 512-byte boundary

Typical use:

    python tools/sdwrite.py build/game.bin --out card.img     # make an image
    python tools/sdwrite.py build/game.bin --device \\\\.\\E: --yes

WRITING TO A DEVICE DESTROYS EVERYTHING ON IT. That is what raw sectors means:
there is no filesystem left afterwards, and Windows will offer to format the
card next time you plug it in — say no, it is not broken, it simply has no
filesystem any more. The guards below exist because getting the drive letter
wrong once is enough to lose the wrong disk:

  * --device must be given explicitly; there is no auto-detect and no default;
  * --yes must be given as well, or nothing is written;
  * on Windows the target must be a REMOVABLE drive, checked via the Win32
    API, and the write is refused otherwise;
  * anything larger than 64 GiB is refused outright — a console card is never
    that big, but a backup disk usually is.

Copyright (c) 2026 Joonatan Alanampa
SPDX-License-Identifier: Apache-2.0
"""

import argparse
import ctypes
import os
import re
import sys

BLOCK = 512
MAGIC = b"CTG1"
MAX_DEVICE_BYTES = 64 * 1024**3


def build_image(payload: bytes, entry: int = 0) -> bytes:
    """Header block + padded payload, exactly as the gateware expects."""
    checksum = sum(payload) & 0xFFFFFFFF
    header = (MAGIC
              + len(payload).to_bytes(4, "little")
              + entry.to_bytes(4, "little")
              + checksum.to_bytes(4, "little"))
    padding = (-len(payload)) % BLOCK
    return header.ljust(BLOCK, b"\x00") + payload + bytes(padding)


def _windows_drive_letter(device: str):
    """Return 'E' for r'\\\\.\\E:' style paths, else None."""
    m = re.fullmatch(r"\\\\[.?]\\([A-Za-z]):", device)
    return m.group(1).upper() if m else None


def check_device_is_safe(device: str) -> None:
    """Refuse anything that is not a small removable volume."""
    if os.name != "nt":
        if not device.startswith("/dev/"):
            raise SystemExit(f"refusing: {device!r} does not look like a device")
        return

    letter = _windows_drive_letter(device)
    if letter is None:
        raise SystemExit(
            f"refusing: {device!r} is not a drive-letter device path.\n"
            r"Use the \\.\E: form so the removable check can run.")

    DRIVE_REMOVABLE = 2
    root = f"{letter}:\\"
    kind = ctypes.windll.kernel32.GetDriveTypeW(ctypes.c_wchar_p(root))
    if kind != DRIVE_REMOVABLE:
        raise SystemExit(
            f"refusing: drive {letter}: is not removable (GetDriveType={kind}).\n"
            "This guard is the only thing between a typo and your system disk.")

    free_c, total_c = ctypes.c_ulonglong(), ctypes.c_ulonglong()
    ok = ctypes.windll.kernel32.GetDiskFreeSpaceExW(
        ctypes.c_wchar_p(root), ctypes.byref(free_c), ctypes.byref(total_c), None)
    if ok and total_c.value > MAX_DEVICE_BYTES:
        raise SystemExit(
            f"refusing: drive {letter}: holds {total_c.value / 1024**3:.1f} GiB, "
            f"more than the {MAX_DEVICE_BYTES / 1024**3:.0f} GiB limit.")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("binary", help="game image (raw binary, loaded at flash 0)")
    ap.add_argument("--entry", type=lambda s: int(s, 0), default=0,
                    help="entry point recorded in the header (informational)")
    out = ap.add_mutually_exclusive_group(required=True)
    out.add_argument("--out", help="write a card image to this file")
    out.add_argument("--device", help=r"raw device, e.g. \\.\E: or /dev/sdX")
    ap.add_argument("--yes", action="store_true",
                    help="required with --device: confirm the card is erased")
    args = ap.parse_args(argv)

    with open(args.binary, "rb") as f:
        payload = f.read()
    if not payload:
        raise SystemExit(f"refusing: {args.binary} is empty")

    image = build_image(payload, args.entry)
    checksum = sum(payload) & 0xFFFFFFFF

    print(f"image   : {args.binary}")
    print(f"payload : {len(payload)} bytes ({len(payload) / 1024:.1f} KiB)")
    print(f"sum32   : 0x{checksum:08X}")
    print(f"blocks  : 1 header + {(len(image) // BLOCK) - 1} data")

    if args.out:
        with open(args.out, "wb") as f:
            f.write(image)
        print(f"written : {args.out}")
        return 0

    if not args.yes:
        raise SystemExit(
            f"refusing: --device {args.device} erases the card completely.\n"
            "Re-run with --yes if that is what you want.")

    check_device_is_safe(args.device)

    try:
        fd = os.open(args.device, os.O_WRONLY | getattr(os, "O_BINARY", 0))
    except PermissionError:
        raise SystemExit(
            "permission denied opening the device.\n"
            "Windows: run this from an Administrator shell.\n"
            "Linux:   use sudo, and make sure the card is not mounted.")
    try:
        os.write(fd, image)
        os.fsync(fd)
    finally:
        os.close(fd)

    print(f"written : {args.device} ({len(image)} bytes)")
    print("Eject the card, put it in the ULX3S, power on.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
