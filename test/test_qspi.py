# test_qspi.py — the quad-mode QSPI controller against bit-level flash and
# PSRAM slave models, exercising the 1-bit fallback and every quad path.
#
# The `SpiMem` slave model and the falling-edge bus glue are ported from the
# proven tt-riscv suite (tt-riscv/test/test.py, which boots the CPU through
# this exact modelling and passes all 40 rv32ui riscv-tests in both SPI
# modes). Only the pin plumbing changes: the console controller exposes named
# sd_out/sd_oe/sd_in/sck/cs_* pads instead of a packed uio bus, so the glue
# reads those directly. The model also records the command bytes it decodes,
# so tests can assert WHICH command ran (03h/6Bh/EBh/38h) — that is the direct
# proof of the cfg-driven quad-vs-1-bit-fallback selection.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

FLASH_SIZE = 1 << 16
RAM_SIZE = 1 << 16


class SpiMem:
    """Behavioral SPI/QSPI slave, mode 0.

    Serial: 03h read, 02h write (24-bit address).
    Quad:   6Bh fast-read-quad-output (serial cmd+addr, 8 dummies, quad data)
            EBh quad read (serial cmd, quad addr, 6 waits, quad data)
            38h quad write (serial cmd, quad addr, quad data)
    """

    def __init__(self, size, writable):
        self.mem = bytearray(size)
        self.writable = writable
        self.cmds = []          # every command byte decoded, in order
        self.deselect()

    def deselect(self):
        self.phase = "cmd"
        self.sh = 0
        self.n = 0
        self.cmd = None
        self.addr = 0
        self.dummy_left = 0
        self.nib_idx = 0
        self.cur = 0
        self.out_mask = 0       # which SD bits we drive
        self.out_val = 0

    def _begin_read(self, quad):
        self.phase = "rd_q" if quad else "rd_s"
        self.nib_idx = 2        # forces a fresh byte load on first on_fall
        self.bit_idx = 8

    def on_rise(self, io):
        bit = io & 1            # serial traffic is on SD0
        if self.phase == "cmd":
            self.sh = ((self.sh << 1) | bit) & 0xFF
            self.n += 1
            if self.n == 8:
                self.cmd = self.sh
                self.cmds.append(self.cmd)
                self.sh = 0
                self.n = 0
                if self.cmd in (0x03, 0x02, 0x6B):
                    self.phase = "addr_s"
                elif self.cmd in (0xEB, 0x38):
                    self.phase = "addr_q"
                else:
                    self.phase = "ignore"
        elif self.phase == "addr_s":
            self.sh = ((self.sh << 1) | bit) & 0xFFFFFF
            self.n += 1
            if self.n == 24:
                self.addr = self.sh
                self.sh = 0
                self.n = 0
                if self.cmd == 0x03:
                    self._begin_read(False)
                elif self.cmd == 0x02:
                    self.phase = "wr_s"
                else:                       # 6Bh: 8 dummy clocks first
                    self.phase = "dummy"
                    self.dummy_left = 8
        elif self.phase == "addr_q":
            self.sh = ((self.sh << 4) | io) & 0xFFFFFF
            self.n += 1
            if self.n == 6:
                self.addr = self.sh
                self.sh = 0
                self.n = 0
                if self.cmd == 0xEB:
                    self.phase = "dummy"
                    self.dummy_left = 6
                else:                       # 38h quad write
                    self.phase = "wr_q"
        elif self.phase == "dummy":
            self.dummy_left -= 1
            if self.dummy_left == 0:
                self._begin_read(True)
        elif self.phase == "wr_s":
            self.sh = ((self.sh << 1) | bit) & 0xFF
            self.n += 1
            if self.n == 8:
                if self.writable:
                    self.mem[self.addr % len(self.mem)] = self.sh
                self.addr += 1
                self.sh = 0
                self.n = 0
        elif self.phase == "wr_q":
            self.sh = ((self.sh << 4) | io) & 0xFF
            self.n += 1
            if self.n == 2:
                if self.writable:
                    self.mem[self.addr % len(self.mem)] = self.sh
                self.addr += 1
                self.sh = 0
                self.n = 0

    def on_fall(self):
        if self.phase == "rd_s":
            if self.bit_idx == 8:
                self.cur = self.mem[self.addr % len(self.mem)]
                self.addr += 1
                self.bit_idx = 0
            self.out_mask = 0b0010          # SD1 (MISO)
            self.out_val = (((self.cur >> (7 - self.bit_idx)) & 1) << 1)
            self.bit_idx += 1
        elif self.phase == "rd_q":
            if self.nib_idx == 2:
                self.cur = self.mem[self.addr % len(self.mem)]
                self.addr += 1
                self.nib_idx = 0
            nib = (self.cur >> 4) & 0xF if self.nib_idx == 0 else self.cur & 0xF
            self.out_mask = 0b1111
            self.out_val = nib
            self.nib_idx += 1
        else:
            self.out_mask = 0
            self.out_val = 0


