#!/usr/bin/env python3
r"""Tests for the host-side card writer: where the bytes land, not just what they are.

`test/test_sdload.py` already checks that `build_image` agrees byte-for-byte
with what the gateware expects. That is the *content* half, and it was green
while the *targeting* half was wrong: the writer required a `\\.\E:` drive
letter, which addresses the first sector of the PARTITION, while
`fpga/sd_loader.sv` reads block 0 of the CARD. On an SD-spec-formatted SDHC
card those are thousands of sectors apart, so a perfectly correct image went
somewhere the loader never looks and the board would have reported
`0xE1 ST_E_MAGIC` — an error that accuses the card, not the writer.

Nothing here touches a device. `classify_device` is pure and takes the OS name
as an argument precisely so the Windows rules can be tested on the Linux
runner, where the mistake would otherwise be invisible until hardware day.

Copyright (c) 2026 Joonatan Alanampa
SPDX-License-Identifier: Apache-2.0
"""

import importlib.util
import os
import struct
import sys
from pathlib import Path

import pytest

_SDWRITE_PY = Path(__file__).parent / "sdwrite.py"
_spec = importlib.util.spec_from_file_location("sdwrite", _SDWRITE_PY)
sdwrite = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sdwrite)


# ------------------------------------------------------------------ targeting

@pytest.mark.parametrize("path,disk", [
    (r"\\.\PhysicalDrive0", 0),
    (r"\\.\PhysicalDrive2", 2),
    (r"\\.\PhysicalDrive11", 11),
    (r"\\?\PhysicalDrive3", 3),
    (r"\\.\physicaldrive4", 4),
])
def test_windows_whole_disk_accepted(path, disk):
    assert sdwrite.classify_device(path, "nt") == ("windows", disk)


@pytest.mark.parametrize("path", [r"\\.\E:", r"\\.\C:", r"\\?\F:"])
def test_windows_volume_refused_and_says_why(path):
    """A drive letter is the obvious guess and the wrong target.

    It must not merely fail: it must name PhysicalDrive, because the person
    reading this message has a board on the desk and an LED code that blames
    the card.
    """
    with pytest.raises(SystemExit) as e:
        sdwrite.classify_device(path, "nt")
    msg = str(e.value)
    assert "VOLUME" in msg
    assert "PhysicalDrive" in msg
    assert "ST_E_MAGIC" in msg


@pytest.mark.parametrize("path", ["E:", "card.img", "/dev/sdb", r"\\.\PhysicalDrive"])
def test_windows_other_shapes_refused(path):
    with pytest.raises(SystemExit):
        sdwrite.classify_device(path, "nt")


@pytest.mark.parametrize("path", [
    "/dev/sdb", "/dev/sda", "/dev/mmcblk0", "/dev/disk2", "/dev/rdisk2",
    "/dev/nvme0n1",
])
def test_posix_whole_disk_accepted(path):
    assert sdwrite.classify_device(path, "posix") == ("posix", path)


@pytest.mark.parametrize("path", [
    "/dev/sdb1", "/dev/sda2", "/dev/mmcblk0p1", "/dev/nvme0n1p1",
    "/dev/disk2s1", "/dev/rdisk2s1",
])
def test_posix_partition_refused(path):
    """Same trap as the Windows drive letter, different spelling."""
    with pytest.raises(SystemExit) as e:
        sdwrite.classify_device(path, "posix")
    assert "PARTITION" in str(e.value)


@pytest.mark.parametrize("path", ["card.img", "sdb", "~/card", r"\\.\PhysicalDrive2"])
def test_posix_non_device_refused(path):
    with pytest.raises(SystemExit):
        sdwrite.classify_device(path, "posix")


# --------------------------------------------------------------------- layout

def test_header_is_block_zero_and_parses():
    """The invariant the targeting bug broke: the header IS the first block."""
    payload = bytes(range(256)) * 5
    image = sdwrite.build_image(payload, entry=0x40)

    magic, length, entry, sum32 = struct.unpack("<4sIII", image[:16])
    assert magic == b"CTG1"
    assert length == len(payload)
    assert entry == 0x40
    assert sum32 == sum(payload) & 0xFFFFFFFF

    assert image[16:sdwrite.BLOCK] == bytes(sdwrite.BLOCK - 16)
    assert image[sdwrite.BLOCK:sdwrite.BLOCK + len(payload)] == payload
    assert len(image) % sdwrite.BLOCK == 0


@pytest.mark.parametrize("n", [1, 511, 512, 513, 4096])
def test_payload_padded_to_block_boundary(n):
    image = sdwrite.build_image(bytes(n))
    assert len(image) == sdwrite.BLOCK + ((n + sdwrite.BLOCK - 1) // sdwrite.BLOCK) * sdwrite.BLOCK


# ------------------------------------------------------------------------ cli

def test_out_mode_writes_the_same_bytes(tmp_path):
    payload = b"\xde\xad\xbe\xef" * 40
    binary = tmp_path / "game.bin"
    binary.write_bytes(payload)
    out = tmp_path / "card.img"

    assert sdwrite.main([str(binary), "--out", str(out)]) == 0
    assert out.read_bytes() == sdwrite.build_image(payload)


def test_device_without_yes_writes_nothing(tmp_path):
    binary = tmp_path / "game.bin"
    binary.write_bytes(b"x" * 64)
    with pytest.raises(SystemExit) as e:
        sdwrite.main([str(binary), "--device", "/dev/sdb"])
    assert "--yes" in str(e.value)


def test_empty_binary_refused(tmp_path):
    binary = tmp_path / "empty.bin"
    binary.write_bytes(b"")
    with pytest.raises(SystemExit):
        sdwrite.main([str(binary), "--out", str(tmp_path / "card.img")])


def test_bad_device_is_rejected_before_any_open(tmp_path):
    """The refusal must come from classify_device, not from failing to open.

    /dev/sdb1 exists on plenty of machines; if the guard ran late we would
    find out by writing to it. The host's own OS is used here on purpose —
    this is the one test that exercises the real `main` -> `classify_device`
    wiring rather than calling the classifier directly.
    """
    binary = tmp_path / "game.bin"
    binary.write_bytes(b"x" * 64)
    wrong, expect = ((r"\\.\E:", "VOLUME") if os.name == "nt"
                     else ("/dev/sdb1", "PARTITION"))
    with pytest.raises(SystemExit) as e:
        sdwrite.main([str(binary), "--device", wrong, "--yes"])
    assert expect in str(e.value)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
