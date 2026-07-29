# test_spiflash.py — the harness-side W25Q128 driver against a behavioural part.
#
# The model enforces the two rules that actually bite on real hardware and that
# a permissive stub would hide:
#   * an erase or program with no preceding WREN is IGNORED (the write-enable
#     latch is not set), and it self-clears afterwards, so each write needs its
#     own 06h;
#   * a program only ANDs bits into place — it can clear 1->0 but never set
#     0->1 — so skipping the erase leaves corrupt data rather than an error.
# It also stays BUSY for a few status reads, which is the only way to prove the
# RDSR poll loop is really polling.

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Edge, RisingEdge

OP_ID, OP_READ, OP_ERASE, OP_PROG = 0, 1, 2, 3
SECTOR = 4096


class FlashChip:
    """Behavioural W25Q128, SPI mode 0. Drives `miso`, watches `sck`/`cs_n`."""

    def __init__(self, dut, size=1 << 20, busy_reads=3):
        self.dut = dut
        self.mem = bytearray(b"\xff" * size)
        self.busy_reads = busy_reads
        self.wel = False
        self.busy_left = 0
        self.status_reads = 0
        self.wren_count = 0
        self.no_wren_writes = 0     # erases/programs attempted with WEL clear
        self._new_txn()

    def _new_txn(self):
        self.buf = []
        self.mode = None            # None | "id" | "read" | "status"
        self.raddr = 0
        self.tx = []
        self.rx = 0
        self.nbits = 0
        self.cur = 0xFF

    def _on_byte(self, b):
        self.buf.append(b)
        n = len(self.buf)
        op = self.buf[0]

        if op == 0x9F and n == 1:
            self.mode = "id"
            self.tx = [0xEF, 0x40, 0x18]
        elif op == 0x05 and n == 1:
            self.mode = "status"
        elif op == 0x03 and n == 4:
            self.mode = "read"
            self.raddr = int.from_bytes(bytes(self.buf[1:4]), "big")

    def _on_cs_rise(self):
        """Erases and programs only take effect when CS rises."""
        if self.buf:
            op = self.buf[0]
            if op == 0x06:
                self.wel = True
                self.wren_count += 1
            elif op == 0x20 and len(self.buf) >= 4:
                if not self.wel:
                    self.no_wren_writes += 1
                else:
                    a = int.from_bytes(bytes(self.buf[1:4]), "big") & ~(SECTOR - 1)
                    self.mem[a:a + SECTOR] = b"\xff" * SECTOR
                    self.wel = False
                    self.busy_left = self.busy_reads
            elif op == 0x02 and len(self.buf) >= 4:
                if not self.wel:
                    self.no_wren_writes += 1
                else:
                    a = int.from_bytes(bytes(self.buf[1:4]), "big")
                    for i, v in enumerate(self.buf[4:]):
                        # NOR flash programs by clearing bits only
                        self.mem[a + i] &= v
                    self.wel = False
                    self.busy_left = self.busy_reads
        self._new_txn()

    def _next_tx(self):
        if self.mode == "read":
            v = self.mem[self.raddr]
            self.raddr += 1
            return v
        if self.mode == "status":
            self.status_reads += 1
            if self.busy_left > 0:
                self.busy_left -= 1
                return 0x01                 # BUSY
            return 0x00
        return self.tx.pop(0) if self.tx else 0xFF

    async def run_cs(self):
        dut = self.dut
        while True:
            await Edge(dut.cs_n)
            if dut.cs_n.value == 1:
                self._on_cs_rise()
                dut.miso.value = 1

    async def run(self):
        dut = self.dut
        dut.miso.value = 1
        cocotb.start_soon(self.run_cs())
        while True:
            await Edge(dut.sck)
            if dut.cs_n.value == 1:
                continue
            if dut.sck.value == 1:
                self.rx = ((self.rx << 1) | int(dut.mosi.value)) & 0xFF
                self.nbits += 1
                if self.nbits == 8:
                    self.nbits = 0
                    self._on_byte(self.rx)
            else:
                # Byte framing keyed to the master's rising-edge count — see
                # the same note in test_sdspi.py.
                if self.nbits == 0:
                    self.cur = self._next_tx()
                dut.miso.value = (self.cur >> 7) & 1
                self.cur = (self.cur << 1) & 0xFF