async def qspi_bus(dut, flash, ram):
    """Pin-level glue, sampled on the falling clk edge so the DUT's rising-edge
    NBA values have settled. SCK toggles at clk/2 → every SCK edge seen once."""
    prev_sck = 0
    while True:
        await FallingEdge(dut.clk)
        oe = dut.sd_oe.value
        ov = dut.sd_out.value
        sk = dut.sck.value
        csf = dut.cs_flash_n.value
        csr = dut.cs_ram_n.value
        if not (oe.is_resolvable and ov.is_resolvable and sk.is_resolvable
                and csf.is_resolvable and csr.is_resolvable):
            prev_sck = 0
            dut.sd_in.value = 0xF
            continue
        oem, out, sck = int(oe), int(ov), int(sk)
        # master nibble: driven pins as driven, released pins pulled up
        io = 0
        for i in range(4):
            io |= (((out >> i) & 1) if (oem >> i) & 1 else 1) << i
        sel = flash if not int(csf) else ram if not int(csr) else None
        for d in (flash, ram):
            if d is not sel:
                d.deselect()
        uin = 0xF                           # idle bus: pull-ups
        if sel is not None:
            if sck and not prev_sck:
                sel.on_rise(io)
            elif prev_sck and not sck:
                sel.on_fall()
            uin = 0
            for i in range(4):
                bit = (sel.out_val >> i) & 1 if (sel.out_mask >> i) & 1 else 1
                uin |= bit << i
        dut.sd_in.value = uin
        prev_sck = sck


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    flash = SpiMem(FLASH_SIZE, writable=False)
    ram = SpiMem(RAM_SIZE, writable=True)
    # distinct patterns so a device/ordering mix-up is visible
    for i in range(FLASH_SIZE):
        flash.mem[i] = (i * 7 + 0x11) & 0xFF
    cocotb.start_soon(qspi_bus(dut, flash, ram))

    dut.req.value = 0
    dut.we.value = 0
    dut.dev.value = 0
    dut.addr.value = 0
    dut.len.value = 1
    dut.wdata.value = 0
    dut.cfg.value = 0
    dut.rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    return flash, ram


async def do_read(dut, dev, addr, length, cap=8000):
    dut.we.value = 0
    dut.dev.value = dev
    dut.addr.value = addr
    dut.len.value = length
    dut.req.value = 1
    got = []
    for _ in range(cap):
        await RisingEdge(dut.clk)
        if int(dut.rvalid.value):
            got.append(int(dut.rdata.value))
        if int(dut.ack.value):
            break
    else:
        raise TimeoutError(f"read never acked (dev={dev} addr={addr:#x} len={length})")
    dut.req.value = 0
    await RisingEdge(dut.clk)
    assert len(got) == length, f"got {len(got)} bytes, expected {length}"
    return got


async def do_write(dut, dev, addr, data, cap=8000):
    dut.we.value = 1
    dut.dev.value = dev
    dut.addr.value = addr
    dut.len.value = len(data)
    idx = 0
    dut.wdata.value = data[0]
    dut.req.value = 1
    pulses = 0
    for _ in range(cap):
        await RisingEdge(dut.clk)
        if int(dut.wnext.value):
            pulses += 1
            idx += 1
            if idx < len(data):
                dut.wdata.value = data[idx]
        if int(dut.ack.value):
            break
    else:
        raise TimeoutError(f"write never acked (dev={dev} addr={addr:#x})")
    dut.req.value = 0
    await RisingEdge(dut.clk)
    return pulses


def expect(mem, addr, length):
    return [mem[(addr + k) % len(mem)] for k in range(length)]


# ------------------------------------------------------------------- reads

@cocotb.test()
async def flash_read_serial_fallback(dut):
    """cfg=0 is the boot/fallback mode: flash reads via 03h, 1-bit."""
    flash, ram = await setup(dut)
    dut.cfg.value = 0
    got = await do_read(dut, dev=0, addr=0x1234, length=8)
    assert got == expect(flash.mem, 0x1234, 8), got
    assert flash.cmds[-1] == 0x03, f"expected 03h, got {flash.cmds[-1]:#x}"


@cocotb.test()
async def flash_read_quad(dut):
    """cfg[0]=1: flash reads via 6Bh Fast Read Quad Output."""
    flash, ram = await setup(dut)
    dut.cfg.value = 0b01
    got = await do_read(dut, dev=0, addr=0x0800, length=16)
    assert got == expect(flash.mem, 0x0800, 16), got
    assert flash.cmds[-1] == 0x6B, f"expected 6Bh, got {flash.cmds[-1]:#x}"


# ------------------------------------------------------- PSRAM round-trips

