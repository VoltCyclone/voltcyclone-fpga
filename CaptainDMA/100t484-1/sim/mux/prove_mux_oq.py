#!/usr/bin/env python3
"""Prove the pcileech_mux output queue never exceeds three words (SymbiYosys).

All ports and rd_en are unconstrained after an initial reset. PDR (abc pdr)
needs no induction depth. Negative control: a 2-entry bound must fail.
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
read -formal -DFORMAL pcileech_mux.sv
prep -top pcileech_mux

[files]
{src}
"""


def run(bound: str) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "pcileech_mux.sv"
        text = (BOARD / "src/pcileech_mux.sv").read_text()
        if bound != "3'd3":
            text = text.replace("assert( oq_cnt <= 3'd3 );", f"assert( oq_cnt <= {bound} );")
        src.write_text(text)
        (Path(tmp) / "p.sby").write_text(SBY.format(src=src))
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
    real = run("3'd3")
    ctrl = run("3'd2")
    print(f"MUX_OQ_BOUND3 {real}")
    print(f"MUX_OQ_BOUND2_CONTROL {ctrl} (expected FAIL)")
    return 0 if real == "PASS" and ctrl == "FAIL" else 1


if __name__ == "__main__":
    sys.exit(main())
