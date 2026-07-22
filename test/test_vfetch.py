# test_vfetch.py — the race-the-beam tile fetcher against the real arbiter +
# controller + bit-level memories. Checks the fetched pattern pairs match the
# tile map / pattern table, and MEASURES how many system clocks a full 40-tile
# line takes — the number that decides whether scattered per-tile fetches fit
# the 800-clock (32 us) scanline at all.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from test_qspi import SpiMem, qspi_bus

FLASH_SIZE = 1 << 16
RAM_SIZE = 1 << 16
TILEMAP_BASE = 0x010000        # vga_fetch defaults
PATTERN_BASE = 0x000000
TILES = 20                     # 160-wide
LINE_BUDGET = 3200             # 4 screen lines (4x vertical) of display time


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 40, "ns").start())     # 25 MHz
    flash = SpiMem(FLASH_SIZE, writable=False)
    ram = SpiMem(RAM_SIZE, writable=True)
    for i in range(FLASH_SIZE):
        flash.mem[i] = (i * 7 + 0x11) & 0xFF                # pattern table
    for i in range(RAM_SIZE):
        ram.mem[i] = (i * 13 + 7) & 0xFF                    # tile map
    cocotb.start_soon(qspi_bus(dut, flash, ram))

    dut.start.value = 0
    dut.line_y.value = 0
    dut.pop.value = 0
    dut.cpu_req.value = 0
    dut.cpu_we.value = 0
    dut.cpu_dev.value = 0
    dut.cpu_addr.value = 0
    dut.cpu_len.value = 1
    dut.cpu_wdata.value = 0
    dut.cfg.value = 0b11
    dut.sd_in.value = 0xF
    dut.rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    return flash, ram


def expected_line(flash, ram, line_y):
    tile_row = line_y >> 3
    row_in = line_y & 7
    out = []
    for col in range(TILES):
        maddr = (TILEMAP_BASE + tile_row * TILES + col) % RAM_SIZE
        mb = ram.mem[maddr]
        paddr = PATTERN_BASE + mb * 16 + row_in * 2
        hi = flash.mem[paddr % FLASH_SIZE]
        lo = flash.mem[(paddr + 1) % FLASH_SIZE]
        out.append((hi << 8) | lo)
    return out


async def pop_one(dut):
    dut.pop.value = 1
    await RisingEdge(dut.clk)
    dut.pop.value = 0


@cocotb.test()
async def fetch_line_correct_and_timed(dut):
    """Fetch a whole line with no CPU load; check every tile pair and report the
    clocks the line took (the scanline-budget number)."""
    flash, ram = await setup(dut)
    exp = expected_line(flash, ram, line_y=17)

    dut.line_y.value = 17
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    got = []
    clocks = 0
    while len(got) < TILES:
        await RisingEdge(dut.clk)
        clocks += 1
        if not int(dut.empty.value):
            got.append(int(dut.tile_pat.value))
            await pop_one(dut)
            clocks += 1
        assert clocks < 20000, "line fetch hung"

    assert got == exp, f"tile mismatch\n got {got[:6]}\n exp {exp[:6]}"
    cocotb.log.info(f"LINE FETCH (no load): {TILES} tiles in {clocks} clocks "
                    f"(budget {LINE_BUDGET})")
    assert clocks < LINE_BUDGET, f"even unloaded over budget: {clocks}"


@cocotb.test()
async def fetch_line_under_load(dut):
    """Fetch a whole line ahead while the CPU hammers the bus with back-to-back
    PSRAM reads; the fill must finish inside the 3200-clock line-display budget
    (the time the previous line is on screen) and the data must be correct."""
    flash, ram = await setup(dut)
    exp = expected_line(flash, ram, line_y=33)
    stop = {"go": True}

    async def cpu_hammer():
        while stop["go"]:
            dut.cpu_dev.value = 1
            dut.cpu_addr.value = 0x4000
            dut.cpu_len.value = 60
            dut.cpu_we.value = 0
            dut.cpu_req.value = 1
            for _ in range(20000):
                await RisingEdge(dut.clk)
                if int(dut.cpu_ack.value):
                    break
            dut.cpu_req.value = 0
            await RisingEdge(dut.clk)

    cocotb.start_soon(cpu_hammer())
    for _ in range(50):                    # let the CPU get mid-burst
        await RisingEdge(dut.clk)

    dut.line_y.value = 33
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    got = []
    clocks = 0
    while len(got) < TILES:                # drain as fast as the bus fills
        await RisingEdge(dut.clk)
        clocks += 1
        if not int(dut.empty.value):
            got.append(int(dut.tile_pat.value))
            await pop_one(dut)
            clocks += 1
        assert clocks < 20000, "line fetch hung"
    stop["go"] = False

    assert got == exp, "tile mismatch under load"
    cocotb.log.info(f"LINE UNDER LOAD: 20 tiles in {clocks} clocks (budget {LINE_BUDGET})")
    assert clocks < LINE_BUDGET, f"missed the line budget: {clocks} >= {LINE_BUDGET}"