@cocotb.test()
async def psram_roundtrip_serial(dut):
    """cfg=0: PSRAM write 02h / read 03h, 1-bit."""
    flash, ram = await setup(dut)
    dut.cfg.value = 0
    payload = [0xA5, 0x00, 0xFF, 0x3C, 0x81]
    await do_write(dut, dev=1, addr=0x2000, data=payload)
    assert ram.cmds[-1] == 0x02, f"expected 02h, got {ram.cmds[-1]:#x}"
    got = await do_read(dut, dev=1, addr=0x2000, length=len(payload))
    assert got == payload, got
    assert ram.cmds[-1] == 0x03, f"expected 03h, got {ram.cmds[-1]:#x}"


@cocotb.test()
async def psram_roundtrip_quad(dut):
    """cfg[1]=1: PSRAM write 38h / read EBh, quad address and data."""
    flash, ram = await setup(dut)
    dut.cfg.value = 0b10
    payload = [i & 0xFF for i in range(16)]
    pulses = await do_write(dut, dev=1, addr=0x3AB0, data=payload)
    assert pulses == 16, f"one wnext per byte expected, got {pulses}"
    assert ram.cmds[-1] == 0x38, f"expected 38h, got {ram.cmds[-1]:#x}"
    got = await do_read(dut, dev=1, addr=0x3AB0, length=16)
    assert got == payload, got
    assert ram.cmds[-1] == 0xEB, f"expected EBh, got {ram.cmds[-1]:#x}"


# --------------------------------------------- per-device cfg independence

@cocotb.test()
async def cfg_is_per_device(dut):
    """cfg[0]=1 makes flash quad while PSRAM (cfg[1]=0) stays serial."""
    flash, ram = await setup(dut)
    dut.cfg.value = 0b01
    fr = await do_read(dut, dev=0, addr=0x0040, length=4)
    assert fr == expect(flash.mem, 0x0040, 4), fr
    assert flash.cmds[-1] == 0x6B
    await do_write(dut, dev=1, addr=0x0100, data=[0x11, 0x22])
    rr = await do_read(dut, dev=1, addr=0x0100, length=2)
    assert rr == [0x11, 0x22], rr
    assert ram.cmds[-1] == 0x03, f"PSRAM should be serial, got {ram.cmds[-1]:#x}"


# ---------------------------------------------------------- edge behaviour

@cocotb.test()
async def flash_write_is_noop(dut):
    """A write to the read-only flash acks fast, no wnext, no change."""
    flash, ram = await setup(dut)
    before = bytes(flash.mem[0x0500:0x0510])
    dut.we.value = 1
    dut.dev.value = 0
    dut.addr.value = 0x0500
    dut.len.value = 4
    dut.wdata.value = 0xDD
    dut.req.value = 1
    pulses = 0
    acked = False
    for n in range(20):
        await RisingEdge(dut.clk)
        if int(dut.wnext.value):
            pulses += 1
        if int(dut.ack.value):
            acked = True
            break
    dut.req.value = 0
    await RisingEdge(dut.clk)
    assert acked and n < 5, f"flash write should ack immediately (n={n})"
    assert pulses == 0, "no data should be pulled for a flash no-op"
    assert bytes(flash.mem[0x0500:0x0510]) == before, "flash must be unchanged"


@cocotb.test()
async def len_extremes(dut):
    """len=1 and len=16 both work, serial and quad."""
    flash, ram = await setup(dut)
    for cfg in (0, 0b01):
        dut.cfg.value = cfg
        one = await do_read(dut, dev=0, addr=0x0AAA, length=1)
        assert one == expect(flash.mem, 0x0AAA, 1), (cfg, one)
        full = await do_read(dut, dev=0, addr=0x0AAA, length=16)
        assert full == expect(flash.mem, 0x0AAA, 16), (cfg, full)


@cocotb.test()
async def back_to_back(dut):
    """Two transactions in a row: the controller returns to idle between them."""
    flash, ram = await setup(dut)
    dut.cfg.value = 0
    a = await do_read(dut, dev=0, addr=0x0000, length=6)
    assert a == expect(flash.mem, 0x0000, 6), a
    await do_write(dut, dev=1, addr=0x00, data=[0xDE, 0xAD, 0xBE, 0xEF])
    b = await do_read(dut, dev=1, addr=0x00, length=4)
    assert b == [0xDE, 0xAD, 0xBE, 0xEF], b
    c = await do_read(dut, dev=0, addr=0x00F0, length=8)
    assert c == expect(flash.mem, 0x00F0, 8), c


@cocotb.test()
async def ascending_order(dut):
    """Streamed bytes are in ascending address order (quad PSRAM)."""
    flash, ram = await setup(dut)
    dut.cfg.value = 0b10
    payload = [(0x40 + k) & 0xFF for k in range(12)]
    await do_write(dut, dev=1, addr=0x0210, data=payload)
    got = await do_read(dut, dev=1, addr=0x0210, length=12)
    assert got == payload, got
