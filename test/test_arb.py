# test_arb.py — the memory arbiter driving the real full-rate QSPI controller
# and the bit-level flash/PSRAM models. Checks the properties the arbiter exists
# for: fixed priority (video > audio > ifetch > data), atomic grants, the tCEM
# burst cap and the 1 KB PSRAM page-wrap split, and that video meets its deadline
# under worst-case CPU load. The SpiMem slave and pin glue are reused from the
# controller suite (test_qspi) so both blocks are checked against the same model.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from test_qspi import SpiMem, qspi_bus

FLASH_SIZE = 1 << 16
RAM_SIZE = 1 << 16

VID, AUD, IF, DATA = 0, 1, 2, 3          # master indices (priority order)

# shared "master bank": each coroutine mutates its own entry; one driver packs
# the four entries into the flattened DUT vectors every clock.
MB = [dict(req=0, we=0, dev=0, addr=0, len=1, wdata=0) for _ in range(4)]

# the largest controller transaction issued per device — for the tCEM assertion
issued = {"flash": [], "psram": []}

# longest observed cs_ram_n low interval, in clocks (40 ns each). tCEM is a hard
# 8 us ceiling = 200 clocks; a byte-count cap only protects the RAM if the CS#
# low time it produces actually stays under it, so measure the pin, not the math.
CE_LOW_LIMIT = 200
ce_low = {"max_q": 0}


def _reset_bank():
    for m in MB:
        m.update(req=0, we=0, dev=0, addr=0, len=1, wdata=0)


async def driver(dut):
    while True:
        await RisingEdge(dut.clk)
        req = we = dev = addr = length = wdata = 0
        for i in range(4):
            m = MB[i]
            req |= (m["req"] & 1) << i
            we |= (m["we"] & 1) << i
            dev |= (m["dev"] & 1) << i
            addr |= (m["addr"] & 0xFFFFFF) << (i * 24)
            length |= (m["len"] & 0x7F) << (i * 7)
            wdata |= (m["wdata"] & 0xFF) << (i * 8)
        dut.m_req.value = req
        dut.m_we.value = we
        dut.m_dev.value = dev
        dut.m_addr.value = addr
        dut.m_len.value = length
        dut.m_wdata.value = wdata


async def issue_monitor(dut):
    """Record each controller transaction's length, per device, as it starts."""
    prev = 0
    while True:
        await RisingEdge(dut.clk)
        r = int(dut.c_req.value) if dut.c_req.value.is_resolvable else 0
        if r and not prev:                   # c_req rose: a new transaction
            key = "psram" if int(dut.c_dev.value) else "flash"
            issued[key].append(int(dut.c_len.value))
        prev = r


async def ce_monitor(dut):
    """Track the longest cs_ram_n low interval, in clocks — the physical tCEM
    exposure. A byte cap that still lets CS# stay low past 8 us would corrupt
    the RAM, and only a pin-level measurement (not a flat memory model) sees it."""
    run = 0
    while True:
        await RisingEdge(dut.clk)
        low = dut.cs_ram_n.value.is_resolvable and int(dut.cs_ram_n.value) == 0
        if low:
            run += 1
        else:
            if run > ce_low["max_q"]:
                ce_low["max_q"] = run
            run = 0


async def setup(dut, ram_wrap=False):
    cocotb.start_soon(Clock(dut.clk, 40, "ns").start())    # 25 MHz
    flash = SpiMem(FLASH_SIZE, writable=False)
    ram = SpiMem(RAM_SIZE, writable=True, page_wrap=ram_wrap)
    for i in range(FLASH_SIZE):
        flash.mem[i] = (i * 7 + 0x11) & 0xFF
    cocotb.start_soon(qspi_bus(dut, flash, ram))
    cocotb.start_soon(driver(dut))
    cocotb.start_soon(issue_monitor(dut))
    cocotb.start_soon(ce_monitor(dut))
    issued["flash"].clear()
    issued["psram"].clear()
    ce_low["max_q"] = 0

    _reset_bank()
    dut.cfg.value = 0
    dut.sd_in.value = 0xF
    dut.rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    return flash, ram


async def m_read(dut, idx, dev, addr, length, cap=20000):
    MB[idx].update(req=1, we=0, dev=dev, addr=addr, len=length)
    got = []
    cyc = 0
    for cyc in range(cap):
        await RisingEdge(dut.clk)
        if (int(dut.m_rvalid.value) >> idx) & 1:
            got.append(int(dut.m_rdata.value))
        if (int(dut.m_ack.value) >> idx) & 1:
            break
    else:
        raise TimeoutError(f"master {idx} read never acked")
    MB[idx]["req"] = 0
    await RisingEdge(dut.clk)
    assert len(got) == length, f"master {idx}: {len(got)} bytes, expected {length}"
    return got, cyc


async def m_write(dut, idx, dev, addr, data, cap=20000):
    MB[idx].update(req=1, we=1, dev=dev, addr=addr, len=len(data), wdata=data[0])
    i = 0
    for _ in range(cap):
        await RisingEdge(dut.clk)
        if (int(dut.m_wnext.value) >> idx) & 1:
            i += 1
            if i < len(data):
                MB[idx]["wdata"] = data[i]
        if (int(dut.m_ack.value) >> idx) & 1:
            break
    else:
        raise TimeoutError(f"master {idx} write never acked")
    MB[idx]["req"] = 0
    await RisingEdge(dut.clk)


def fexpect(mem, addr, length):
    return [mem[(addr + k) % len(mem)] for k in range(length)]


# ------------------------------------------------------------------- basics

