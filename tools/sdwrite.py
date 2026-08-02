#!/usr/bin/env python3
r"""sdwrite.py — put a game image on a microSD card for the ULX3S console.

The card layout is RAW SECTORS, not a filesystem: block 0 is a 16-byte header
and blocks 1.. are the binary. The gateware that reads it back is
`fpga/sd_loader.sv`; the header format is documented there and mirrored here.

    block 0    'CTG1' | length (u32 LE) | entry (u32 LE) | sum32 (u32 LE)
    block 1..  the game binary, zero-padded to a 512-byte boundary

Typical use:

    python tools/sdwrite.py --list                            # find the card
    python tools/sdwrite.py sw/game.bin --out card.img        # make an image
    python tools/sdwrite.py sw/game.bin --device \\.\PhysicalDrive2 --yes

WRITING TO A DEVICE DESTROYS EVERYTHING ON IT. That is what raw sectors means:
there is no filesystem left afterwards, and Windows will offer to format the
card next time you plug it in — say no, it is not broken, it simply has no
filesystem any more. The guards below exist because getting the target wrong
once is enough to lose the wrong disk:

  * --device must be given explicitly; there is no auto-detect and no default;
  * --yes must be given as well, or nothing is written;
  * the target must be a WHOLE DISK, never a partition or a drive letter
    (see below — this is a correctness rule before it is a safety rule);
  * on Windows the disk must report removable or USB/SD/MMC bus type,
    PhysicalDrive0 is refused outright, and the size cap below applies;
  * anything larger than 64 GiB is refused — a console card is never that
    big, but a backup disk usually is;
  * everything written is read back and compared before we claim success.

WHY A DRIVE LETTER IS THE WRONG TARGET, even though it looks like the obvious
one. `sd_loader.sv` reads the header with CMD17 at block address 0 — the first
sector of the *card*. On Windows `\\.\E:` is the *volume*, whose sector 0 is
the first sector of the partition, and SD-spec-formatted SDHC cards put that
partition thousands of sectors in (8192 is typical). Writing there lands a
perfectly correct image where the gateware never looks: the card reads back as
an MBR, the loader reports `0xE1 ST_E_MAGIC` ("the card is not ours"), and
nothing about the error points at the writer. Same trap on Linux with
`/dev/sdb1` instead of `/dev/sdb`. So both forms are refused by name.

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


# --------------------------------------------------------------- device paths
# classify_device is deliberately pure and OS-independent so that the rules
# above are unit-testable on the CI runner, which has neither a card nor
# Windows. The Win32 calls further down are the part no test can reach.

_WIN_DISK = re.compile(r"\\\\[.?]\\PhysicalDrive(\d+)\Z", re.IGNORECASE)
_WIN_VOLUME = re.compile(r"\\\\[.?]\\([A-Za-z]):\Z")

# Partition-shaped POSIX names: sda1, mmcblk0p1, nvme0n1p1, and macOS disk2s1.
_POSIX_PARTITION = re.compile(
    r"/dev/(?:(?:s|v|h|xv)d[a-z]+\d+"    # sda1, vdb2, hdc3, xvda1
    r"|mmcblk\d+p\d+"                    # mmcblk0p1
    r"|nvme\d+n\d+p\d+"                  # nvme0n1p1
    r"|r?disk\d+s\d+)\Z")                # macOS disk2s1 / rdisk2s1


def classify_device(device: str, osname: str = os.name):
    """Map a --device string to ('windows', disk_number) or ('posix', path).

    Raises SystemExit with an explanation for anything that is not a whole
    disk. The refusals matter as much as the acceptance: a volume or partition
    path writes successfully to the wrong sectors, which is the failure mode
    hardest to diagnose from the LED code the board will show you.
    """
    if osname == "nt":
        m = _WIN_DISK.match(device)
        if m:
            return "windows", int(m.group(1))

        vol = _WIN_VOLUME.match(device)
        if vol:
            raise SystemExit(
                f"refusing: {device} is a VOLUME, not a disk.\n"
                f"Sector 0 of {vol.group(1)}: is the start of the partition, but the\n"
                "gateware reads the start of the CARD. On a normally formatted\n"
                "SDHC card those differ by thousands of sectors, so the write\n"
                "would succeed and the board would still report 0xE1 ST_E_MAGIC.\n"
                r"Use the whole disk: --device \\.\PhysicalDriveN"
                "\nRun with --list to see which N that is.")

        raise SystemExit(
            f"refusing: {device} is not a physical-disk path.\n"
            r"Expected \\.\PhysicalDriveN — run with --list to find N.")

    if not device.startswith("/dev/"):
        raise SystemExit(f"refusing: {device!r} does not look like a device")

    if _POSIX_PARTITION.match(device):
        raise SystemExit(
            f"refusing: {device!r} is a PARTITION, not a whole disk.\n"
            "The gateware reads the first sector of the card; a partition\n"
            "starts thousands of sectors later, so the image would land where\n"
            "nothing reads it and the board would report 0xE1 ST_E_MAGIC.\n"
            "Drop the trailing partition number (e.g. /dev/sdb, /dev/mmcblk0).")

    return "posix", device


# ------------------------------------------------------------------- win32
# Only reached on Windows. Kept in one place so the rest of the file stays
# readable, and so the ctypes constants sit next to the calls that use them.

_GENERIC_READ = 0x80000000
_GENERIC_WRITE = 0x40000000
_FILE_SHARE_READ = 0x00000001
_FILE_SHARE_WRITE = 0x00000002
_OPEN_EXISTING = 3
_INVALID_HANDLE = ctypes.c_void_p(-1).value

_IOCTL_STORAGE_QUERY_PROPERTY = 0x002D1400
_IOCTL_STORAGE_GET_DEVICE_NUMBER = 0x002D1080
# GET_LENGTH_INFO needs GENERIC_READ; GET_DRIVE_GEOMETRY_EX needs no access
# rights at all, which is what lets --list run before you elevate.
_IOCTL_DISK_GET_LENGTH_INFO = 0x0007405C
_IOCTL_DISK_GET_DRIVE_GEOMETRY_EX = 0x000700A0
_FSCTL_LOCK_VOLUME = 0x00090018
_FSCTL_DISMOUNT_VOLUME = 0x00090020

_BUS_USB, _BUS_SD, _BUS_MMC = 0x07, 0x0C, 0x0D
_DRIVE_REMOVABLE = 2


class _StoragePropertyQuery(ctypes.Structure):
    _fields_ = [("PropertyId", ctypes.c_ulong),
                ("QueryType", ctypes.c_ulong),
                ("AdditionalParameters", ctypes.c_ubyte * 1)]


class _StorageDeviceDescriptor(ctypes.Structure):
    _fields_ = [("Version", ctypes.c_ulong),
                ("Size", ctypes.c_ulong),
                ("DeviceType", ctypes.c_ubyte),
                ("DeviceTypeModifier", ctypes.c_ubyte),
                ("RemovableMedia", ctypes.c_ubyte),
                ("CommandQueueing", ctypes.c_ubyte),
                ("VendorIdOffset", ctypes.c_ulong),
                ("ProductIdOffset", ctypes.c_ulong),
                ("ProductRevisionOffset", ctypes.c_ulong),
                ("SerialNumberOffset", ctypes.c_ulong),
                ("BusType", ctypes.c_ulong),
                ("RawPropertiesLength", ctypes.c_ulong),
                ("RawDeviceProperties", ctypes.c_ubyte * 1024)]


class _DiskGeometry(ctypes.Structure):
    _fields_ = [("Cylinders", ctypes.c_longlong),
                ("MediaType", ctypes.c_int),
                ("TracksPerCylinder", ctypes.c_ulong),
                ("SectorsPerTrack", ctypes.c_ulong),
                ("BytesPerSector", ctypes.c_ulong)]


class _DiskGeometryEx(ctypes.Structure):
    _fields_ = [("Geometry", _DiskGeometry),
                ("DiskSize", ctypes.c_longlong),
                ("Data", ctypes.c_ubyte * 1)]


class _StorageDeviceNumber(ctypes.Structure):
    _fields_ = [("DeviceType", ctypes.c_ulong),
                ("DeviceNumber", ctypes.c_ulong),
                ("PartitionNumber", ctypes.c_long)]


_K = None


def _k32():
    """kernel32 with real prototypes.

    The default ctypes restype is a 32-bit int, which SILENTLY TRUNCATES the
    64-bit HANDLE that CreateFileW returns — every subsequent call then works
    on a garbage handle and fails in a way that looks like a permissions
    problem. Declaring the prototypes once is the only reliable fix.
    """
    global _K
    if _K is not None:
        return _K
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    LP = ctypes.c_void_p
    k.CreateFileW.restype = LP
    k.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_ulong, ctypes.c_ulong,
                              LP, ctypes.c_ulong, ctypes.c_ulong, LP]
    k.CloseHandle.restype = ctypes.c_int
    k.CloseHandle.argtypes = [LP]
    k.DeviceIoControl.restype = ctypes.c_int
    k.DeviceIoControl.argtypes = [LP, ctypes.c_ulong, LP, ctypes.c_ulong,
                                  LP, ctypes.c_ulong, LP, LP]
    k.ReadFile.restype = ctypes.c_int
    k.ReadFile.argtypes = [LP, LP, ctypes.c_ulong, LP, LP]
    k.WriteFile.restype = ctypes.c_int
    k.WriteFile.argtypes = [LP, LP, ctypes.c_ulong, LP, LP]
    k.FlushFileBuffers.restype = ctypes.c_int
    k.FlushFileBuffers.argtypes = [LP]
    k.SetFilePointerEx.restype = ctypes.c_int
    k.SetFilePointerEx.argtypes = [LP, ctypes.c_longlong, LP, ctypes.c_ulong]
    k.GetDriveTypeW.restype = ctypes.c_uint
    k.GetDriveTypeW.argtypes = [ctypes.c_wchar_p]
    _K = k
    return _K


def _open_handle(path: str, access: int):
    """Open a device. access=0 is the query-only form, which needs no elevation.

    Querying size, bus type and device number all work with zero access rights;
    only the actual write needs an Administrator shell. That is why --list is
    usable before you elevate, which is the order you actually want: find the
    disk number first, elevate once you know it.
    """
    h = _k32().CreateFileW(path, access,
                           _FILE_SHARE_READ | _FILE_SHARE_WRITE,
                           None, _OPEN_EXISTING, 0, None)
    if h is None or h == _INVALID_HANDLE:
        err = ctypes.get_last_error()
        if err == 5:
            raise SystemExit(
                f"permission denied opening {path}.\n"
                "Raw disk access needs an Administrator shell on Windows.")
        raise SystemExit(f"cannot open {path} (Win32 error {err})")
    return h


def _ioctl(handle, code, in_buf, out_type):
    out = out_type() if out_type is not None else None
    returned = ctypes.c_ulong(0)
    in_ptr = ctypes.cast(ctypes.byref(in_buf), ctypes.c_void_p) if in_buf is not None else None
    in_len = ctypes.sizeof(in_buf) if in_buf is not None else 0
    out_ptr = ctypes.cast(ctypes.byref(out), ctypes.c_void_p) if out is not None else None
    out_len = ctypes.sizeof(out) if out is not None else 0
    ok = _k32().DeviceIoControl(handle, code, in_ptr, in_len,
                                out_ptr, out_len,
                                ctypes.cast(ctypes.byref(returned), ctypes.c_void_p),
                                None)
    return bool(ok), out


def _win_describe(disk: int):
    """(removable, bus_type, size_bytes) for PhysicalDriveN. No elevation needed."""
    h = _open_handle(rf"\\.\PhysicalDrive{disk}", 0)
    try:
        query = _StoragePropertyQuery(0, 0, (ctypes.c_ubyte * 1)())
        ok, desc = _ioctl(h, _IOCTL_STORAGE_QUERY_PROPERTY, query,
                          _StorageDeviceDescriptor)
        removable = bool(desc.RemovableMedia) if ok else False
        bus = int(desc.BusType) if ok else 0

        ok_geo, geo = _ioctl(h, _IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, None,
                             _DiskGeometryEx)
        if ok_geo and geo.DiskSize > 0:
            return removable, bus, int(geo.DiskSize)

        ok_len, length = _ioctl(h, _IOCTL_DISK_GET_LENGTH_INFO, None,
                                ctypes.c_ulonglong)
        return removable, bus, int(length.value) if ok_len else 0
    finally:
        _k32().CloseHandle(h)


def _win_volumes_on(disk: int):
    """Drive letters whose volume lives on PhysicalDriveN."""
    letters = []
    for code in range(ord("A"), ord("Z") + 1):
        letter = chr(code)
        if _k32().GetDriveTypeW(f"{letter}:\\") == 1:      # DRIVE_NO_ROOT_DIR
            continue
        try:
            h = _open_handle(rf"\\.\{letter}:", 0)
        except SystemExit:
            continue
        try:
            ok, num = _ioctl(h, _IOCTL_STORAGE_GET_DEVICE_NUMBER, None,
                             _StorageDeviceNumber)
            if ok and int(num.DeviceNumber) == disk:
                letters.append(letter)
        finally:
            _k32().CloseHandle(h)
    return letters


def win_list_disks():
    """Print the disks that could plausibly be the card. Windows only."""
    print(f"{'disk':<22} {'size':>9}  {'bus':<10} {'removable':<10} letters")
    for disk in range(0, 16):
        try:
            removable, bus, size = _win_describe(disk)
        except SystemExit:
            continue
        bus_name = {_BUS_USB: "USB", _BUS_SD: "SD", _BUS_MMC: "MMC"}.get(bus,
                                                                        f"0x{bus:02X}")
        letters = ",".join(_win_volumes_on(disk)) or "-"
        flag = "" if _looks_like_a_card(disk, removable, bus, size) else "   (refused)"
        shown = f"{size / 1024**3:>7.1f}G" if size else "      ?"
        print(rf"\\.\PhysicalDrive{disk}".ljust(22)
              + f" {shown}  {bus_name:<10} "
              + f"{'yes' if removable else 'no':<10} {letters}{flag}")
    print("\nPick the one that matches your card's size and appeared when you "
          "inserted it.\nPhysicalDrive0 is refused on principle: it is the "
          "system disk on every normal machine.")


def _looks_like_a_card(disk, removable, bus, size):
    if disk == 0:
        return False
    if size == 0 or size > MAX_DEVICE_BYTES:
        return False
    return removable or bus in (_BUS_USB, _BUS_SD, _BUS_MMC)


def _win_check_and_lock(disk: int):
    """Refuse a disk that is not card-shaped, then take it away from Windows.

    Since Vista, writes to sectors owned by a mounted filesystem are refused
    even for Administrators unless the volume is locked and dismounted first.
    Without this the write dies with a bare access-denied that reads exactly
    like "you forgot to elevate" — when you did not.
    """
    removable, bus, size = _win_describe(disk)

    if disk == 0:
        raise SystemExit(
            "refusing: PhysicalDrive0 is the system disk on every normal "
            "machine.\nIf your card really is disk 0, something is wrong "
            "enough to stop for.")
    if size == 0:
        raise SystemExit(
            f"refusing: cannot read the size of PhysicalDrive{disk}.\n"
            "The size cap is a real guard, not decoration — without a size "
            "there is nothing stopping a typo from reaching a big disk.")
    if size > MAX_DEVICE_BYTES:
        raise SystemExit(
            f"refusing: PhysicalDrive{disk} holds {size / 1024**3:.1f} GiB, "
            f"more than the {MAX_DEVICE_BYTES / 1024**3:.0f} GiB limit.")
    if not (removable or bus in (_BUS_USB, _BUS_SD, _BUS_MMC)):
        raise SystemExit(
            f"refusing: PhysicalDrive{disk} is not removable and is not on a "
            f"USB/SD/MMC bus (BusType=0x{bus:02X}).\n"
            "This guard is the only thing between a typo and your system disk.")

    held = []
    for letter in _win_volumes_on(disk):
        h = _open_handle(rf"\\.\{letter}:", _GENERIC_READ | _GENERIC_WRITE)
        ok_lock, _ = _ioctl(h, _FSCTL_LOCK_VOLUME, None, None)
        if not ok_lock:
            _k32().CloseHandle(h)
            raise SystemExit(
                f"cannot lock volume {letter}: — something has it open.\n"
                "Close any Explorer window or program using the card and "
                "retry.")
        _ioctl(h, _FSCTL_DISMOUNT_VOLUME, None, None)
        held.append(h)
        print(f"locked  : {letter}: (dismounted for the write)")
    return held, size


def _win_write_verify(disk: int, image: bytes, held):
    path = rf"\\.\PhysicalDrive{disk}"
    k = _k32()
    h = _open_handle(path, _GENERIC_READ | _GENERIC_WRITE)
    try:
        written = ctypes.c_ulong(0)
        buf = ctypes.create_string_buffer(image, len(image))
        ok = k.WriteFile(h, ctypes.cast(buf, ctypes.c_void_p), len(image),
                         ctypes.cast(ctypes.byref(written), ctypes.c_void_p), None)
        if not ok:
            raise SystemExit(
                f"write failed on {path} (Win32 error {ctypes.get_last_error()})")
        if written.value != len(image):
            raise SystemExit(
                f"short write on {path}: {written.value} of {len(image)} bytes")
        k.FlushFileBuffers(h)

        new_pos = ctypes.c_longlong(0)
        k.SetFilePointerEx(h, 0,
                           ctypes.cast(ctypes.byref(new_pos), ctypes.c_void_p), 0)
        read = ctypes.c_ulong(0)
        back = ctypes.create_string_buffer(len(image))
        ok_r = k.ReadFile(h, ctypes.cast(back, ctypes.c_void_p), len(image),
                          ctypes.cast(ctypes.byref(read), ctypes.c_void_p), None)
        if not ok_r or read.value != len(image):
            raise SystemExit("read-back failed; cannot confirm the card is good")
        _compare(back.raw[:len(image)], image)
    finally:
        k.CloseHandle(h)
        for vol in held:
            k.CloseHandle(vol)


def _compare(got: bytes, want: bytes) -> None:
    if got == want:
        print(f"verified: {len(want)} bytes read back identical")
        return
    for i, (a, b) in enumerate(zip(got, want)):
        if a != b:
            raise SystemExit(
                f"VERIFY FAILED at byte {i} (block {i // BLOCK}): "
                f"wrote 0x{b:02X}, read 0x{a:02X}.\n"
                "The card is now in an unknown state — do not trust it.")
    raise SystemExit("VERIFY FAILED: read-back length differs")


def _posix_write_verify(device: str, image: bytes) -> None:
    try:
        fd = os.open(device, os.O_RDWR)
    except PermissionError:
        raise SystemExit(
            f"permission denied opening {device}.\n"
            "Use sudo, and make sure no partition of that card is mounted.")
    try:
        os.write(fd, image)
        os.fsync(fd)
        os.lseek(fd, 0, os.SEEK_SET)
        back = b""
        while len(back) < len(image):
            chunk = os.read(fd, len(image) - len(back))
            if not chunk:
                break
            back += chunk
        _compare(back, image)
    finally:
        os.close(fd)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("binary", nargs="?",
                    help="game image (raw binary, loaded at flash 0)")
    ap.add_argument("--entry", type=lambda s: int(s, 0), default=0,
                    help="entry point recorded in the header (informational)")
    ap.add_argument("--list", action="store_true",
                    help="list candidate disks (Windows) and exit")
    out = ap.add_mutually_exclusive_group()
    out.add_argument("--out", help="write a card image to this file")
    out.add_argument("--device",
                     help=r"whole disk, e.g. \\.\PhysicalDrive2 or /dev/sdb")
    ap.add_argument("--yes", action="store_true",
                    help="required with --device: confirm the card is erased")
    args = ap.parse_args(argv)

    if args.list:
        if os.name != "nt":
            print("--list is Windows-only; on Linux use `lsblk -dpo "
                  "NAME,SIZE,RM,MODEL`.")
            return 0
        win_list_disks()
        return 0

    if args.binary is None:
        ap.error("a binary is required unless --list is given")
    if not (args.out or args.device):
        ap.error("one of --out or --device is required")

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

    kind, target = classify_device(args.device)
    if kind == "windows":
        held, size = _win_check_and_lock(target)
        print(f"device  : PhysicalDrive{target} ({size / 1024**3:.1f} GiB)")
        _win_write_verify(target, image, held)
    else:
        _posix_write_verify(target, image)

    print(f"written : {args.device} ({len(image)} bytes) at block 0")
    print("Eject the card, put it in the ULX3S, power on.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