async def setup(dut, **kw):
    cocotb.start_soon(Clock(dut.clk, 40, units="ns").start())
    chip = FlashChip(dut, **kw)
    cocotb.start_soon(chip.run())

    dut.rst.value = 1
    dut.start.value = 0
    dut.op.value = 0
    dut.addr.value = 0
    dut.len.value = 0
    dut.wdata.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    return chip


async def run_op(dut, op, addr=0, length=0, payload=None, timeout=2_000_000):
    """Drive one operation; feed `payload` on wnext, collect rvalid bytes."""
    dut.op.value = op
    dut.addr.value = addr
    dut.len.value = length
    idx = 0
    if payload:
        dut.wdata.value = payload[0]
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    out = bytearray()
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.rvalid.value == 1:
            out.append(int(dut.rdata.value))
        if payload and dut.wnext.value == 1:
            idx += 1
            dut.wdata.value = payload[idx] if idx < len(payload) else 0xFF
        if dut.done.value == 1:
            return bytes(out)
    raise AssertionError(f"op {op} never completed")


@cocotb.test()
async def test_jedec_id(dut):
    """9Fh identifies the part — the harness's proof the cartridge is alive."""
    await setup(dut)
    got = await run_op(dut, OP_ID, length=3)
    assert got == bytes([0xEF, 0x40, 0x18]), f"JEDEC ID came back as {got.hex()}"


@cocotb.test()
async def test_erase_program_readback(dut):
    """The real cycle: erase a sector, program a page, read it back exactly."""
    chip = await setup(dut)
    rnd = random.Random(4242)
    page = bytes(rnd.randrange(256) for _ in range(256))

    await run_op(dut, OP_ERASE, addr=0)
    await run_op(dut, OP_PROG, addr=0, length=256, payload=page)
    got = await run_op(dut, OP_READ, addr=0, length=256)

    assert got == page, "read-back does not match what was programmed"
    assert chip.mem[0:256] == page, "the part's own array disagrees"


@cocotb.test()
async def test_every_write_sends_its_own_wren(dut):
    """WEL self-clears, so erase and program each need their own 06h."""
    chip = await setup(dut)
    await run_op(dut, OP_ERASE, addr=0)
    await run_op(dut, OP_PROG, addr=0, length=4, payload=b"\x01\x02\x03\x04")
    assert chip.no_wren_writes == 0, (
        f"{chip.no_wren_writes} write(s) reached the part with WEL clear — "
        "they would have been silently discarded on real hardware"
    )
    assert chip.wren_count == 2, f"expected 2 WREN frames, saw {chip.wren_count}"


@cocotb.test()
async def test_busy_poll_actually_polls(dut):
    """RDSR must be read until BUSY clears, not read once and assumed done."""
    chip = await setup(dut, busy_reads=5)
    await run_op(dut, OP_ERASE, addr=0)
    assert chip.status_reads >= 6, (
        f"only {chip.status_reads} status reads; the part claimed BUSY 5 times, "
        "so the poll loop is not waiting for it to clear"
    )


@cocotb.test()
async def test_program_spans_a_second_page(dut):
    """Two 256-byte pages land at the right offsets within one sector."""
    await setup(dut)
    rnd = random.Random(99)
    a = bytes(rnd.randrange(256) for _ in range(256))
    b = bytes(rnd.randrange(256) for _ in range(256))

    await run_op(dut, OP_ERASE, addr=0)
    await run_op(dut, OP_PROG, addr=0x000, length=256, payload=a)
    await run_op(dut, OP_PROG, addr=0x100, length=256, payload=b)
    got = await run_op(dut, OP_READ, addr=0, length=512)
    assert got == a + b, "page offsets are wrong"
