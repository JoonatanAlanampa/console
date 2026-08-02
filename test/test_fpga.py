# test_fpga.py - the ULX3S harness layer, through the actual pins.
#
# The gap this closes: fourteen suites drive the chip or a sub-block, and none
# of them had ever elaborated ulx3s_top. Everything between a working SoC and
# the connectors - the J1/J2 header permutations, the SW1/SW2/SW3 orientation
# straps, the loader/SoC bus mux, the tristates, the LED mux - was logic that
# only hardware would have tested, and on hardware it fails looking exactly
# like dead gateware.
#
# The one idea that makes this bench worth more than a round trip: the memory
# model reaches the flash through the PHYSICAL wires, using a seating the test
# controls, never through the gateware's own mapping. ulx3s_top's permutation
# is self-consistent by construction (bus_in and bus_out share the algebra), so
# a bench that used the design's mapping to talk to the design would pass with
# the permutation completely wrong. See tb_fpga.v's header.
#
# The card model, the flash/PSRAM model and the card-image writer are reused
# verbatim from the existing suites, so what is under test here is the harness
# and only the harness.
#
# (Deliberately ASCII-only: this directory has been corrupted by a stray
# cp1252 round-trip once already.)

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Edge, RisingEdge

from test_rehearse import CartBus, sdwrite
from test_sdspi import SdCard

# uio bit numbering on the cartridge bus, as in ulx3s_top's own comment:
#   0=CS0 1=SD0 2=SD1 3=SCK 4=SD2 5=SD3 6=CS1 7=AUDIO
CS0, SD0, SD1, SCK, CS1 = 0, 1, 2, 3, 6

# Gamepad button indices, matching test_gamepad.py and snes_pad's order.
B, Y, SELECT, START, UP, DOWN, LEFT, RIGHT, A, X, L, R = range(12)

# One gamepad row is {data, clk, latch} in bits {2, 1, 0}, per ulx3s_top's
# pmod_latch/pmod_clk/pmod_data selection. IDLE is a Pmod that is attached but
# not mid-frame: latch and clock low, data high. ALL ONES is nothing plugged in
# at all - PULLMODE=UP with no board on the header.
PAD_IDLE = 0b100
PAD_UNPLUGGED = 0b111


# ---------------------------------------------------------------------------
# physical pin <-> uio, using the SEATING only
# ---------------------------------------------------------------------------

def _row(sig):
    """The four wires of one header row as a list, index 0 = bit 0.

    z and x both read as 1: every J1 line carries PULLMODE=UP in ulx3s.lpf, so
    an undriven wire really is high, and a mid-reset x on a chip select would
    otherwise abort the test before the design has left reset.
    """
    s = str(sig.value)
    return [1 if s[len(s) - 1 - i] in "1hHzZxX" else 0 for i in range(4)]


def uio_from_pins(gp, gn, seat_flip):
    """Rebuild uio[7:0] from the header wires, using the PHYSICAL seating.

    This is the Pmod's view of the connector, not the gateware's. It depends on
    how the board is plugged in and never on what sw[0] claims, which is what
    lets a test set the strap wrong and watch the boot fail.
    """
    lo, hi = (gp, gn) if not seat_flip else (gn, gp)
    v = 0
    for b in range(4):
        v |= lo[3 - b] << b
    for b in range(4, 8):
        v |= hi[7 - b] << b
    return v


