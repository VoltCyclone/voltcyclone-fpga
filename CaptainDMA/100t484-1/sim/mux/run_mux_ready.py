#!/usr/bin/env python3
"""Run tb_mux_ready (pcileech_mux output integrity, toggling rd_en) with iverilog.

Current mux: every mode/seed must pass. Control: the frozen stock mux must
fail with a toggling consumer (modes 0, 1) and pass with ready held (mode 2),
showing the bench is not stricter than the contract.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
BOARD = HERE.parents[1]


def sim(mux: Path, mode: int, seed: int, cycles: int, tmp: Path) -> bool:
    vvp = tmp / f"m{mode}s{seed}.vvp"
    subprocess.run(["iverilog", "-g2012", "-o", str(vvp),
                    "-P", f"tb_mux_ready.RD_MODE={mode}", "-P", f"tb_mux_ready.SEED={seed}",
                    "-P", f"tb_mux_ready.CYCLES={cycles}",
                    str(HERE / "tb_mux_ready.sv"), str(mux)], check=True)
    out = subprocess.run(["vvp", "-n", str(vvp)], capture_output=True, text=True).stdout
    line = next((l for l in out.splitlines() if l.startswith("MUX_READY_")), "MUX_READY_NONE")
    print(f"  {mux.name} mode={mode} seed={seed}: {line}")
    return line.startswith("MUX_READY_PASS")


def main() -> int:
    ok = True
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        for mode in (0, 1, 2):
            for seed in (1, 2, 3):
                ok &= sim(BOARD / "src/pcileech_mux.sv", mode, seed, 100000, tmp)
        stock = HERE / "pcileech_mux_stock.sv"
        ok &= not sim(stock, 0, 1, 50000, tmp)
        ok &= not sim(stock, 1, 1, 50000, tmp)
        ok &= sim(stock, 2, 1, 50000, tmp)
    print("MUX_READY_RUN_PASS" if ok else "MUX_READY_RUN_FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
