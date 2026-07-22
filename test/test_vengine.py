# test_vengine.py — the whole video engine (vga_timing -> vga_engine: ping-pong
# buffers + tile renderer) rendering real pixels, fetched through the real
# arbiter + controller + bit-level memories. Every visible pixel on a band of
# steady-state scanlines must equal the tile map / pattern table decode.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from test_qspi import SpiMem, qspi_bus

FLASH_SIZE = 1 << 16
RAM_SIZE = 1 << 16
TILEMAP_BASE = 0x010000
PATTERN_BASE = 0x000000
TILES = 20

# palette (matches vga_engine defaults) -> (r,g,b) per 2bpp index
PAL = [(0, 0, 0), (3, 0, 0), (0, 3, 0), (3, 3, 3)]


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 40, "ns").start())
    flash = SpiMem(FLASH_SIZE, writable=False)
    ram = SpiMem(RAM_SIZE, writable=True)
    for i in range(FLASH_SIZE):
        flash.mem[i] = (i * 7 + 0x11) & 0xFF                # pattern table
    for i in range(RAM_SIZE):
        ram.mem[i] = (i * 13 + 7) & 0xFF                    # tile map
    cocotb.start_soon(qspi_bus(dut, flash, ram))

    dut.cfg.value = 0b11
    dut.sd_in.value = 0xF
    dut.rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    return flash, ram


def expected_pixel(flash, ram, x, y):
    vx, vy = x >> 2, y >> 2                                  # logical 160x120
    tcol, pxi = x >> 5, vx & 7
    trow, rin = vy >> 3, vy & 7
    mb = ram.mem[(TILEMAP_BASE + trow * TILES + tcol) % RAM_SIZE]
    paddr = PATTERN_BASE + mb * 16 + rin * 2
    hi = flash.mem[paddr % FLASH_SIZE]
    lo = flash.mem[(paddr + 1) % FLASH_SIZE]
    idx = (((hi >> (7 - pxi)) & 1) << 1) | ((lo >> (7 - pxi)) & 1)
    return PAL[idx]


@cocotb.test()
async def render_steady_state(dut):
    """Check every visible pixel on screen lines 8..47 (logical lines 2..11),
    i.e. steady-state ping-pong: line L is on screen while L+1 fetches."""
    flash, ram = await setup(dut)

    while not (dut.y.value.is_resolvable and int(dut.y.value) >= 8):
        await RisingEdge(dut.clk)

    checks = 0
    while True:
        await RisingEdge(dut.clk)
        if int(dut.y.value) >= 48:
            break
        if int(dut.de.value):
            xx, yy = int(dut.x.value), int(dut.y.value)
            exp = expected_pixel(flash, ram, xx, yy)
            got = (int(dut.r.value), int(dut.g.value), int(dut.b.value))
            assert got == exp, f"pixel ({xx},{yy}): got {got} exp {exp}"
            checks += 1

    assert checks > 15000, f"too few pixels checked ({checks})"
    cocotb.log.info(f"RENDER: {checks} pixels verified across lines 8..47")
