# test_boot.py — full-system boot: the tt_um console top (vendored TinyRV32 core
# + adapter + SoC) runs a tiny program out of the flash model and stores to PSRAM.
# Proves the whole chain: core boots at PC 0, fetches instruction pairs from flash
# through the adapter + arbiter + controller, executes, and its store lands in
# PSRAM -- on the packed cartridge-Pmod uio bus, in the reset default 1-bit mode.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Edge, First, RisingEdge, Timer

from test_qspi import SpiMem

SD = [1, 2, 4, 5]                 # SD0..SD3 positions in the uio bus


async def qspi_bus_uio(dut, flash, ram):
    """Same full-rate bit-level glue as test_qspi.qspi_bus, but on the packed uio
    bus: SD0=uio1 SD1=uio2 SD2=uio4 SD3=uio5 SCK=uio3 CS0=uio0 CS1=uio6."""
    prev = 0
    while True:
        await First(Edge(dut.sck_tap), Edge(dut.csf_tap), Edge(dut.csr_tap))
        await Timer(1, "ps")
        oe, out = dut.uio_oe.value, dut.uio_out.value
        if not (oe.is_resolvable and out.is_resolvable):
            dut.uio_in.value = 0xFF
            prev = 0
            continue
        oe, out = int(oe), int(out)
        sck, csf, csr = (out >> 3) & 1, (out >> 0) & 1, (out >> 6) & 1
        sel = flash if csf == 0 else ram if csr == 0 else None
        for d in (flash, ram):
            if d is not sel:
                d.deselect()
        if sel is None:
            dut.uio_in.value = 0xFF
            prev = 0
            continue
        io = 0
        for i, b in enumerate(SD):
            io |= (((out >> b) & 1) if (oe >> b) & 1 else 1) << i
        if sck and not prev:
            sel.on_rise(io)
        elif prev and not sck:
            sel.on_fall()
            uin = 0xFF
            for i, b in enumerate(SD):
                bit = (sel.out_val >> i) & 1 if (sel.out_mask >> i) & 1 else 1
                uin = (uin & ~(1 << b)) | (bit << b)
            dut.uio_in.value = uin
        prev = sck


# hand-assembled RV32 (RV32E-safe: x1, x2 only)
#   lui  x1, 0x01000     x1 = 0x0100_0000  (PSRAM base)
#   addi x2, x0, 42
#   sw   x2, 0(x1)       PSRAM[0..3] = 42, 0, 0, 0
#   jal  x0, 0           spin
PROGRAM = [0x010000B7, 0x02A00113, 0x0020A023, 0x0000006F]


@cocotb.test()
async def boots_and_stores(dut):
    cocotb.start_soon(Clock(dut.clk, 40, "ns").start())
    flash = SpiMem(1 << 16, writable=False)
    ram = SpiMem(1 << 16, writable=True)
    for i, w in enumerate(PROGRAM):
        for k in range(4):
            flash.mem[i * 4 + k] = (w >> (8 * k)) & 0xFF
    cocotb.start_soon(qspi_bus_uio(dut, flash, ram))

    dut.ui_in.value = 0
    dut.ena.value = 1
    dut.uio_in.value = 0xFF
    dut.rst_n.value = 0
    for _ in range(10):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    for _ in range(60000):
        await RisingEdge(dut.clk)
        if ram.mem[0] == 42:
            break
    else:
        raise TimeoutError(f"CPU never stored to PSRAM (ram[0]={ram.mem[0]})")

    assert list(ram.mem[0:4]) == [42, 0, 0, 0], list(ram.mem[0:4])
    cocotb.log.info("BOOT: CPU booted from flash and stored 42 to PSRAM")
