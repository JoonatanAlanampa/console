# SPDX-FileCopyrightText: © 2026 Joonatan Alanampa
# SPDX-License-Identifier: Apache-2.0
#
# The gate netlist and the RTL define the SAME module name, which is the
# whole point of an equivalence test and also makes them impossible to
# compile together. Rather than editing the vendored netlist — it must
# stay byte-identical to what the stdcells flow emitted, so that the
# provenance line in vendor/README.md keeps meaning something — this
# script writes a renamed copy into the build directory.
#
# It renames the module and nothing else: a single identifier, checked
# for the expected number of occurrences (declaration only), so a
# netlist regenerated with a different structure fails loudly here
# instead of silently testing the wrong thing.

import sys
from pathlib import Path

TOP = "tt_um_joonatanalanampa_cordic"
TWIN = "tt_um_joonatanalanampa_cordic_gates"


def render(src: Path, dst: Path) -> Path:
    text = src.read_text()
    n = text.count(f"module {TOP}(") + text.count(f"module {TOP} (")
    if n != 1:
        raise SystemExit(
            f"{src}: expected exactly one `module {TOP}` declaration, found {n}"
        )
    out = text.replace(f"module {TOP}(", f"module {TWIN}(")
    out = out.replace(f"module {TOP} (", f"module {TWIN} (")
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(out)
    return dst


if __name__ == "__main__":
    here = Path(__file__).parent
    render(
        here.parent / "vendor" / "cordic_gates.v",
        Path(sys.argv[1]) if len(sys.argv) > 1
        else here / "sim_build" / "twin" / "cordic_gates_twin.v",
    )
