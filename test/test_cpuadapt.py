# test_cpuadapt.py — the CPU adapter: a cocotb model of the TinyRV32 core issues
# word fetch / load / store, and the adapter turns them into the console's
# byte-streaming bus (through the real arbiter + controller + memories) or the
# on-chip MMIO. Checks fetch pairs, word/byte data, and the MMIO carve-out.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from test_qspi import SpiMem, qspi_bus

FLASH_SIZE = 1 << 16
RAM_SIZE = 1 << 16


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 40, "ns").start())
    flash = SpiMem(FLASH_SIZE, writable=False)
    ram = SpiMem(RAM_SIZE, writable=True)
    for i in range(FLASH_SIZE):
        flash.mem[i] = (i * 7 + 0x11) & 0xFF
    for i in range(RAM_SIZE):
        ram.mem[i] = (i * 13 + 7) & 0xFF
    cocotb.start_soon(qspi_bus(dut, flash, ram))

    for s in ("if_req", "if_addr", "d_req", "d_we", "d_addr", "d_wdata", "d_be"):
        getattr(dut, s).value = 0
    dut.cfg.value = 0b11
    dut.sd_in.value = 0xF
    dut.rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    return flash, ram


def word_at(mem, byte_addr):
    return sum(mem[(byte_addr + k) % len(mem)] << (8 * k) for k in range(4))


async def fetch(dut, word_addr, cap=2000):
    dut.if_addr.value = word_addr
    dut.if_req.value = 1
    for _ in range(cap):
        await RisingEdge(dut.clk)
        if int(dut.if_ack.value):
            w0, w1 = int(dut.if_rdata.value), int(dut.if_rdata2.value)
            break
    else:
        raise TimeoutError("fetch never acked")
    dut.if_req.value = 0
    await RisingEdge(dut.clk)
    return w0, w1


async def data(dut, word_addr, we, wdata=0, be=0xF, cap=2000):
    dut.d_addr.value = word_addr
    dut.d_we.value = we
    dut.d_wdata.value = wdata
    dut.d_be.value = be
    dut.d_req.value = 1
    for _ in range(cap):
        await RisingEdge(dut.clk)
        if int(dut.d_ack.value):
            rd = int(dut.d_rdata.value)
            break
    else:
        raise TimeoutError("data never acked")
    dut.d_req.value = 0
    await RisingEdge(dut.clk)
    return rd


FLASH_W = lambda a: a >> 2                    # byte addr -> word addr (flash, dev 0)
PSRAM_W = lambda a: (1 << 22) | (a >> 2)      # byte addr within PSRAM -> word addr
MMIO_W = lambda off: (0x01FF0000 + off * 4) >> 2   # console MMIO word addr


@cocotb.test()
async def fetch_pair(dut):
    flash, ram = await setup(dut)
    w0, w1 = await fetch(dut, FLASH_W(0x100))
    assert w0 == word_at(flash.mem, 0x100), hex(w0)
    assert w1 == word_at(flash.mem, 0x104), hex(w1)


@cocotb.test()
async def load_word(dut):
    flash, ram = await setup(dut)
    rd = await data(dut, PSRAM_W(0x40), we=0)
    assert rd == word_at(ram.mem, 0x40), hex(rd)


@cocotb.test()
async def store_word_and_byte(dut):
    flash, ram = await setup(dut)
    await data(dut, PSRAM_W(0x80), we=1, wdata=0xDEADBEEF, be=0xF)
    assert list(ram.mem[0x80:0x84]) == [0xEF, 0xBE, 0xAD, 0xDE]
    rd = await data(dut, PSRAM_W(0x80), we=0)
    assert rd == 0xDEADBEEF, hex(rd)
    # byte store into lane 2
    await data(dut, PSRAM_W(0x80), we=1, wdata=0x00AA0000, be=0b0100)
    assert ram.mem[0x82] == 0xAA
    rd = await data(dut, PSRAM_W(0x80), we=0)
    assert rd == 0xDEAABEEF, hex(rd)


@cocotb.test()
async def mmio_carveout(dut):
    flash, ram = await setup(dut)
    sp = 10 | (4 << 8) | (0x30 << 16) | (1 << 24)      # an OAM sprite word
    await data(dut, MMIO_W(0), we=1, wdata=sp, be=0xF)
    rd = await data(dut, MMIO_W(0), we=0)
    assert rd == sp, hex(rd)
    # a memory access still goes to QSPI, unaffected
    m = await data(dut, PSRAM_W(0x200), we=0)
    assert m == word_at(ram.mem, 0x200), hex(m)


@cocotb.test()
async def mmio_partial_write(dut):
    """C2: sb/sh into an MMIO register must touch only the enabled lanes, not
    clobber the whole 32-bit word (an sb to OAM byte 1 was replacing the entire
    sprite entry)."""
    flash, ram = await setup(dut)
    await data(dut, MMIO_W(0), we=1, wdata=0x11223344, be=0xF)   # seed full word
    # sb into lane 1 (byte enable 0b0010): only bits [15:8] change
    await data(dut, MMIO_W(0), we=1, wdata=0x0000AA00, be=0b0010)
    rd = await data(dut, MMIO_W(0), we=0)
    assert rd == 0x1122AA44, hex(rd)
    # sh into lanes 2-3 (byte enable 0b1100): only bits [31:16] change
    await data(dut, MMIO_W(0), we=1, wdata=0xBBCC0000, be=0b1100)
    rd = await data(dut, MMIO_W(0), we=0)
    assert rd == 0xBBCCAA44, hex(rd)
    # lane 0 (0b0001) alone
    await data(dut, MMIO_W(0), we=1, wdata=0x000000EE, be=0b0001)
    rd = await data(dut, MMIO_W(0), we=0)
    assert rd == 0xBBCCAAEE, hex(rd)


@cocotb.test()
async def psram_high_mirror_rejected(dut):
    """C3: the APS6404 has only A[22:0] (8 MiB); an access to the dev-1 high
    mirror (offset >= 8 MiB) must be rejected, not silently aliased onto the low
    8 MiB. Without the fix the high write lands on the same physical byte."""
    flash, ram = await setup(dut)
    HIGH = (1 << 22) | (0x800000 >> 2)                 # PSRAM offset 0x800000
    await data(dut, PSRAM_W(0x0), we=1, wdata=0xCAFEF00D, be=0xF)   # low byte 0
    await data(dut, HIGH, we=1, wdata=0xDEADBEEF, be=0xF)           # must be rejected
    rd = await data(dut, PSRAM_W(0x0), we=0)
    assert rd == 0xCAFEF00D, hex(rd)                   # low byte 0 untouched
    rd2 = await data(dut, HIGH, we=0)
    assert rd2 == 0, hex(rd2)                          # rejected read returns 0
