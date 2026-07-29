# synth.ps1 — build the console prototype bitstream for the ULX3S 85F.
#   powershell -File fpga\synth.ps1              # full flow -> console.bit
#   powershell -File fpga\synth.ps1 -SynthOnly   # yosys only (fast RTL check)
#
# Output: fpga\build\console.bit
# Flash:  openFPGALoader -b ulx3s fpga\build\console.bit
#
# The bitstream contains the UNCHANGED tt_um top plus the harness-only blocks
# (SD loader, SNES decoder, header muxes) that the silicon has no pins for.
# See ulx3s_top.sv for what is harness-only and why.
#
# nextpnr on an 85F is the slow step by a wide margin; -SynthOnly stops after
# yosys, which is enough to catch an elaboration error or a surprise in the
# cell count without paying for a place-and-route.
param([switch]$SynthOnly)

$ErrorActionPreference = "Stop"
$oss = "$env:USERPROFILE\opt\oss-cad-suite"
if (-not (Test-Path $oss)) { throw "oss-cad-suite not found at $oss" }
$env:PATH = "$oss\bin;$oss\lib;" + $env:PATH

Set-Location (Split-Path $PSScriptRoot -Parent)
New-Item -ItemType Directory -Force fpga\build | Out-Null

# Source order: the TT top first, then the rest of the design, then the
# harness. `../vendor` carries the read-only RV32 core, exactly as info.yaml
# lists it for the ASIC flow.
$src = @(
    "src/tt_um_joonatanalanampa_console.sv",
    "src/cpu_adapter.sv", "src/console_soc.sv", "src/sysregs.sv",
    "src/vga_engine.sv", "src/vga_fetch.sv", "src/vga_timing.sv",
    "src/audio.sv", "src/qspi_arbiter.sv", "src/qspi_ctrl.sv",
    "src/snes_pad.sv",
    "vendor/rv32_core.sv", "vendor/control.sv", "vendor/immgen.sv",
    "vendor/regfile.sv", "vendor/alu.sv", "vendor/branch.sv",
    "vendor/uart_tx.sv",
    "fpga/spi_master.sv", "fpga/sd_spi.sv", "fpga/spi_flash.sv",
    "fpga/sd_loader.sv", "fpga/ulx3s_top.sv"
) -join " "

yosys -q -p "read_verilog -sv -I src $src; synth_ecp5 -top ulx3s_top -json fpga/build/console.json"
if ($LASTEXITCODE -ne 0) { throw "yosys failed" }
Write-Output "OK: fpga\build\console.json"

if ($SynthOnly) { exit 0 }

nextpnr-ecp5 --85k --package CABGA381 --json fpga/build/console.json `
    --lpf fpga/ulx3s.lpf --textcfg fpga/build/console.config
if ($LASTEXITCODE -ne 0) { throw "nextpnr failed" }

ecppack fpga/build/console.config fpga/build/console.bit
if ($LASTEXITCODE -ne 0) { throw "ecppack failed" }

Write-Output "OK: fpga\build\console.bit"
