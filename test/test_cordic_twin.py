# SPDX-FileCopyrightText: © 2026 Joonatan Alanampa
# SPDX-License-Identifier: Apache-2.0
#
# Gate-level twin: CORDIC-1 RTL vs the same design mapped onto the
# self-designed standard-cell library.
#
# The stdcells flow can prove the library is DRC/LVS clean and that the
# hardening routes. It cannot prove that a chip built from those cells
# computes what the RTL says — nothing in that flow ever simulates the
# design. This does: same clock, same stimulus, both twins, compared on
# every cycle. The netlist uses six cell types (INV/BUF/NAND2/NOR2/DFF/
# TIE) and its flops have no reset pin, so the comparison starts one
# reset pulse after time zero and is exact from there on.
#
# NOTE the models: vendor/own_cells_beh.v is functional only, with no
# timing. This test proves logical equivalence — that the mapping is
# right. It does NOT prove the library is fast enough; that is OpenSTA's
# job in the stdcells hardening, and silicon's job in the vertical slice.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CLK_NS = 40  # 25 MHz, the ship clock

# 359 clocks per bit-serial conversion; a few of them per frequency code
# is enough to walk the engine through every state, and the sigma-delta
# and heartbeat counters diverge visibly within a handful of cycles if
# any flop is mapped wrong.
CONVERSION = 359


async def start(dut, code):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.ena.value = 1
    dut.uio_in.value = 0
    dut.ui_in.value = code
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1


async def compare(dut, cycles, note=""):
    """Step `cycles` clocks, failing on the first cycle that differs."""
    for i in range(cycles):
        await ClockCycles(dut.clk, 1)
        rtl = dut.uo_out_rtl.value
        gl = dut.uo_out_gl.value
        assert rtl.is_resolvable, f"RTL went X at cycle {i} {note}"
        assert gl.is_resolvable, f"gates went X at cycle {i} {note}"
        assert int(rtl) == int(gl), (
            f"cycle {i} {note}: RTL uo_out={int(rtl):#04x} "
            f"gates uo_out={int(gl):#04x}"
        )


@cocotb.test()
async def test_wakeup_default(dut):
    """Code 0 = the 440 Hz wake-up tone: ten conversions, cycle-exact."""
    await start(dut, 0)
    await compare(dut, 10 * CONVERSION, "(code 0)")


@cocotb.test()
async def test_frequency_codes(dut):
    """A spread of codes, including both special cases (0 and 127)."""
    await start(dut, 0)
    for code in (1, 2, 64, 100, 126, 127):
        dut.ui_in.value = code
        await compare(dut, 3 * CONVERSION, f"(code {code})")


@cocotb.test()
async def test_ui7_is_ignored(dut):
    """ui[7] is documented as reserved — both twins must ignore it alike."""
    await start(dut, 0)
    await compare(dut, CONVERSION, "(ui[7]=0)")
    dut.ui_in.value = 0x80
    await compare(dut, 2 * CONVERSION, "(ui[7]=1)")


@cocotb.test()
async def test_uio_is_driven_low_and_tristated(dut):
    """The netlist's TIE cells must reproduce the RTL's constant uio."""
    await start(dut, 0)
    await ClockCycles(dut.clk, 10)
    assert int(dut.uio_oe_gl.value) == 0 == int(dut.uio_oe_rtl.value)
    assert int(dut.uio_out_gl.value) == 0 == int(dut.uio_out_rtl.value)


@cocotb.test()
async def test_reset_is_synchronous_and_repeatable(dut):
    """A second reset re-converges the gate twin — no hidden state."""
    await start(dut, 64)
    await compare(dut, 2 * CONVERSION, "(before re-reset)")
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await compare(dut, 2 * CONVERSION, "(after re-reset)")
