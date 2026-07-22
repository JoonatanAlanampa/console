# test_audio.py — the chiptune audio block: DDS frequency, waveforms, volume/mix
# levels, and sigma-delta output density.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

SAMPLE_DIV = 512
OFF = (0, 3, 0)                       # freq, wave(3=off), vol


def set_voices(dut, voices):
    f = w = v = 0
    for i, (fr, wa, vo) in enumerate(voices):
        f |= (fr & 0xFFFF) << (i * 16)
        w |= (wa & 3) << (i * 2)
        v |= (vo & 0xF) << (i * 4)
    dut.v_freq.value = f
    dut.v_wave.value = w
    dut.v_vol.value = v


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 40, "ns").start())
    set_voices(dut, [OFF] * 4)
    dut.rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def settle(dut, n):
    for _ in range(n):
        await RisingEdge(dut.clk)


async def density(dut, n):
    hi = 0
    for _ in range(n):
        await RisingEdge(dut.clk)
        hi += int(dut.audio_out.value)
    return hi / n


@cocotb.test()
async def sigma_delta_density(dut):
    """Sigma-delta average tracks the sample: silence (128) ~ 50%, a fixed
    square level (98) ~ 38%."""
    await setup(dut)
    set_voices(dut, [OFF] * 4)                          # sample = 128
    await settle(dut, 2000)
    assert int(dut.sample.value) == 128
    d = await density(dut, 6 * SAMPLE_DIV)
    assert abs(d - 0.5) < 0.02, f"silence density {d}"

    set_voices(dut, [(0, 0, 15), OFF, OFF, OFF])        # square, freq 0 -> level 98
    await settle(dut, 2000)
    assert int(dut.sample.value) == 98, int(dut.sample.value)
    d = await density(dut, 6 * SAMPLE_DIV)
    assert abs(d - 98 / 256) < 0.02, f"level-98 density {d}"


@cocotb.test()
async def square_wave(dut):
    """A square voice: sample toggles between exactly the two mixed levels, and
    the DDS sets the rate (freq 0x4000 -> half-period 2 ticks = 1024 clocks)."""
    await setup(dut)
    set_voices(dut, [(0x4000, 0, 15), OFF, OFF, OFF])
    await settle(dut, 2000)

    vals, gaps = set(), []
    prev, last = None, 0
    for c in range(9000):
        await RisingEdge(dut.clk)
        s = int(dut.sample.value)
        vals.add(s)
        if prev is not None and s != prev:
            if last:
                gaps.append(c - last)
            last = c
        prev = s

    assert vals == {98, 157}, f"square should be two levels, got {sorted(vals)}"
    steady = [g for g in gaps[1:-1]]                    # drop partial first/last
    assert steady, "no transitions seen"
    assert all(1000 <= g <= 1050 for g in steady), f"period off: {steady}"


async def collect_levels(dut, n):
    vals = set()
    for _ in range(n):
        await RisingEdge(dut.clk)
        vals.add(int(dut.sample.value))
    return vals


@cocotb.test()
async def triangle_and_mix(dut):
    """A triangle sweeps many levels (not two); adding a second voice sums into
    the mix and shifts it, proving the voices are summed."""
    await setup(dut)
    set_voices(dut, [(0x0400, 1, 15), OFF, OFF, OFF])   # slow triangle only
    await settle(dut, 2000)
    vals_a = await collect_levels(dut, 12000)
    assert len(vals_a) > 8, f"triangle should sweep many levels, got {len(vals_a)}"

    # voice1 = square held low (freq 0 -> level 8, below an OFF voice's 128) sums
    # in and lowers the mix floor by (128-8)/4 = 30
    set_voices(dut, [(0x0400, 1, 15), (0, 0, 15), OFF, OFF])
    await settle(dut, 3000)
    vals_b = await collect_levels(dut, 12000)
    assert min(vals_b) < min(vals_a), \
        f"summing a low voice should lower the floor ({min(vals_b)} vs {min(vals_a)})"
