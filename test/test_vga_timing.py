# SPDX-FileCopyrightText: © 2026 Joonatan Alanampa
# SPDX-License-Identifier: Apache-2.0
#
# 640x480@60 timing core.
#
# A monitor is an unforgiving test bench: if the sync pulses are one
# pixel off, or the polarity is inverted, or there are 524 lines instead
# of 525, it either refuses to lock or shows the picture in the wrong
# place. These tests measure the raster the way a monitor does — timing
# the edges.
#
# COST NOTE: one frame is 420,000 pixel clocks, and the simulator costs
# roughly a second per 700,000 ns of simulated time regardless of how
# few events are waited on — the bottleneck is advancing time, not
# handling edges (measured: an edge-driven rewrite of a per-cycle poll
# ran SLOWER, because it covered more frames). So everything that needs
# a whole frame is collected in ONE frame walk, and every other test
# stays inside a single 800-clock line.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import (ClockCycles, FallingEdge, RisingEdge, Timer)
from cocotb.utils import get_sim_time

CLK_NS = 40  # 25 MHz pixel clock

H_VIS, H_FRONT, H_SYNC, H_BACK = 640, 16, 96, 48
V_VIS, V_FRONT, V_SYNC, V_BACK = 480, 10, 2, 33
H_TOTAL = H_VIS + H_FRONT + H_SYNC + H_BACK  # 800
V_TOTAL = V_VIS + V_FRONT + V_SYNC + V_BACK  # 525
PRE = 8


def now():
    """Current sim time in pixel clocks."""
    return get_sim_time(unit="ns") / CLK_NS


async def start(dut):
    """Reset, and return with the beam at the top of a frame.

    No wait for frame_start is needed — and none is affordable: reset
    holds both counters at zero, so releasing it IS the top of the
    frame. Waiting for the next frame_start edge instead would burn a
    full 16.8 ms frame (about 23 s of wall clock) before every test.
    """
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.rst.value = 1
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 1)
    assert int(dut.x.value) == 0 and int(dut.y.value) == 0, (
        "reset did not leave the beam at the top of the frame"
    )


@cocotb.test()
async def test_one_whole_frame(dut):
    """Everything that is only visible over a full frame, measured once.

    Line count, frame period, visible-line count, vsync placement and
    width, and the per-line fetch requests — all from a single pass, so
    the expensive part of this suite happens exactly once.
    """
    await start(dut)
    t0 = now()
    de_at_origin = int(dut.de.value)

    hsyncs, visible_lines, fetches, vsync_edges = [], [], [], []

    async def watch(signal, sink, rising, stamp):
        trig = RisingEdge if rising else FallingEdge
        while True:
            await trig(signal)
            sink.append(stamp())

    tasks = [
        cocotb.start_soon(watch(dut.hsync, hsyncs, False, now)),
        cocotb.start_soon(watch(dut.de, visible_lines, True,
                                lambda: int(dut.y.value))),
        cocotb.start_soon(watch(dut.line_fetch, fetches, True,
                                lambda: (int(dut.y.value), int(dut.next_y.value)))),
        cocotb.start_soon(watch(dut.vsync, vsync_edges, False,
                                lambda: ("fall", now(), int(dut.y.value)))),
        cocotb.start_soon(watch(dut.vsync, vsync_edges, True,
                                lambda: ("rise", now(), int(dut.y.value)))),
    ]

    await RisingEdge(dut.frame_start)
    walk = now() - t0
    for t in tasks:
        t.cancel()

    # --- raster geometry
    #
    # The frame period is derived from the line timestamps rather than
    # from `walk`, which is ambiguous by one clock: reset holds the
    # counters at zero, so "the frame began" is either the last reset
    # edge or the first counting edge depending on how you look at it.
    # Lines are unambiguous — and V_TOTAL lines of H_TOTAL each IS the
    # frame period, with the uniformity checked rather than assumed.
    assert len(hsyncs) == V_TOTAL, (
        f"{len(hsyncs)} hsync pulses per frame, expected {V_TOTAL}"
    )
    gaps = {b - a for a, b in zip(hsyncs, hsyncs[1:])}
    assert gaps == {H_TOTAL}, f"line periods seen: {sorted(gaps)}"
    assert abs(walk - H_TOTAL * V_TOTAL) <= 1, (
        f"frame_start repeated after {walk} pixel clocks, "
        f"expected {H_TOTAL * V_TOTAL}"
    )
    # Line 0 has no observable de RISE in this walk: the walk starts at
    # the top of the frame, where de is already open. So the rises seen
    # are lines 1..479, and line 0 is accounted for by the assertion
    # that de is open at the origin.
    assert de_at_origin == 1, "de was not already open at the top of the frame"
    assert visible_lines == list(range(1, V_VIS)), (
        f"{len(visible_lines) + 1} visible lines, expected {V_VIS} "
        f"(first seen: {visible_lines[:3]}, last: {visible_lines[-3:]})"
    )

    # --- vsync: negative-going, V_SYNC lines wide, after the front porch
    kinds = [e[0] for e in vsync_edges]
    assert kinds == ["fall", "rise"], f"vsync edges in a frame: {kinds}"
    (_, t_fall, line), (_, t_rise, _) = vsync_edges
    assert line == V_VIS + V_FRONT, (
        f"vsync fell on line {line}, expected {V_VIS + V_FRONT}"
    )
    assert t_rise - t_fall == V_SYNC * H_TOTAL, (
        f"vsync was {(t_rise - t_fall) / H_TOTAL} lines wide, expected {V_SYNC}"
    )

    # --- fetch hooks: one request per visible line, always ahead of the beam
    assert len(fetches) == V_VIS, (
        f"{len(fetches)} fetch pulses per frame, expected {V_VIS}"
    )
    assert sorted(n for _, n in fetches) == list(range(V_VIS)), (
        "the set of requested lines is not exactly the visible lines"
    )
    for cur, nxt in fetches:
        # line n is fetched during the blank of line n-1; line 0 during
        # the last line of the previous frame
        assert nxt == 0 or nxt == cur + 1, f"line {cur} asked for {nxt}"


