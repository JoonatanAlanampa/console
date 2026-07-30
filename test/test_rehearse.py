# test_rehearse.py - the full power-on chain, with the REAL cartridge image.
#
# Card -> loader -> cartridge flash -> XIP boot -> the game running. This is
# the rehearsal that was always the point of the ULX3S prototype, done in
# simulation so that the first time real hardware is powered on, the only
# untested things are the wires.
#
# It uses sw/game.bin as built by sw/build.py, not a synthetic image, so the
# linker script, the pattern-table placement and the RV32E ABI are all part of
# what is under test.
#
# (Deliberately ASCII-only: this file gets rewritten by tooling often enough
# that a stray cp1252 round-trip has already corrupted it once.)

import importlib.util
from pathlib import Path
from types import SimpleNamespace

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Edge, RisingEdge

from test_sdspi import SdCard

# Build the card image with the REAL host-side writer, not a test-local copy of
# the format. tools/sdwrite.py is the only thing that ever writes a physical
# card, so if it and the gateware disagree the whole suite can pass while the
# actual hardware reads garbage. Importing it by path (tools/ is not a package,
# and sdwrite.py is a CLI script guarded by __main__) makes this rehearsal
# start where the user starts.
_SDWRITE_PY = Path(__file__).parent.parent / "tools" / "sdwrite.py"
_spec = importlib.util.spec_from_file_location("sdwrite", _SDWRITE_PY)
sdwrite = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sdwrite)

GAME = Path(__file__).parent.parent / "sw" / "game.bin"

FLASH_SIZE = 1 << 24
PSRAM_SIZE = 1 << 23
TILEMAP_BASE = 0x010000          # vga_fetch default, in PSRAM
SECTOR = 4096


def bit(vec, i, default=1):
    """One bit of a tristate bus, tolerating X/Z.

    The cartridge lines carry real pull-ups (PULLMODE=UP in ulx3s.lpf), and
    before reset settles the bus is X, so an undriven line reads as 1, which
    for a chip select means "deselected" and is the safe interpretation.
    """
    try:
        return int(vec[i])
    except ValueError:
        return default


class CartBus:
    """Flash on CS0 and PSRAM on CS1, sharing one 1-bit SPI bus.

    Serves the loader's programming commands (9Fh/06h/05h/20h/02h) and the
    SoC's execute-in-place reads (03h) on the same part, because on real
    hardware they ARE the same part. That overlap is precisely what the
    harness's bus mux exists to arbitrate, and a model that split them in two
    would not test it.
    """

    def __init__(self, dut):
        self.dut = dut
        self.flash = bytearray(b"\xff" * FLASH_SIZE)
        self.psram = bytearray(PSRAM_SIZE)
        self.wel = False
        self.busy_left = 0
        self.last_sck = 0
        self._new_txn()

    def _new_txn(self):
        self.buf = []
        self.mode = None
        self.raddr = 0
        self.dev = None
        self.tx = []
        self.rx = 0
        self.nbits = 0
        self.cur = 0xFF

    def _mem(self):
        return self.flash if self.dev == "flash" else self.psram

    def _on_byte(self, b):
        self.buf.append(b)
        n, op = len(self.buf), self.buf[0]
        if op == 0x9F and n == 1:
            self.mode, self.tx = "q", [0xEF, 0x40, 0x18]
        elif op == 0x05 and n == 1:
            self.mode = "status"
        elif op == 0x03 and n == 4:
            self.mode = "read"
            self.raddr = int.from_bytes(bytes(self.buf[1:4]), "big")

    def _on_cs_rise(self):
        if self.buf:
            op = self.buf[0]
            if op == 0x06:
                self.wel = True
            elif op == 0x20 and len(self.buf) >= 4 and self.wel:
                a = int.from_bytes(bytes(self.buf[1:4]), "big") & ~(SECTOR - 1)
                self.flash[a:a + SECTOR] = b"\xff" * SECTOR
                self.wel = False
                self.busy_left = 2
            elif op == 0x02 and len(self.buf) >= 4:
                a = int.from_bytes(bytes(self.buf[1:4]), "big")
                if self.dev == "psram":
                    for i, v in enumerate(self.buf[4:]):
                        if a + i < PSRAM_SIZE:
                            self.psram[a + i] = v
                elif self.wel:
                    for i, v in enumerate(self.buf[4:]):
                        self.flash[a + i] &= v    # NOR flash clears bits only
                    self.wel = False
                    self.busy_left = 2
        self._new_txn()

    def _next_tx(self):
        if self.mode == "read":
            m = self._mem()
            v = m[self.raddr % len(m)]
            self.raddr += 1
            return v
        if self.mode == "status":
            if self.busy_left > 0:
                self.busy_left -= 1
                return 0x01
            return 0x00
        return self.tx.pop(0) if self.tx else 0xFF

    async def run(self):
        dut = self.dut
        dut.mem_dq1.value = 1
        dut.mem_dq1_oe.value = 0
        cocotb.start_soon(self._cs_watch(dut.bus, 0, "flash"))
        cocotb.start_soon(self._cs_watch(dut.bus, 6, "psram"))
        while True:
            await Edge(dut.bus)
            sel = self.dev is not None
            dut.mem_dq1_oe.value = 1 if sel else 0
            if not sel:
                continue
            sck = bit(dut.bus.value, 3, 0)
            if sck == self.last_sck:
                continue
            self.last_sck = sck
            if sck:
                self.rx = ((self.rx << 1) | bit(dut.bus.value, 1)) & 0xFF
                self.nbits += 1
                if self.nbits == 8:
                    self.nbits = 0
                    self._on_byte(self.rx)
            else:
                if self.nbits == 0:
                    self.cur = self._next_tx()
                dut.mem_dq1.value = (self.cur >> 7) & 1
                self.cur = (self.cur << 1) & 0xFF

    async def _cs_watch(self, bus, bitno, name):
        prev = 1
        while True:
            await Edge(bus)
            cs = bit(bus.value, bitno)
            if cs != prev:
                if cs == 0:
                    self._new_txn()
                    self.dev = name
                    self.last_sck = bit(bus.value, 3, 0)
                elif self.dev == name:
                    self._on_cs_rise()
                    self.dev = None
                prev = cs


