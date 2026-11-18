#!/usr/bin/env python3
"""Prove the pcileech_mux output queue never exceeds four words (SymbiYosys).

All ports and rd_en are unconstrained after an initial reset. PDR (abc pdr)
needs no induction depth. Negative control: a 3-entry bound must fail
(the bound is reached). The queue has eight entries.
Requires sby/yosys/abc on PATH (oss-cad-suite).
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BOARD = Path(__file__).resolve().parents[2]
SBY = """[options]
mode prove

[engines]
abc pdr

[script]
read -formal -DFORMAL -DPCILEECH_MUX_OQ_BOUND={bound} pcileech_mux.sv
prep -top pcileech_mux

[files]
{src}
"""


def run(bound: str) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "pcileech_mux.sv"
        src.write_text((BOARD / "src/pcileech_mux.sv").read_text())
        (Path(tmp) / "p.sby").write_text(SBY.format(src=src, bound=bound))
        r = subprocess.run(["sby", "-f", "p.sby"], cwd=tmp, capture_output=True, text=True, timeout=1800)
        out = r.stdout + r.stderr
        for status in ("PASS", "FAIL", "ERROR"):
            if f"DONE ({status}" in out:
                return status
        return "UNKNOWN\n" + out[-2000:]


def main() -> int:
    if not shutil.which("sby"):
        print("sby not found", file=sys.stderr)
        return 2
    real = run("4")
    ctrl = run("3")
    print(f"MUX_OQ_BOUND4 {real}")
    print(f"MUX_OQ_BOUND3_CONTROL {ctrl} (expected FAIL)")
    return 0 if real == "PASS" and ctrl == "FAIL" else 1


if __name__ == "__main__":
    sys.exit(main())