@cocotb.test()
async def test_visible_window(dut):
    """de opens at x=0 and stays open for exactly 640 pixels."""
    await start(dut)
    await RisingEdge(dut.de)
    assert int(dut.x.value) == 0, f"de rose at x={int(dut.x.value)}"
    t0 = now()
    await FallingEdge(dut.de)
    assert now() - t0 == H_VIS, f"de was open for {now() - t0} pixels"


@cocotb.test()
async def test_hsync_pulse(dut):
    """hsync is negative-going, 96 pixels wide, at the right place."""
    await start(dut)
    await FallingEdge(dut.hsync)
    assert int(dut.x.value) == H_VIS + H_FRONT, (
        f"hsync fell at x={int(dut.x.value)}, expected {H_VIS + H_FRONT}"
    )
    t0 = now()
    await RisingEdge(dut.hsync)
    assert now() - t0 == H_SYNC, f"hsync was {now() - t0} pixels wide"


@cocotb.test()
async def test_fetch_window_length(dut):
    """The fetch budget is the whole horizontal blanking interval."""
    await start(dut)
    await RisingEdge(dut.line_fetch)
    t0 = now()
    await RisingEdge(dut.de)
    assert now() - t0 == H_FRONT + H_SYNC + H_BACK, (
        f"fetch window was {now() - t0} cycles, "
        f"expected {H_FRONT + H_SYNC + H_BACK}"
    )


@cocotb.test()
async def test_pre_line_warning(dut):
    """pre_line gives the engine PRE cycles of notice before de rises."""
    await start(dut)
    await RisingEdge(dut.line_fetch)  # a visible line is coming
    await RisingEdge(dut.pre_line)
    t0 = now()
    await RisingEdge(dut.de)
    assert now() - t0 == PRE, (
        f"pre_line led de by {now() - t0} cycles, expected {PRE}"
    )


@cocotb.test()
async def test_pixels_are_black_in_blanking(dut):
    """The placeholder pixel source respects de — required by every DAC."""
    await start(dut)
    for _ in range(2 * H_TOTAL):  # two lines, pixel by pixel
        await ClockCycles(dut.clk, 1)
        if dut.de.value == 0:
            assert int(dut.r.value) == 0
            assert int(dut.g.value) == 0
            assert int(dut.b.value) == 0