@cocotb.test()
async def test_card_to_running_game(dut):
    """A real game.bin on a card ends up executing on the console."""
    assert GAME.exists(), "sw/game.bin not built - run `python sw/build.py`"
    payload = GAME.read_bytes()
    image = sdwrite.build_image(payload)

    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())

    sd_pins = SimpleNamespace(cs_n=dut.ldr_sd_cs_n, sck=dut.ldr_sd_sck,
                              mosi=dut.ldr_sd_mosi, miso=dut.sd_miso)
    card = SdCard(sd_pins, image)
    cart = CartBus(dut)
    cocotb.start_soon(card.run())
    cocotb.start_soon(cart.run())

    dut.sd_present.value = 1
    dut.ui_in.value = 0
    dut.rst.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk)
    dut.rst.value = 0

    # ---- phase 1: the loader puts the image in flash ----
    for _ in range(30_000_000):
        await RisingEdge(dut.clk)
        if dut.ldr_done.value == 1:
            break
    else:
        raise AssertionError("the loader never finished")

    assert dut.ldr_err.value == 0, (
        "loader error, status=0x%02x" % int(dut.ldr_status.value))
    assert bytes(cart.flash[0:len(payload)]) == payload, (
        "the cartridge flash does not match sw/game.bin")
    # The resident header must be byte-identical to the one sdwrite.py put in
    # block 0 - that is what makes the next boot's skip-compare trustworthy.
    assert bytes(cart.flash[0xFFF000:0xFFF010]) == image[0:16]

    # ---- phase 2: the SoC boots out of that flash and runs the game ----
    # draw_map() is the first thing main() does, so the tile map appearing in
    # PSRAM proves the CPU fetched, decoded and executed real compiled code
    # out of the image the loader just wrote.
    for _ in range(6_000_000):
        await RisingEdge(dut.clk)
        if cart.psram[TILEMAP_BASE + 14 * 20 + 19] != 0:
            break
    else:
        raise AssertionError(
            "the tile map was never fully written - the CPU did not run main()")

    top = bytes(cart.psram[TILEMAP_BASE:TILEMAP_BASE + 20])
    assert set(top) == {4}, "top border row is %s, expected all 0x04" % top.hex()

    interior = cart.psram[TILEMAP_BASE + 20 + 1]      # row 1, col 1
    assert interior in (0, 2), "interior tile %d is not empty/checker" % interior

    # SYSCTL.video_en is the game's own hardware enable: reaching it means the
    # MMIO path works, not just memory. game.c writes it AFTER draw_map() and
    # after the OAM entries, so it has to be polled for rather than sampled the
    # instant the map completes.
    for _ in range(2_000_000):
        await RisingEdge(dut.clk)
        if int(dut.console.soc.regs.sysctl_r.value) & 1:
            break
    else:
        raise AssertionError("video_en never set - the game never reached SYSCTL")

    # game.c writes the three static markers BEFORE SYSCTL, so by now they are
    # guaranteed live. Sprite 0 is the player and is written inside the main
    # loop, i.e. strictly after SYSCTL, so it has to be waited for.
    oam1 = int(dut.console.soc.regs.oam_r[1].value)
    assert oam1 & (1 << 24), "static sprite 1 is not enabled (OAM1=0x%x)" % oam1

    for _ in range(2_000_000):
        await RisingEdge(dut.clk)
        if int(dut.console.soc.regs.oam_r[0].value) & (1 << 24):
            break
    else:
        raise AssertionError("the game loop never placed the player sprite")