@cocotb.test()
async def single_master_flash(dut):
    flash, ram = await setup(dut)
    dut.cfg.value = 0b01
    got, _ = await m_read(dut, IF, dev=0, addr=0x0200, length=20)
    assert got == fexpect(flash.mem, 0x0200, 20), got


@cocotb.test()
async def single_master_psram_rw(dut):
    flash, ram = await setup(dut)
    dut.cfg.value = 0b10
    # (A) isolate the PSRAM read path: preload memory, read it back
    for i in range(RAM_SIZE):
        ram.mem[i] = (i * 13 + 7) & 0xFF
    rd, _ = await m_read(dut, DATA, dev=1, addr=0x0500, length=24)
    assert rd == fexpect(ram.mem, 0x0500, 24), ("READ", rd)
    # (B) isolate the write path, then read back
    payload = [(i * 5 + 2) & 0xFF for i in range(24)]
    await m_write(dut, DATA, dev=1, addr=0x0800, data=payload)
    assert list(ram.mem[0x0800:0x0800 + 24]) == payload, \
        ("WROTE", [hex(b) for b in ram.mem[0x0800:0x0800 + 24]])
    got, _ = await m_read(dut, DATA, dev=1, addr=0x0800, length=24)
    assert got == payload, ("READBACK", got)


# ---------------------------------------------------------------- priority

@cocotb.test()
async def video_beats_cpu(dut):
    """Video (0) and CPU-data (3) request together; video's data completes first."""
    flash, ram = await setup(dut)
    dut.cfg.value = 0b01
    order = []

    async def cpu():
        got, _ = await m_read(dut, DATA, dev=0, addr=0x1000, length=64)
        order.append("cpu")
        return got

    async def vid():
        got, _ = await m_read(dut, VID, dev=0, addr=0x0000, length=8)
        order.append("vid")
        return got

    ct = cocotb.start_soon(cpu())
    vt = cocotb.start_soon(vid())
    vg = await vt.join()
    cg = await ct.join()
    assert order[0] == "vid", f"video must finish first, order={order}"
    assert vg == fexpect(flash.mem, 0x0000, 8), vg
    assert cg == fexpect(flash.mem, 0x1000, 64), cg


# ------------------------------------------------------- device-rule splits

@cocotb.test()
async def tcem_chop(dut):
    """A 96 B quad PSRAM read exceeds the 88 B tCEM cap -> split; data still
    correct, no single controller transaction exceeds the byte cap, AND the
    measured CS# low time stays under the 8 us (200-clock) tCEM ceiling."""
    flash, ram = await setup(dut)
    dut.cfg.value = 0b10
    payload = [(i * 9 + 5) & 0xFF for i in range(96)]
    await m_write(dut, DATA, dev=1, addr=0x2000, data=payload)   # 0x2000: page-aligned
    got, _ = await m_read(dut, IF, dev=1, addr=0x2000, length=96)
    assert got == payload, got
    assert issued["psram"], "no PSRAM transactions recorded"
    assert max(issued["psram"]) <= 88, f"tCEM byte cap violated: {max(issued['psram'])}"
    assert len(issued["psram"]) >= 4, "a 96 B write + 96 B read should be >=2 pieces each"
    cocotb.log.info(f"tCEM: worst CS# low = {ce_low['max_q']} clocks "
                    f"({ce_low['max_q'] * 40 / 1000:.2f} us)")
    assert 0 < ce_low["max_q"] < CE_LOW_LIMIT, \
        f"CS# low {ce_low['max_q']} clocks >= {CE_LOW_LIMIT} (tCEM 8 us) violated"


@cocotb.test()
async def page_wrap_split(dut):
    """A PSRAM burst crossing a 1 KB page boundary must be split; with a
    wrap-modelling PSRAM an unsplit burst would re-read the page top."""
    flash, ram = await setup(dut, ram_wrap=True)
    dut.cfg.value = 0b10
    base = 0x03F0                         # 16 bytes below the 0x0400 page edge
    payload = [(i * 11 + 3) & 0xFF for i in range(40)]   # crosses 0x0400
    # write with the same arbiter (also split), then read back
    await m_write(dut, DATA, dev=1, addr=base, data=payload)
    got, _ = await m_read(dut, IF, dev=1, addr=base, length=40)
    assert got == payload, got


# ---------------------------------------------------------------- deadline

@cocotb.test()
async def video_deadline_under_load(dut):
    """CPU hammers the bus with back-to-back 90 B reads; a video line fetch must
    still complete well inside a 32 us (800-clock) scanline."""
    flash, ram = await setup(dut)
    dut.cfg.value = 0b11
    stop = {"go": True}

    async def cpu_hammer():
        while stop["go"]:
            await m_read(dut, DATA, dev=1, addr=0x4000, length=90)

    cocotb.start_soon(cpu_hammer())
    for _ in range(200):                  # let the CPU get mid-burst
        await RisingEdge(dut.clk)

    worst = 0
    for _ in range(8):                    # several video "lines"
        _, cyc = await m_read(dut, VID, dev=1, addr=0x6000, length=60)
        worst = max(worst, cyc)
    stop["go"] = False
    assert worst < 800, f"video missed the scanline deadline: {worst} clocks"
    # the CPU's back-to-back 90 B PSRAM reads (split at 88) must never hold CS#
    # low past the tCEM ceiling, even under this sustained load
    assert 0 < ce_low["max_q"] < CE_LOW_LIMIT, \
        f"CS# low {ce_low['max_q']} clocks >= {CE_LOW_LIMIT} (tCEM 8 us) violated"