class HeaderCartBus(CartBus):
    """The rehearsal's flash+PSRAM part, reached through the J1 header.

    Only the pin plumbing is new; every byte of protocol behaviour - 9Fh, 06h,
    05h busy, 20h sector erase, 02h page program, 03h read, NOR-flash
    clear-bits-only semantics - is inherited from the model the rehearsal
    already trusts.
    """

    def __init__(self, dut, seat_flip):
        super().__init__(dut)
        self.seat_flip = seat_flip
        self.reads = []                      # every 03h (device, address)
        self.ops = []                        # (device, opcode, byte count)
        self._prev_cs = {CS0: 1, CS1: 1}

    def _uio(self):
        return uio_from_pins(_row(self.dut.pmod_gp), _row(self.dut.pmod_gn),
                             self.seat_flip)

    def _on_byte(self, b):
        super()._on_byte(b)
        # After super() the buffer holds 03h plus its three address bytes and
        # raddr has been set.
        if len(self.buf) == 4 and self.buf[0] == 0x03:
            self.reads.append((self.dev, self.raddr))

    def _on_cs_rise(self):
        # Recorded before super() clears the buffer. A transaction log is worth
        # its few lines here: when this bench fails, the useful question is
        # always "what did the part actually see", and the answer is otherwise
        # only recoverable from a waveform.
        if self.buf:
            self.ops.append((self.dev, self.buf[0], len(self.buf)))
        super()._on_cs_rise()

    async def run(self):
        dut = self.dut
        dut.mem_dq1.value = 1
        dut.mem_dq1_oe.value = 0

        # Edge-triggered on the header, exactly as CartBus is on uio. Sampling
        # once per system clock instead looks tidier and is WRONG: after the
        # handover qspi_ctrl drives SCK at clk/2, a once-per-clock sampler
        # aliases against it, and the model sits watching an apparently frozen
        # SCK while the SoC is reading flat out. tb_fpga.v's `hdr` exists so
        # that one wait covers both rows.
        while True:
            await Edge(dut.hdr)
            uio = self._uio()

            for bitno, name in ((CS0, "flash"), (CS1, "psram")):
                cs = (uio >> bitno) & 1
                if cs != self._prev_cs[bitno]:
                    if cs == 0:
                        self._new_txn()
                        self.dev = name
                        self.last_sck = (uio >> SCK) & 1
                    elif self.dev == name:
                        self._on_cs_rise()
                        self.dev = None
                    self._prev_cs[bitno] = cs

            if self.dev is None:
                dut.mem_dq1_oe.value = 0
                continue
            dut.mem_dq1_oe.value = 1

            sck = (uio >> SCK) & 1
            if sck == self.last_sck:
                continue
            self.last_sck = sck
            if sck:
                self.rx = ((self.rx << 1) | ((uio >> SD0) & 1)) & 0xFF
                self.nbits += 1
                if self.nbits == 8:
                    self.nbits = 0
                    self._on_byte(self.rx)
            else:
                if self.nbits == 0:
                    self.cur = self._next_tx()
                dut.mem_dq1.value = (self.cur >> 7) & 1
                self.cur = (self.cur << 1) & 0xFF


class _SdPins:
    """Name adapter: SdCard wants .cs_n / .sck / .mosi / .miso."""

    def __init__(self, dut):
        self.cs_n = dut.sd_cs_n
        self.sck = dut.sd_sck
        self.mosi = dut.sd_mosi
        self.miso = dut.sd_miso


# ---------------------------------------------------------------------------
# bring-up
# ---------------------------------------------------------------------------
# Every test starts its own clock and its own models, and that is deliberate.
# cocotb cancels whatever tasks a test started when that test ends, so a clock
# started once "for the whole file" dies with the first test and every later
# test stops dead at the next edge with "Simulator shut down prematurely" -
# which reads like a simulator bug and is not one. Restarting per test is also
# what the other suites in this directory do.


async def bring_up(dut, payload, seat_flip, cart_strap, vga_strap=0,
                   pad_strap=0, led_strap=0):
    """Power on with a card inserted.

    `seat_flip` is the physical fact - how the Pmod is actually plugged in.
    `cart_strap` is sw[0], the design's separate guess at it. On a correctly
    strapped board they agree; the point of one test here is that they do not.
    """
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())

    dut.seat_flip.value = seat_flip
    dut.sw.value = ((led_strap << 3) | (pad_strap << 2)
                    | (vga_strap << 1) | cart_strap)
    dut.pad_gp.value = PAD_IDLE
    dut.pad_gn.value = PAD_IDLE
    dut.sd_cdn.value = 0                    # a card is in the slot
    dut.btn.value = 0                       # btn[0] low = PWR pressed = reset

    image = sdwrite.build_image(payload)
    card = SdCard(_SdPins(dut), image)
    cart = HeaderCartBus(dut, seat_flip)
    cocotb.start_soon(card.run())
    cocotb.start_soon(cart.run())

    await ClockCycles(dut.clk, 20)
    dut.btn.value = 1                       # release reset

    # ulx3s_top's power-on counter is 16 bits, so rst stays asserted for 65536
    # cycles after the button is released. Only the first test pays for it -
    # the counter saturates and never reloads.
    await ClockCycles(dut.clk, 70_000)
    return cart


async def wait_loader(dut, timeout=4_000_000):
    """Wait for the loader to hand the bus over. True if it did."""
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.top.ldr_done.value == 1:
            await RisingEdge(dut.clk)
            return True
    return False


def small_payload(seed=7, n=1024):
    """A short image. The bytes are arbitrary - what is under test is whether
    they survive the header, not what the CPU makes of them."""
    rnd = random.Random(seed)
    return bytes(rnd.randrange(256) for _ in range(n))


