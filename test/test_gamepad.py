# test_gamepad.py — the harness front end for the TT Gamepad Pmod.
#
# The model here is the Pmod MASTER: the CH32V003 on the Pmod drives latch,
# clock and data, and the FPGA only samples. That is the whole reason this
# part exists — the raw SNES protocol needs latch and clock as outputs, which
# the chip's input-only `ui` pins can never provide.
#
# Frame facts are taken from the vendored reference receiver
# (vendor/gamepad_pmod.v, the Pmod designer's own code), not guessed:
#   * sample on the RISING edge of pmod_clk;
#   * pmod_latch's RISING edge commits — latch TERMINATES a frame;
#   * in a 24-bit dual frame CONTROLLER 2 GOES FIRST;
#   * within a controller, B is first on the wire;
#   * an all-1s word means "not plugged in" and must decode to NO buttons.
#
# That last one is the case worth the most: an unplugged port that read as
# "every button held" would look like a possessed controller, and it is the
# exact inverse of the raw-pad default where a pull-up made silence safe.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

# Bit positions, matching snes_pad's order so ui_in keeps its meaning.
B, Y, SELECT, START, UP, DOWN, LEFT, RIGHT, A, X, L, R = range(12)
NAMES = ["B", "Y", "select", "start", "up", "down", "left", "right",
         "A", "X", "L", "R"]

ALL_ONES = 0xFFF          # what a disconnected controller reports


def buttons(*bits):
    """Pack button indices into the 12-bit vector (bit 0 = B)."""
    v = 0
    for b in bits:
        v |= 1 << b
    return v


async def ticks(dut, n):
    await ClockCycles(dut.clk, n)


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 40, units="ns").start())   # 25 MHz
    dut.pmod_latch.value = 0
    dut.pmod_clk.value = 0
    dut.pmod_data.value = 1        # idle high: PULLMODE=UP, nothing plugged
    dut.rst.value = 1
    await ticks(dut, 10)
    dut.rst.value = 0
    await ticks(dut, 5)


async def send_frame(dut, pad2, pad1, half=30):
    """Drive one 24-bit dual frame, controller 2 first, B first within each.

    `half` is the Pmod half-clock in system clocks. The real Pmod runs at
    100 kHz against our 25 MHz, i.e. half=125; the default is faster to keep
    the suite quick, and test_real_pmod_clock_rate covers the true ratio.

    Data is asserted BEFORE the clock rises and held past the fall, which is
    what the Pmod does and what the receiver's rising-edge sampling needs.
    """
    bits = ([(pad2 >> i) & 1 for i in range(12)]
            + [(pad1 >> i) & 1 for i in range(12)])
    for bit in bits:
        dut.pmod_data.value = bit
        await ticks(dut, half)
        dut.pmod_clk.value = 1
        await ticks(dut, half)
        dut.pmod_clk.value = 0

    await ticks(dut, half)
    dut.pmod_latch.value = 1       # rising edge commits the frame
    await ticks(dut, half)
    dut.pmod_latch.value = 0
    await ticks(dut, half)


@cocotb.test()
async def test_two_controllers_are_not_swapped(dut):
    """Distinct patterns must land on the right controller.

    This is the test that pins down which controller transmits first -- the
    reference puts controller 1 in data_reg[11:0], i.e. the LAST twelve bits
    on the wire, so controller 2 leads. Getting this backwards would be
    invisible with one controller and maddening with two.
    """
    await setup(dut)
    p1 = buttons(B, START, LEFT)
    p2 = buttons(A, UP, R)
    await send_frame(dut, pad2=p2, pad1=p1)

    assert int(dut.btn1.value) == p1, (
        f"btn1={int(dut.btn1.value):#05x} expected {p1:#05x} "
        "- controller order is reversed")
    assert int(dut.btn2.value) == p2, (
        f"btn2={int(dut.btn2.value):#05x} expected {p2:#05x}")
    assert dut.present1.value == 1 and dut.present2.value == 1


@cocotb.test()
async def test_bit_order_one_hot(dut):
    """One button at a time, all twelve: pins the wire order exactly."""
    await setup(dut)
    for i in range(12):
        await send_frame(dut, pad2=0, pad1=1 << i)
        got = int(dut.btn1.value)
        assert got == 1 << i, (
            f"{NAMES[i]} (bit {i}) decoded as {got:#05x}, expected "
            f"{1 << i:#05x} - the wire bit order is wrong")


@cocotb.test()
async def test_disconnected_controller_reads_as_no_buttons(dut):
    """All 1s means unplugged, and MUST decode to zero buttons.

    The dangerous failure is the opposite: an empty port reporting every
    button held at once.
    """
    await setup(dut)
    await send_frame(dut, pad2=ALL_ONES, pad1=ALL_ONES)

    assert int(dut.btn1.value) == 0, "an unplugged controller reported buttons"
    assert int(dut.btn2.value) == 0, "an unplugged controller reported buttons"
    assert dut.present1.value == 0
    assert dut.present2.value == 0


@cocotb.test()
async def test_one_plugged_one_not(dut):
    """A real controller must still work with the other port empty."""
    await setup(dut)
    p1 = buttons(Y, DOWN, X)
    await send_frame(dut, pad2=ALL_ONES, pad1=p1)

    assert int(dut.btn1.value) == p1
    assert dut.present1.value == 1
    assert int(dut.btn2.value) == 0
    assert dut.present2.value == 0


@cocotb.test()
async def test_outputs_hold_while_idle(dut):
    """Silence is normal - the last frame must persist, not decay.

    The Pmod need not retransmit continuously, so a receiver that timed out
    to zero would make held buttons flicker or drop.
    """
    await setup(dut)
    p1 = buttons(RIGHT, A)
    await send_frame(dut, pad2=0, pad1=p1)
    assert int(dut.btn1.value) == p1

    await ticks(dut, 50_000)          # 2 ms of complete silence
    assert int(dut.btn1.value) == p1, (
        "the buttons decayed while the Pmod was idle")
    assert dut.present1.value == 1


@cocotb.test()
async def test_reset_clears_to_no_buttons(dut):
    """Before any frame arrives, report nothing pressed and nothing present."""
    await setup(dut)
    assert int(dut.btn1.value) == 0
    assert int(dut.btn2.value) == 0
    assert dut.present1.value == 0
    assert dut.present2.value == 0

    await send_frame(dut, pad2=0, pad1=buttons(START))
    assert int(dut.btn1.value) == buttons(START)

    dut.rst.value = 1
    await ticks(dut, 10)
    dut.rst.value = 0
    await ticks(dut, 5)
    assert int(dut.btn1.value) == 0, "reset did not clear the buttons"
    assert dut.present1.value == 0


@cocotb.test()
async def test_back_to_back_frames(dut):
    """Consecutive frames with no idle gap must each commit."""
    await setup(dut)
    first = buttons(LEFT)
    second = buttons(RIGHT, B)

    await send_frame(dut, pad2=0, pad1=first)
    assert int(dut.btn1.value) == first
    await send_frame(dut, pad2=0, pad1=second)
    assert int(dut.btn1.value) == second, (
        "the second frame did not replace the first")


@cocotb.test()
async def test_real_pmod_clock_rate(dut):
    """The true 100 kHz against our 25 MHz - 250 system clocks per bit."""
    await setup(dut)
    p1 = buttons(SELECT, UP, L)
    p2 = buttons(B, RIGHT)
    await send_frame(dut, pad2=p2, pad1=p1, half=125)

    assert int(dut.btn1.value) == p1, "CDC failed at the real Pmod clock rate"
    assert int(dut.btn2.value) == p2
