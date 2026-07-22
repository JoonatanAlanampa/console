# test_soc.py — the integrated console (everything but the CPU core). cocotb
# drives the fetch/data/MMIO ports the CPU will own and checks the pieces work
# together: the MMIO control plane, audio playing, and -- the real integration
# proof -- video rendering the correct picture WHILE the CPU shares the bus.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from test_qspi import SpiMem, qspi_bus

FLASH_SIZE = 1 << 16
RAM_SIZE = 1 << 16
TILEMAP_BASE = 0x010000
PATTERN_BASE = 0x000000
TILES = 20
PAL = [(0, 0, 0), (3, 0, 0), (0, 3, 0), (3, 3, 3)]

# MMIO word offsets (sysregs)
OAM0, SYSCTL, AUD0, PADS = 0x00, 0x08, 0x10, 0x18


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 40, "ns").start())
    flash = SpiMem(FLASH_SIZE, writable=False)
    ram = SpiMem(RAM_SIZE, writable=True)
    for i in range(FLASH_SIZE):
        flash.mem[i] = (i * 7 + 0x11) & 0xFF
    for i in range(RAM_SIZE):
        ram.mem[i] = (i * 13 + 7) & 0xFF
    cocotb.start_soon(qspi_bus(dut, flash, ram))

    for s in ("f_req", "f_dev", "f_addr", "d_req", "d_we", "d_dev", "d_addr",
              "d_wdata", "m_sel", "m_we", "m_addr", "m_wdata", "pad0_btn", "pad1_btn"):
        getattr(dut, s).value = 0
    dut.f_len.value = 1
    dut.d_len.value = 1
    dut.sd_in.value = 0xF
    dut.rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    return flash, ram


async def mmio_write(dut, addr, data):
    dut.m_sel.value = 1
    dut.m_we.value = 1
    dut.m_addr.value = addr
    dut.m_wdata.value = data
    await RisingEdge(dut.clk)
    dut.m_sel.value = 0
    dut.m_we.value = 0
    await RisingEdge(dut.clk)


async def mmio_read(dut, addr):
    dut.m_addr.value = addr
    dut.m_sel.value = 1
    await RisingEdge(dut.clk)
    v = int(dut.m_rdata.value)
    dut.m_sel.value = 0
    return v


async def cpu_dread(dut, dev, addr, length, cap=20000):
    dut.d_req.value = 1
    dut.d_we.value = 0
    dut.d_dev.value = dev
    dut.d_addr.value = addr
    dut.d_len.value = length
    got = []
    for _ in range(cap):
        await RisingEdge(dut.clk)
        if int(dut.d_rvalid.value):
            got.append(int(dut.d_rdata.value))
        if int(dut.d_ack.value):
            break
    dut.d_req.value = 0
    await RisingEdge(dut.clk)
    return got


def oam_word(en, sx, sy, st):
    return (sx & 0xFF) | ((sy & 0xFF) << 8) | ((st & 0xFF) << 16) | ((1 if en else 0) << 24)


def expected_pixel(flash, ram, x, y, sprites=()):
    vx, vy = x >> 2, y >> 2
    tcol, pxi = x >> 5, vx & 7
    trow, rin = vy >> 3, vy & 7
    mb = ram.mem[(TILEMAP_BASE + trow * TILES + tcol) % RAM_SIZE]
    pa = PATTERN_BASE + mb * 16 + rin * 2
    idx = (((flash.mem[pa % FLASH_SIZE] >> (7 - pxi)) & 1) << 1) | \
          ((flash.mem[(pa + 1) % FLASH_SIZE] >> (7 - pxi)) & 1)
    for (en, sx, sy, st) in sprites:
        if en and sy <= vy < sy + 8 and sx <= vx < sx + 8:
            spa = PATTERN_BASE + st * 16 + (vy - sy) * 2
            sc = vx - sx
            si = (((flash.mem[spa % FLASH_SIZE] >> (7 - sc)) & 1) << 1) | \
                 ((flash.mem[(spa + 1) % FLASH_SIZE] >> (7 - sc)) & 1)
            if si != 0:
                idx = si
                break
    return PAL[idx]


@cocotb.test()
async def soc_control_plane(dut):
    """MMIO write/read of sysctl, OAM and audio registers; audio then plays."""
    flash, ram = await setup(dut)
    await mmio_write(dut, SYSCTL, 0b111)                 # video_en=1, cfg=0b11
    assert await mmio_read(dut, SYSCTL) == 0b111
    sp = oam_word(1, 10, 4, 0x30)
    await mmio_write(dut, OAM0, sp)
    assert await mmio_read(dut, OAM0) == sp
    aud = 0x4000 | (0 << 16) | (15 << 18)               # square, freq 0x4000, vol 15
    await mmio_write(dut, AUD0, aud)
    assert await mmio_read(dut, AUD0) == aud

    hi = 0
    for _ in range(4000):
        await RisingEdge(dut.clk)
        hi += int(dut.audio_out.value)
    assert 0.1 < hi / 4000 < 0.9, f"audio not playing ({hi / 4000})"


@cocotb.test()
async def soc_render_and_bus_share(dut):
    """The heart of it: with video enabled and a sprite in OAM, the beam renders
    the correct picture while the CPU hammers data reads on the SAME bus, and
    those reads still return correct memory."""
    flash, ram = await setup(dut)
    await mmio_write(dut, SYSCTL, 0b111)
    sprites = [(1, 10, 4, 0x30)]
    await mmio_write(dut, OAM0, oam_word(*sprites[0]))

    stop = {"go": True}
    reads = {"ok": 0, "bad": 0}

    async def cpu():
        while stop["go"]:
            got = await cpu_dread(dut, dev=1, addr=0x5000, length=16)
            exp = [ram.mem[(0x5000 + k) % RAM_SIZE] for k in range(16)]
            reads["ok" if got == exp else "bad"] += 1

    cocotb.start_soon(cpu())

    while not (dut.soc.vy.value.is_resolvable and int(dut.soc.vy.value) >= 8):
        await RisingEdge(dut.clk)

    checks = 0
    while True:
        await RisingEdge(dut.clk)
        if int(dut.soc.vy.value) >= 48:
            break
        if int(dut.soc.de.value):
            xx, yy = int(dut.soc.vx.value), int(dut.soc.vy.value)
            exp = expected_pixel(flash, ram, xx, yy, sprites)
            got = (int(dut.vga_r.value), int(dut.vga_g.value), int(dut.vga_b.value))
            assert got == exp, f"pixel ({xx},{yy}): got {got} exp {exp}"
            checks += 1
    stop["go"] = False

    assert checks > 15000, checks
    assert reads["ok"] > 0 and reads["bad"] == 0, f"CPU bus reads: {reads}"
    cocotb.log.info(f"SOC: {checks} pixels ok, {reads['ok']} CPU bus reads ok")
