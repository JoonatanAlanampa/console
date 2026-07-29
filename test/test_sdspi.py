# test_sdspi.py — the harness-side microSD reader against a behavioural card.
#
# The model is a real SPI-mode slave, not a stub: it tracks chip select, byte
# alignment and the NCR gap, answers R1/R3/R7 with the right shapes, makes
# ACMD41 report "still initialising" a few times before it succeeds (a cold
# card always does), and only then serves data. That matters because every one
# of those is a place the sequencer can hang, and a stub that answers instantly
# would prove nothing about the retry paths.

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Edge, RisingEdge, Timer

BLOCK = 512


class SdCard:
    """Behavioural SD card, SPI mode. Drives `miso`, watches `sck`/`cs_n`."""

    def __init__(self, dut, image, acmd41_busy=3, sdhc=True):
        self.dut = dut
        self.image = image
        self.acmd41_left = acmd41_busy
        self.sdhc = sdhc
        self.cmd = []
        self.tx = []            # queued response bytes
        self.seen = []          # command indices, in order — asserted on later
        self.rx = 0
        self.nbits = 0
        self.cur = 0xFF
        self.curbits = 0

    def _respond(self, idx, arg):
        self.seen.append(idx)
        # NCR: a real card always inserts at least one idle byte before R1.
        if idx == 0:                                    # GO_IDLE_STATE
            self.tx += [0xFF, 0x01]
        elif idx == 8:                                  # SEND_IF_COND -> R7
            self.tx += [0xFF, 0x01, 0x00, 0x00, 0x01, 0xAA]
        elif idx == 55:                                 # APP_CMD
            self.tx += [0xFF, 0x01]
        elif idx == 41:                                 # ACMD41
            if self.acmd41_left > 0:
                self.acmd41_left -= 1
                self.tx += [0xFF, 0x01]                 # still initialising
            else:
                self.tx += [0xFF, 0x00]
        elif idx == 58:                                 # READ_OCR -> R3
            ccs = 0x40 if self.sdhc else 0x00
            self.tx += [0xFF, 0x00, 0x80 | ccs, 0xFF, 0x80, 0x00]
        elif idx == 16:                                 # SET_BLOCKLEN
            self.tx += [0xFF, 0x00]
        elif idx == 17:                                 # READ_SINGLE_BLOCK
            blk = arg if self.sdhc else arg // BLOCK
            data = self.image[blk * BLOCK:(blk + 1) * BLOCK]
            data = data + bytes(BLOCK - len(data))      # past the end reads 0
            # R1, a realistic wait, the token, the payload, a dummy CRC
            self.tx += [0xFF, 0x00, 0xFF, 0xFF, 0xFE] + list(data) + [0x5A, 0xA5]
        else:
            self.tx += [0xFF, 0x04]                     # illegal command

    async def run(self):
        dut = self.dut
        dut.miso.value = 1
        while True:
            await Edge(dut.sck)
            if dut.cs_n.value == 1:
                # Deselected: release the line and forget any bit phase.
                dut.miso.value = 1
                self.nbits = 0
                self.curbits = 0
                self.cmd = []
                self.tx = []
                continue

            if dut.sck.value == 1:
                # rising edge: the card samples MOSI
                self.rx = ((self.rx << 1) | int(dut.mosi.value)) & 0xFF
                self.nbits += 1
                if self.nbits == 8:
                    self.nbits = 0
                    b = self.rx
                    if not self.cmd:
                        if (b & 0xC0) == 0x40:          # start bit + transmitter
                            self.cmd = [b]
                    else:
                        self.cmd.append(b)
                        if len(self.cmd) == 6:
                            idx = self.cmd[0] & 0x3F
                            arg = int.from_bytes(bytes(self.cmd[1:5]), "big")
                            self.cmd = []
                            self._respond(idx, arg)
            else:
                # Falling edge: present the bit the master will sample on the
                # NEXT rising edge. Byte framing is keyed to `nbits`, the
                # master's own rising-edge count, not to an independent
                # counter — a card that framed its replies on the first
                # falling edge it happened to see would be offset by one bit
                # from the master forever, which is exactly the bug this
                # comment exists to stop someone reintroducing.
                if self.nbits == 0:
                    self.cur = self.tx.pop(0) if self.tx else 0xFF
                dut.miso.value = (self.cur >> 7) & 1
                self.cur = (self.cur << 1) & 0xFF


