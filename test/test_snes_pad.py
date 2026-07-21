# SPDX-FileCopyrightText: © 2026 Joonatan Alanampa
# SPDX-License-Identifier: Apache-2.0
#
# snes_pad against a behavioural model of a real SNES controller.
#
# The pad model is written from the connector's point of view — it only
# ever reacts to LATCH and CLK — so these tests check the DUT against
# the protocol, not against itself. Anything the DUT gets wrong about
# edge sense, bit order or bit count shows up as decoded buttons that do
# not match the ones the model was told to hold.

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, First, RisingEdge, Timer

CLK_NS = 1000  # 1 MHz, matching tb_snes.v's CLK_HZ
POLL_CYCLES = 1000  # CLK_HZ / POLL_HZ

# bit index -> name, in the order the pad shifts them out
ORDER = ["B", "Y", "Select", "Start", "Up", "Down", "Left", "Right",
         "A", "X", "L", "R"]
BIT = {name: i for i, name in enumerate(ORDER)}


def encode(*names):
    """Button names -> the 12-bit active-high word snes_pad should report."""
    v = 0
    for n in names:
        v |= 1 << BIT[n]
    return v


class PadModel:
    """One SNES controller: a 16-bit parallel-in / serial-out shifter.

    Loads on LATCH high, presents bit 0, and advances on every rising
    edge of CLK. Data is active low at the connector; bits 12..15 of a
    real pad read as released. `buttons` may be changed at any time —
    only the value at latch time is captured, exactly like the hardware.
    """

    def __init__(self, dut, index):
        self.dut = dut
        self.line = getattr(dut, f"pad_data{index}")  # own driver, no bus race
        self.buttons = 0
        self.word = 0xFFFF
        self.pos = 0

    def _drive(self):
        self.line.value = 1 if self.pos > 15 else (self.word >> self.pos) & 1

    async def run(self):
        """Purely edge-driven, with no state that can fall out of step.

        An earlier version had an outer "wait for latch" loop around an
        inner "shift on clock" loop; it silently missed every second read
        because the inner loop consumed the latch edge the outer one was
        waiting for. One loop over both edges cannot desynchronize.
        """
        self._drive()
        while True:
            latch = RisingEdge(self.dut.pad_latch)
            clk = RisingEdge(self.dut.pad_clk)
            fired = await First(latch, clk)
            if fired is latch:
                # capture: active low at the connector, unused bits released
                self.word = (~self.buttons & 0xFFF) | 0xF000
                self.pos = 0
            else:
                self.pos += 1
            self._drive()


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.pad_data0.value = 1  # lines idle high = nothing pressed
    dut.pad_data1.value = 1
    dut.rst.value = 1
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    pads = [PadModel(dut, i) for i in range(2)]
    for p in pads:
        cocotb.start_soon(p.run())
    return pads


async def next_sample(dut, timeout_cycles=4 * POLL_CYCLES):
    """Wait for the strobe that says a fresh sample landed in btn."""
    await First(RisingEdge(dut.strobe), ClockCycles(dut.clk, timeout_cycles))
    assert dut.strobe.value == 1, "no strobe within the poll timeout"
    await Timer(1, unit="ns")  # let btn settle alongside the strobe


@cocotb.test()
async def test_idle_reads_nothing(dut):
    """An untouched (or unplugged) pad decodes to all-released."""
    await start(dut)
    for _ in range(2):
        await next_sample(dut)
        assert int(dut.btn0.value) == 0
        assert int(dut.btn1.value) == 0


@cocotb.test()
async def test_single_buttons(dut):
    """Every button, one at a time, on pad 0 — checks bit order end to end."""
    pads = await start(dut)
    for name in ORDER:
        pads[0].buttons = encode(name)
        await next_sample(dut)  # first poll may have latched mid-change
        await next_sample(dut)
        got = int(dut.btn0.value)
        assert got == encode(name), (
            f"{name}: expected {encode(name):#05x}, got {got:#05x}"
        )


@cocotb.test()
async def test_pads_are_independent(dut):
    """Random combinations, both pads at once, on the shared clock."""
    pads = await start(dut)
    rnd = random.Random(20260721)
    for _ in range(8):
        want = [rnd.randrange(1 << 12) for _ in range(2)]
        pads[0].buttons, pads[1].buttons = want
        await next_sample(dut)
        await next_sample(dut)
        got = [int(dut.btn0.value), int(dut.btn1.value)]
        assert got == want, f"expected {[f'{w:#05x}' for w in want]}, got {[f'{g:#05x}' for g in got]}"


@cocotb.test()
async def test_poll_cadence(dut):
    """Samples arrive once per poll period — the frame tick the game loop uses."""
    await start(dut)
    await next_sample(dut)
    marks = []
    for _ in range(3):
        t0 = cocotb.utils.get_sim_time(unit="ns")
        await next_sample(dut)
        marks.append(cocotb.utils.get_sim_time(unit="ns") - t0)
    for gap in marks:
        cycles = gap / CLK_NS
        assert abs(cycles - POLL_CYCLES) <= 2, (
            f"poll gap {cycles} cycles, expected ~{POLL_CYCLES}"
        )


@cocotb.test()
async def test_unplugged_port_is_quiet(dut):
    """Pad 1 unplugged (line floats high) while pad 0 is used normally."""
    pads = await start(dut)
    pads[0].buttons = encode("A", "Start", "Left")
    pads[1].buttons = 0  # model keeps driving 1 = released
    await next_sample(dut)
    await next_sample(dut)
    assert int(dut.btn0.value) == encode("A", "Start", "Left")
    assert int(dut.btn1.value) == 0
