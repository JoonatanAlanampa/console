# test_sdload.py — the whole power-on load path, card to cartridge flash.
#
# This is the test that matters: everything the ULX3S will do on power-up,
# minus the wires. It reuses the SD card and flash models from the unit suites
# so the parts behave the same awkward way here as they do there (a card that
# stays busy through several ACMD41s, a flash that only clears bits and
# silently ignores a write with no WREN).
#
# The cases are chosen around what fails SILENTLY on real hardware:
#   * a fresh card must actually land byte-exact in flash;
#   * a second power-on must NOT reprogram — that is the whole point of the
#     resident header, and a broken compare would look identical to a working
#     one except for taking a minute and wearing the part;
#   * a corrupt image must be REJECTED and must not leave a header behind, or
#     the next boot would trust a half-written game.

import random
from types import SimpleNamespace

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from test_sdspi import SdCard
from test_spiflash import FlashChip

BLOCK = 512
HDR_ADDR = 0xFFF000
FLASH_SIZE = 1 << 24

ST_DONE, ST_SKIP, ST_NOCARD = 0x80, 0x81, 0x82
ST_E_SD, ST_E_MAGIC, ST_E_SUM = 0xE0, 0xE1, 0xE2


def make_header(payload, magic=b"CTG1", entry=0, sum_override=None):
    s = sum(payload) & 0xFFFFFFFF if sum_override is None else sum_override
    return (magic
            + len(payload).to_bytes(4, "little")
            + entry.to_bytes(4, "little")
            + s.to_bytes(4, "little"))


def make_card(payload, **kw):
    """Block 0 = header, blocks 1.. = payload padded to a block boundary."""
    hdr = make_header(payload, **kw).ljust(BLOCK, b"\x00")
    pad = payload + bytes((-len(payload)) % BLOCK)
    return hdr + pad


async def setup(dut, card_image, present=True, flash=None, card=True):
    """card=False models an EMPTY SLOT: no card model at all, MISO left idle
    high by the pull-up. That is the only honest way to test the absent-card
    path now that the loader no longer trusts the card-detect pin."""
    cocotb.start_soon(Clock(dut.clk, 40, units="ns").start())

    sd_pins = SimpleNamespace(cs_n=dut.sd_cs_n, sck=dut.sd_sck,
                              mosi=dut.sd_mosi, miso=dut.sd_miso)
    fl_pins = SimpleNamespace(cs_n=dut.cart_cs_n, sck=dut.cart_sck,
                              mosi=dut.cart_mosi, miso=dut.cart_miso)

    sd = SdCard(sd_pins, card_image) if card else None
    chip = flash if flash is not None else FlashChip(fl_pins, size=FLASH_SIZE)
    chip.dut = fl_pins
    if sd is not None:
        cocotb.start_soon(sd.run())
    else:
        dut.sd_miso.value = 1          # nothing driving it but the pull-up
    cocotb.start_soon(chip.run())

    dut.sd_present.value = 1 if present else 0
    dut.rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    return sd, chip


async def wait_done(dut, timeout=4_000_000):
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.done.value == 1:
            # give owns_bus a cycle to settle alongside done
            await RisingEdge(dut.clk)
            return
    raise AssertionError("loader never asserted done")


@cocotb.test()
async def test_cold_load(dut):
    """A fresh card lands byte-exact in flash, and the header is committed."""
    rnd = random.Random(20260729)
    payload = bytes(rnd.randrange(256) for _ in range(1500))
    card, chip = await setup(dut, make_card(payload))

    await wait_done(dut)

    assert dut.error.value == 0, f"loader errored, status={int(dut.status.value):#04x}"
    assert int(dut.status.value) == ST_DONE, (
        f"status {int(dut.status.value):#04x}, expected ST_DONE")
    assert dut.owns_bus.value == 0, "loader must release the bus before boot"

    got = bytes(chip.mem[0:len(payload)])
    assert got == payload, "the image in flash does not match the card"

    hdr = bytes(chip.mem[HDR_ADDR:HDR_ADDR + 16])
    assert hdr == make_header(payload), (
        f"resident header wrong: {hdr.hex()} vs {make_header(payload).hex()}")


