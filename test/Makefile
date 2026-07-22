# Makefile — one suite per invocation, selected by BLOCK.
#
#   make BLOCK=snes     SNES pad controller
#   make BLOCK=vga      VGA race-the-beam timing core
#   make BLOCK=twin     CORDIC-1 RTL vs own-cell gate netlist
#   make BLOCK=qspi     quad-mode QSPI memory controller
#   make all            all of them
#
# `python run.py` does the same thing without make, which is how it is
# usually run on the Windows host.

SIM ?= icarus
TOPLEVEL_LANG ?= verilog
FST ?= -fst

SRC_DIR    = $(PWD)/../src
VENDOR_DIR = $(PWD)/../vendor

BLOCK ?= snes

COMPILE_ARGS += -g2012 -I$(SRC_DIR)

ifeq ($(BLOCK),snes)
  SIM_BUILD = sim_build/snes
  TOPLEVEL  = tb_snes
  COCOTB_TEST_MODULES = test_snes_pad
  VERILOG_SOURCES += $(SRC_DIR)/snes_pad.sv $(PWD)/tb_snes.v
endif

ifeq ($(BLOCK),vga)
  SIM_BUILD = sim_build/vga
  TOPLEVEL  = tb_vga
  COCOTB_TEST_MODULES = test_vga_timing
  VERILOG_SOURCES += $(SRC_DIR)/vga_timing.sv $(SRC_DIR)/vga_testpat.sv $(PWD)/tb_vga.v
endif

ifeq ($(BLOCK),qspi)
  SIM_BUILD = sim_build/qspi
  TOPLEVEL  = tb_qspi
  COCOTB_TEST_MODULES = test_qspi
  VERILOG_SOURCES += $(SRC_DIR)/qspi_ctrl.sv $(PWD)/tb_qspi.v
endif

ifeq ($(BLOCK),arb)
  SIM_BUILD = sim_build/arb
  TOPLEVEL  = tb_arb
  COCOTB_TEST_MODULES = test_arb
  VERILOG_SOURCES += $(SRC_DIR)/qspi_arbiter.sv $(SRC_DIR)/qspi_ctrl.sv $(PWD)/tb_arb.v
endif

ifeq ($(BLOCK),vfetch)
  SIM_BUILD = sim_build/vfetch
  TOPLEVEL  = tb_vfetch
  COCOTB_TEST_MODULES = test_vfetch
  VERILOG_SOURCES += $(SRC_DIR)/vga_fetch.sv $(SRC_DIR)/qspi_arbiter.sv $(SRC_DIR)/qspi_ctrl.sv $(PWD)/tb_vfetch.v
endif

ifeq ($(BLOCK),vengine)
  SIM_BUILD = sim_build/vengine
  TOPLEVEL  = tb_vengine
  COCOTB_TEST_MODULES = test_vengine
  VERILOG_SOURCES += $(SRC_DIR)/vga_engine.sv $(SRC_DIR)/vga_fetch.sv $(SRC_DIR)/vga_timing.sv $(SRC_DIR)/qspi_arbiter.sv $(SRC_DIR)/qspi_ctrl.sv $(PWD)/tb_vengine.v
endif

ifeq ($(BLOCK),twin)
  SIM_BUILD = sim_build/twin
  TOPLEVEL  = tb_cordic_twin
  COCOTB_TEST_MODULES = test_cordic_twin
  # the netlist's module is renamed into the build dir so it can sit
  # beside the RTL it is being compared against
  GATES_V := $(SIM_BUILD)/cordic_gates_twin.v
  $(shell python mkgates.py $(GATES_V))
  VERILOG_SOURCES += $(VENDOR_DIR)/own_cells_beh.v $(GATES_V)
  VERILOG_SOURCES += $(VENDOR_DIR)/tt-cordic-rtl/cordic.sv $(VENDOR_DIR)/tt-cordic-rtl/project.sv
  VERILOG_SOURCES += $(PWD)/tb_cordic_twin.v
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

# `blocks`, not `all`: cocotb's Makefile.sim already defines `all`, and a
# target of that name here both shadows it and — because it would be the
# first target in the file — becomes the default goal, so each recursive
# call re-enters it. That recursion does not terminate (found by a CI job
# that ran for seven minutes doing nothing).
.PHONY: blocks
blocks:
	$(MAKE) BLOCK=snes
	$(MAKE) BLOCK=vga
	$(MAKE) BLOCK=twin
	$(MAKE) BLOCK=qspi
	$(MAKE) BLOCK=arb
	$(MAKE) BLOCK=vfetch
	$(MAKE) BLOCK=vengine
