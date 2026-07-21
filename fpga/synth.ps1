# synth.ps1 — build the CORDIC-1 gate-level twin bitstream for the ULX3S 85F.
#   powershell -File fpga\synth.ps1
# Output: fpga\build\cordic_twin.bit
# Flash:  openFPGALoader -b ulx3s fpga\build\cordic_twin.bit
#
# The design source is the VENDORED GATE NETLIST plus behavioural models
# of the self-designed cells — no RTL is compiled into this bitstream.
# yosys will of course re-optimize the gate graph for LUTs; that is fine
# and unavoidable. What is being validated here is the netlist's LOGIC
# (does the mapped design compute a sine?), not its structure — the
# structure is validated by DRC/LVS in the stdcells repo and by the
# cycle-exact equivalence test in test/.
$ErrorActionPreference = "Stop"
$oss = "$env:USERPROFILE\opt\oss-cad-suite"
$env:PATH = "$oss\bin;$oss\lib;" + $env:PATH
Set-Location (Split-Path $PSScriptRoot -Parent)
New-Item -ItemType Directory -Force fpga\build | Out-Null

yosys -q -p "read_verilog vendor/own_cells_beh.v vendor/cordic_gates.v; read_verilog -sv fpga/ulx3s_top.sv; synth_ecp5 -top ulx3s_top -json fpga/build/cordic_twin.json"
if ($LASTEXITCODE -ne 0) { throw "yosys failed" }

nextpnr-ecp5 --85k --package CABGA381 --json fpga/build/cordic_twin.json `
    --lpf fpga/ulx3s.lpf --textcfg fpga/build/cordic_twin.config
if ($LASTEXITCODE -ne 0) { throw "nextpnr failed" }

ecppack fpga/build/cordic_twin.config fpga/build/cordic_twin.bit
if ($LASTEXITCODE -ne 0) { throw "ecppack failed" }

Write-Output "OK: fpga\build\cordic_twin.bit"