@cocotb.test()
async def test_second_boot_skips_reprogramming(dut):
    """Identical card + resident header = no erase, no program, fast release."""
    rnd = random.Random(11)
    payload = bytes(rnd.randrange(256) for _ in range(1200))
    image = make_card(payload)

    card, chip = await setup(dut, image)
    await wait_done(dut)
    assert dut.error.value == 0
    first_wren = chip.wren_count
    assert first_wren > 0, "the cold load did not write anything"

    # Power-cycle the loader with the flash contents intact.
    dut.rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await wait_done(dut)

    assert dut.error.value == 0
    assert int(dut.status.value) == ST_SKIP, (
        f"status {int(dut.status.value):#04x}, expected ST_SKIP — the resident "
        "header compare did not short-circuit the load")
    assert chip.wren_count == first_wren, (
        f"{chip.wren_count - first_wren} extra write(s) on the second boot; "
        "the image was already resident and must not be reprogrammed")


@cocotb.test()
async def test_changed_image_reloads(dut):
    """A different game on the card must overwrite the resident one."""
    rnd = random.Random(5)
    first = bytes(rnd.randrange(256) for _ in range(900))
    second = bytes(rnd.randrange(256) for _ in range(700))

    card, chip = await setup(dut, make_card(first))
    await wait_done(dut)
    assert bytes(chip.mem[0:len(first)]) == first

    # Swap the card, then power-cycle.
    card.image = make_card(second)
    dut.rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await wait_done(dut)

    assert dut.error.value == 0
    assert int(dut.status.value) == ST_DONE, "a changed image must reprogram"
    assert bytes(chip.mem[0:len(second)]) == second, "the new game did not land"
    assert bytes(chip.mem[HDR_ADDR:HDR_ADDR + 16]) == make_header(second)


@cocotb.test()
async def test_bad_magic_is_rejected(dut):
    """A card that is not ours must not be treated as a game."""
    payload = bytes(range(256))
    card, chip = await setup(dut, make_card(payload, magic=b"FAT?"))
    await wait_done(dut)

    assert dut.error.value == 1, "a foreign card must raise error"
    assert int(dut.status.value) == ST_E_MAGIC
    assert chip.wren_count == 0, "nothing may be written when the magic is wrong"


@cocotb.test()
async def test_checksum_mismatch_leaves_no_header(dut):
    """A corrupt image fails loudly AND leaves the header uncommitted."""
    rnd = random.Random(77)
    payload = bytes(rnd.randrange(256) for _ in range(1024))
    bad = make_card(payload, sum_override=0xDEADBEEF)
    card, chip = await setup(dut, bad)
    await wait_done(dut)

    assert dut.error.value == 1, "a bad checksum must raise error"
    assert int(dut.status.value) == ST_E_SUM
    hdr = bytes(chip.mem[HDR_ADDR:HDR_ADDR + 16])
    assert hdr != bad[0:16], (
        "the header was committed despite a checksum failure — the next boot "
        "would trust a corrupt image")


@cocotb.test()
async def test_no_card_boots_what_is_already_there(dut):
    """No card is not an error: release the bus and boot resident flash.

    The slot is genuinely empty here — no card model, MISO idle high — so this
    exercises the real path a bare board takes: init runs, nothing ever
    answers, the CMD0 retry budget expires, and the loader gives up cleanly.
    The previous version of this test only lowered the card-detect flag, which
    proved nothing about what an unanswered card actually does.
    """
    card, chip = await setup(dut, bytes(BLOCK), card=False)
    await wait_done(dut)

    assert card is None
    assert dut.error.value == 0, "an absent card must not be an error"
    assert int(dut.status.value) == ST_NOCARD
    assert dut.owns_bus.value == 0
    assert chip.wren_count == 0, "nothing may be written with no card present"


@cocotb.test()
async def test_loads_with_card_detect_unwired(dut):
    """A real card must load even when sd_cdn never goes low.

    This is the regression test for a bug that would have cost a bring-up
    session: the ULX3S v2.0 constraint file marks sd_cdn (N5) "not connected",
    so on real hardware the pin sits pulled up and sd_present reads 0 forever.
    The loader used to short-circuit to ST_NOCARD on exactly that, which means
    the microSD feature would have been dead on arrival while reporting the
    perfectly innocent status "no card". Card detect is advisory now, so a
    present card must load regardless of the pin.
    """
    rnd = random.Random(20260730)
    payload = bytes(rnd.randrange(256) for _ in range(1400))
    card, chip = await setup(dut, make_card(payload), present=False)

    await wait_done(dut)

    assert dut.error.value == 0, f"status={int(dut.status.value):#04x}"
    assert int(dut.status.value) == ST_DONE, (
        f"status {int(dut.status.value):#04x}, expected ST_DONE — the loader "
        "ignored a present card because card detect read low")
    assert bytes(chip.mem[0:len(payload)]) == payload, (
        "the image did not land in flash with card detect unwired")
    assert bytes(chip.mem[HDR_ADDR:HDR_ADDR + 16]) == make_header(payload)