async def setup(dut, image, **kw):
    cocotb.start_soon(Clock(dut.clk, 40, units="ns").start())   # 25 MHz
    card = SdCard(dut, image, **kw)
    cocotb.start_soon(card.run())

    dut.rst.value = 1
    dut.init.value = 0
    dut.rd.value = 0
    dut.blk.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    return card


async def do_init(dut, timeout=400_000):
    dut.init.value = 1
    await RisingEdge(dut.clk)
    dut.init.value = 0
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.ready.value == 1:
            return
        assert dut.err.value == 0, "sd_spi reported an error during init"
    raise AssertionError("sd_spi never became ready")


async def read_block(dut, blk, timeout=400_000):
    dut.blk.value = blk
    dut.rd.value = 1
    await RisingEdge(dut.clk)
    dut.rd.value = 0
    out = bytearray()
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.rvalid.value == 1:
            out.append(int(dut.rdata.value))
        if dut.rdone.value == 1:
            return bytes(out)
        assert dut.err.value == 0, f"error reading block {blk}"
    raise AssertionError(f"block {blk} read never completed")


@cocotb.test()
async def test_init_sdhc(dut):
    """A cold SDHC card reaches ready, and takes the documented route there."""
    card = await setup(dut, bytes(BLOCK * 4))
    await do_init(dut)
    assert dut.err.value == 0
    # CMD0 -> CMD8 -> (CMD55/ACMD41 xN) -> CMD58. No CMD16: SDHC is fixed 512.
    assert card.seen[0] == 0, f"first command was {card.seen[0]}, expected CMD0"
    assert 8 in card.seen, "CMD8 (SEND_IF_COND) was never issued"
    assert card.seen.count(41) >= 4, (
        f"ACMD41 issued {card.seen.count(41)}x; the model stayed busy for 3, so "
        "the retry loop is not looping"
    )
    assert card.seen[-1] == 58, "CMD58 (READ_OCR) must be the last init command"
    assert 16 not in card.seen, "CMD16 must be skipped on a block-addressed card"


@cocotb.test()
async def test_init_sdsc_sends_cmd16(dut):
    """A byte-addressed (<=2 GB) card must additionally get SET_BLOCKLEN."""
    card = await setup(dut, bytes(BLOCK * 4), sdhc=False)
    await do_init(dut)
    assert 16 in card.seen, "CMD16 is required when CCS=0"


@cocotb.test()
async def test_read_blocks(dut):
    """Payload comes back byte-exact, from more than one block."""
    rnd = random.Random(20260729)
    image = bytes(rnd.randrange(256) for _ in range(BLOCK * 4))
    await setup(dut, image)
    await do_init(dut)

    for blk in (0, 3, 1):
        got = await read_block(dut, blk)
        want = image[blk * BLOCK:(blk + 1) * BLOCK]
        assert len(got) == BLOCK, f"block {blk}: got {len(got)} bytes, want {BLOCK}"
        assert got == want, f"block {blk} payload mismatch"


@cocotb.test()
async def test_byte_addressing(dut):
    """On an SDSC card the block number must be shifted into a byte address."""
    rnd = random.Random(7)
    image = bytes(rnd.randrange(256) for _ in range(BLOCK * 4))
    await setup(dut, image, sdhc=False)
    await do_init(dut)
    got = await read_block(dut, 2)
    assert got == image[2 * BLOCK:3 * BLOCK], (
        "SDSC read returned the wrong block — the <<9 byte-address conversion "
        "is wrong"
    )