# ---------------------------------------------------------------------------
# the cartridge header, both seatings
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_cartridge_header_mapping_a(dut):
    """Card -> loader -> flash -> SoC -> video, through the J1/J2 wires.

    Proves the outbound permutation (the loader's commands reach the part), the
    inbound one (05h busy polling and 03h data come back), the handover, that
    the SoC's own fetches take the same path, and that uo_out lands on the J2
    wires the Tiny VGA Pmod expects.
    """
    payload = small_payload()
    cart = await bring_up(dut, payload, seat_flip=0, cart_strap=0)

    assert await wait_loader(dut), "the loader never finished"
    assert dut.top.ldr_err.value == 0, (
        "loader error, status=0x%02x" % int(dut.top.ldr_status.value))
    assert bytes(cart.flash[:len(payload)]) == payload, (
        "the flash contents differ from the card image - the header "
        "permutation corrupted the programming path")

    # Handover: the SoC now owns the bus and must fetch its first instruction
    # out of flash address 0, over the same wires.
    cart.reads.clear()
    cart.ops.clear()
    for _ in range(400_000):
        await RisingEdge(dut.clk)
        if any(dev == "flash" and addr < 0x100 for dev, addr in cart.reads):
            break
    else:
        raise AssertionError(
            "no low-address flash read after handover - the SoC never "
            f"fetched. owns_bus={int(dut.top.ldr_owns.value)} "
            f"soc_rst_n={int(dut.top.soc_rst_n.value)} "
            f"transactions seen: {cart.ops[:20]}")

    # ---- J2, now that the console is actually running and driving video ----
    # Checked against an expectation written out here independently of the
    # design's generate block, for both SW2 settings, and only over samples
    # where uo_out is not uniform - otherwise a stuck bus would pass.
    seen_mixed = False
    for _ in range(400):
        for strap in (0, 1):
            dut.sw.value = (int(dut.sw.value) & ~0b10) | (strap << 1)
            await ClockCycles(dut.clk, 3)

            uo = int(dut.top.uo_out.value)
            seen_mixed = seen_mixed or uo not in (0x00, 0xFF)
            gp, gn = _row(dut.vga_gp), _row(dut.vga_gn)
            for n in range(4):
                want_gp = (uo >> ((7 - n) if strap else (3 - n))) & 1
                want_gn = (uo >> ((3 - n) if strap else (7 - n))) & 1
                assert gp[n] == want_gp, (
                    f"SW2={strap}: vga_gp[{n}]={gp[n]} but uo_out={uo:#04x} "
                    f"says {want_gp}")
                assert gn[n] == want_gn, (
                    f"SW2={strap}: vga_gn[{n}]={gn[n]} but uo_out={uo:#04x} "
                    f"says {want_gn}")
        if seen_mixed:
            break
    assert seen_mixed, (
        "uo_out was 0x00 or 0xFF for every sample - the VGA permutation check "
        "never saw a pattern that could distinguish a wrong mapping")


@cocotb.test()
async def test_cartridge_header_mapping_b(dut):
    """The same, with the Pmod seated the other way round and SW1 flipped.

    This is the case the strap exists for, and otherwise the only way to
    discover it is to plug a board in.
    """
    payload = small_payload(seed=11)
    cart = await bring_up(dut, payload, seat_flip=1, cart_strap=1)

    assert await wait_loader(dut), "the loader never finished with SW1 flipped"
    assert dut.top.ldr_err.value == 0, (
        "loader error, status=0x%02x" % int(dut.top.ldr_status.value))
    assert bytes(cart.flash[:len(payload)]) == payload


@cocotb.test()
async def test_wrong_cartridge_strap_does_not_boot(dut):
    """A wrong SW1 must FAIL, and that is the whole value of this file.

    If the permutation were wrong in the same way on the input and the output
    side, every test above would still pass - the design would simply be
    talking to itself consistently. This one cannot pass in that world: the
    model sits on the physical wires, the strap disagrees with the seating, and
    the flash must not end up holding the image.

    It is also the assertion behind the README's "flip SW1 before suspecting
    the board" instruction.
    """
    payload = small_payload(seed=13)
    cart = await bring_up(dut, payload, seat_flip=0, cart_strap=1)

    # A correctly strapped load finishes in about 42k cycles (see the two tests
    # above), so 400k is a ~10x margin on "it is never going to finish" without
    # making this the slowest test in the repo.
    finished = await wait_loader(dut, timeout=400_000)
    programmed = bytes(cart.flash[:len(payload)]) == payload
    assert not (finished and programmed), (
        "the loader programmed the flash correctly with the strap set WRONG - "
        "the header permutation is not actually being exercised")


