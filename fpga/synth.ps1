# synth.ps1 — build the console prototype bitstream for the ULX3S 85F.
#   powershell -File fpga\synth.ps1              # full flow -> console.bit
#   powershell -File fpga\synth.ps1 -SynthOnly   # yosys only (fast RTL check)
#
# Output: fpga\build\console.bit
#
# Load it one of two ways — the difference matters:
#   openFPGALoader -b ulx3s    fpga\build\console.bit   # SRAM: GONE at power-off
#   openFPGALoader -b ulx3s -f fpga\build\console.bit   # SPI flash: survives
# Use -f for a console you can just switch on; omit it while iterating.
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

# The source list lives in fpga/sources.txt so that this script and the CI
# workflow build the SAME design — see the header of that file.
$src = (Get-Content fpga\sources.txt |
        Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne "" } |
        ForEach-Object { $_.Trim() }) -join " "
if (-not $src) { throw "fpga\sources.txt listed no sources" }

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
