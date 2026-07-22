# Windows-friendly test driver (no `make` required):
#   python run.py            # every suite
#   python run.py snes       # SNES pad controller
#   python run.py vga        # VGA race-the-beam timing core
#   python run.py twin       # CORDIC-1 RTL vs own-cells gate netlist
#
# Each suite has its own toplevel, so they are separate builds — unlike
# a single-chip repo where one testbench serves everything. Mirrors the
# Makefile exactly; CI runs the Makefile.

import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

import mkgates

TEST_DIR = Path(__file__).parent
SRC = TEST_DIR.parent / "src"
VENDOR = TEST_DIR.parent / "vendor"
BUILD = TEST_DIR / "sim_build"


def twin_sources():
    """Vendored netlist + RTL, with the netlist's module renamed on the fly."""
    renamed = mkgates.render(
        VENDOR / "cordic_gates.v", BUILD / "twin" / "cordic_gates_twin.v"
    )
    return [
        VENDOR / "own_cells_beh.v",
        renamed,
        VENDOR / "tt-cordic-rtl" / "cordic.sv",
        VENDOR / "tt-cordic-rtl" / "project.sv",
        TEST_DIR / "tb_cordic_twin.v",
    ]


SUITES = {
    "snes": dict(
        top="tb_snes",
        module="test_snes_pad",
        sources=lambda: [SRC / "snes_pad.sv", TEST_DIR / "tb_snes.v"],
    ),
    "vga": dict(
        top="tb_vga",
        module="test_vga_timing",
        sources=lambda: [
            SRC / "vga_timing.sv",
            SRC / "vga_testpat.sv",
            TEST_DIR / "tb_vga.v",
        ],
    ),
    "twin": dict(
        top="tb_cordic_twin",
        module="test_cordic_twin",
        sources=twin_sources,
    ),
    "qspi": dict(
        top="tb_qspi",
        module="test_qspi",
        sources=lambda: [SRC / "qspi_ctrl.sv", TEST_DIR / "tb_qspi.v"],
    ),
    "arb": dict(
        top="tb_arb",
        module="test_arb",
        sources=lambda: [
            SRC / "qspi_arbiter.sv",
            SRC / "qspi_ctrl.sv",
            TEST_DIR / "tb_arb.v",
        ],
    ),
    "vfetch": dict(
        top="tb_vfetch",
        module="test_vfetch",
        sources=lambda: [
            SRC / "vga_fetch.sv",
            SRC / "qspi_arbiter.sv",
            SRC / "qspi_ctrl.sv",
            TEST_DIR / "tb_vfetch.v",
        ],
    ),
    "vengine": dict(
        top="tb_vengine",
        module="test_vengine",
        sources=lambda: [
            SRC / "vga_engine.sv",
            SRC / "vga_fetch.sv",
            SRC / "vga_timing.sv",
            SRC / "qspi_arbiter.sv",
            SRC / "qspi_ctrl.sv",
            TEST_DIR / "tb_vengine.v",
        ],
    ),
    "audio": dict(
        top="tb_audio",
        module="test_audio",
        sources=lambda: [SRC / "audio.sv", TEST_DIR / "tb_audio.v"],
    ),
    "soc": dict(
        top="tb_soc",
        module="test_soc",
        sources=lambda: [
            SRC / "console_soc.sv", SRC / "sysregs.sv", SRC / "vga_engine.sv",
            SRC / "vga_fetch.sv", SRC / "vga_timing.sv", SRC / "audio.sv",
            SRC / "qspi_arbiter.sv", SRC / "qspi_ctrl.sv",
            TEST_DIR / "tb_soc.v",
        ],
    ),
    "cpuadapt": dict(
        top="tb_cpuadapt",
        module="test_cpuadapt",
        sources=lambda: [
            SRC / "cpu_adapter.sv", SRC / "sysregs.sv",
            SRC / "qspi_arbiter.sv", SRC / "qspi_ctrl.sv",
            TEST_DIR / "tb_cpuadapt.v",
        ],
    ),
    "boot": dict(
        top="tb_boot",
        module="test_boot",
        sources=lambda: [
            SRC / "tt_um_joonatanalanampa_console.sv", SRC / "cpu_adapter.sv",
            SRC / "console_soc.sv", SRC / "sysregs.sv", SRC / "vga_engine.sv",
            SRC / "vga_fetch.sv", SRC / "vga_timing.sv", SRC / "audio.sv",
            SRC / "qspi_arbiter.sv", SRC / "qspi_ctrl.sv",
            VENDOR / "rv32_core.sv", VENDOR / "control.sv", VENDOR / "immgen.sv",
            VENDOR / "regfile.sv", VENDOR / "alu.sv", VENDOR / "branch.sv",
            VENDOR / "uart_tx.sv", TEST_DIR / "tb_boot.v",
        ],
    ),
}


def run(name):
    suite = SUITES[name]
    runner = get_runner("icarus")
    runner.build(
        sources=suite["sources"](),
        hdl_toplevel=suite["top"],
        build_dir=BUILD / name,
        build_args=["-g2012", f"-I{SRC}"],
        timescale=("1ns", "1ps"),
        # Always recompile: the runner's staleness check missed an edited
        # module once and silently re-ran the previous simulation, which
        # is the worst possible failure mode for a test driver. Icarus
        # builds here take about a second.
        always=True,
    )
    runner.test(
        hdl_toplevel=suite["top"],
        test_module=suite["module"],
        test_dir=TEST_DIR,
        results_xml=f"results_{name}.xml",
    )


def main():
    for name in sys.argv[1:] or list(SUITES):
        print(f"=== {name} ===", flush=True)
        run(name)


if __name__ == "__main__":
    main()