# ---------------------------------------------------------------------------
# the gamepad header
# ---------------------------------------------------------------------------

async def send_pad_frame(dut, row, pad1, pad2=0, half=30):
    """One 24-bit dual frame onto a chosen PHYSICAL row of the gamepad block.

    Controller 2 first, B first within each controller - matching
    test_gamepad.py, which matches the vendored reference receiver. The other
    row is parked at PAD_IDLE rather than all ones, so that driving one row
    cannot raise a latch edge on the other and commit a frame by accident.
    """
    sig = dut.pad_gp if row == "gp" else dut.pad_gn
    other = dut.pad_gn if row == "gp" else dut.pad_gp
    other.value = PAD_IDLE

    def drive(latch, clock, data):
        sig.value = latch | (clock << 1) | (data << 2)

    drive(0, 0, 1)
    await ClockCycles(dut.clk, half)

    bits = ([(pad2 >> i) & 1 for i in range(12)]
            + [(pad1 >> i) & 1 for i in range(12)])
    for bit in bits:
        drive(0, 0, bit)
        await ClockCycles(dut.clk, half)
        drive(0, 1, bit)                     # rising clock: the receiver samples
        await ClockCycles(dut.clk, half)
        drive(0, 0, bit)

    await ClockCycles(dut.clk, half)
    drive(1, 0, 0)                           # rising latch commits the frame
    await ClockCycles(dut.clk, half)
    drive(0, 0, 1)
    await ClockCycles(dut.clk, half)


@cocotb.test()
async def test_gamepad_row_strap_and_led_aid(dut):
    """SW3 picks the physical gamepad row; SW4 puts the buttons on the LEDs.

    Both are bring-up instructions in fpga/README.md and neither had a test:
    test_gamepad.py drives gamepad_ulx3s directly, so it never sees the row
    selection or the LED mux that a person at the bench actually uses.
    """
    payload = small_payload(seed=19)
    # SW4 on from the start: "press B, watch LED0" is the documented procedure.
    await bring_up(dut, payload, seat_flip=0, cart_strap=0,
                   pad_strap=0, led_strap=1)

    # SW3 = 0 selects the gn row (ulx3s_top: pmod_latch = sw[2] ? gp[0] : gn[0])
    want = (1 << B) | (1 << START) | (1 << LEFT)
    await send_pad_frame(dut, "gn", pad1=want)
    got = int(dut.top.ui_in.value)
    assert got == want & 0xFF, (
        f"SW3=0: ui_in={got:#04x}, expected {want & 0xFF:#04x} - the gamepad "
        "row selection is wrong")
    assert int(dut.led.value) == want & 0xFF, (
        "SW4 is on, so the LEDs must show btn1[7:0] - this is the only "
        "controller diagnostic available with the Pmod as a black box")

    # A frame on the OTHER row must now be ignored.
    await send_pad_frame(dut, "gp", pad1=1 << RIGHT)
    assert int(dut.top.ui_in.value) == want & 0xFF, (
        "SW3=0 but a frame on the gp row changed the buttons - both rows are "
        "being decoded, so the strap is not doing anything")

    # Flip SW3: the gp row must become the live one.
    dut.sw.value = int(dut.sw.value) | 0b100
    await ClockCycles(dut.clk, 10)
    want2 = (1 << Y) | (1 << UP)
    await send_pad_frame(dut, "gp", pad1=want2)
    assert int(dut.top.ui_in.value) == want2 & 0xFF, (
        f"SW3=1: ui_in={int(dut.top.ui_in.value):#04x}, "
        f"expected {want2 & 0xFF:#04x}")


@cocotb.test()
async def test_unplugged_gamepad_reads_as_no_buttons(dut):
    """Nothing plugged into the gamepad block must mean nothing pressed.

    With PULLMODE=UP and no Pmod, all three lines idle high, no frame is ever
    clocked, and the receiver's all-ones rule reports "not present". The README
    tells the user that LEDs lighting with nothing connected is worth stopping
    for; this is that claim, tested.
    """
    payload = small_payload(seed=23)
    await bring_up(dut, payload, seat_flip=0, cart_strap=0, led_strap=1)

    dut.pad_gp.value = PAD_UNPLUGGED
    dut.pad_gn.value = PAD_UNPLUGGED
    await ClockCycles(dut.clk, 2_000)

    assert int(dut.top.ui_in.value) == 0, (
        f"ui_in={int(dut.top.ui_in.value):#04x} with no controller attached - "
        "an unplugged port must not read as buttons held")
    assert int(dut.led.value) == 0, "SW4 shows the buttons: they must be zero"
