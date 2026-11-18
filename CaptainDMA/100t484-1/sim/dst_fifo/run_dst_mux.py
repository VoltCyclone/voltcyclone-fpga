#!/usr/bin/env python3
"""Run tb_dst_mux (SYS-side prefetch vs frozen reference) under Vivado xsim.

Stages the board sources into a new output directory, optionally applies a
mutant to the staged pcileech_pcie_tlp_a7.sv, then compiles, elaborates and
runs one simulation per (seed, clock) point. Requires the generated
fifo_134_134_clk2 simulation model from a configured project.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent

# name: (search, replace, expected failure marker)
MUTANTS = {
    "no_pull_gate": (
        "wire         pop      = dfifo.rx_rd_en && acc_sys && (pb_count != 2'd0);",
        "wire         pop      = acc_sys && (pb_count != 2'd0);",
        "DST_PULL_CONTRACT",
    ),
    "deep_prefetch": (
        "({1'b0, pb_count} + {2'b0, rd_q} <= 3'd2)",
        "({1'b0, pb_count} + {2'b0, rd_q} <= 3'd3)",
        "DST_",
    ),
    "no_flush": (
        "            pb_head  <= 2'd0;\n            pb_count <= 2'd0;\n            rd_q     <= 1'b0;",
        "            rd_q     <= 1'b0;",
        "DST_STALE",
    ),
    "no_rst_out_gate": (
        "    assign dfifo.rx_valid[0] = o_valid[0] && !rst;",
        "    assign dfifo.rx_valid[0] = o_valid[0];",
        "DST_STALE",
    ),
    # Whole-file control: the frozen stock pcileech_mux (sim/mux).
    "stock_mux": (None, None, "DST_MUX_"),
    "no_inflight_count": (
        "({1'b0, pb_count} + {2'b0, rd_q} <= 3'd2)",
        "({1'b0, pb_count} <= 3'd2)",
        "DST_",
    ),
}

SOURCES = ("pcileech_header.svh", "pcileech_pcie_tlp_a7.sv", "pcileech_mux.sv")
# (PCIE_HALF, SYS_HALF): 62.5/100 MHz as built, sys slower than pcie, near-equal
CLOCKS = ((8.0, 5.0), (8.0, 9.0), (8.0, 7.7))


def run(argv, work: Path, name: str) -> str:
    with (work / f"{name}.log").open("w") as log:
        rc = subprocess.run([str(a) for a in argv], cwd=work, stdout=log,
                            stderr=subprocess.STDOUT, timeout=900).returncode
    out = (work / f"{name}.log").read_text(errors="replace")
    return f"rc={rc}\n" + out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--vivado", type=Path, required=True)
    ap.add_argument("--board", type=Path, required=True)
    ap.add_argument("--generated-ip", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--mutant", choices=tuple(MUTANTS))
    ap.add_argument("--seeds", type=int, default=3)
    a = ap.parse_args()
    a.board = a.board.resolve()
    if a.out.exists():
        raise SystemExit(f"refusing to overwrite {a.out}")
    work = a.out.resolve()
    src = work / "src"
    src.mkdir(parents=True)
    for n in SOURCES:
        shutil.copy2(a.board / "src" / n, src / n)
    for n in ("dst_fifo_reference.sv", "tb_dst_mux.sv"):
        shutil.copy2(HERE / n, src / n)
    model = a.generated_ip / "fifo_134_134_clk2" / "sim" / "fifo_134_134_clk2.v"
    shutil.copy2(model, src / model.name)
    if a.mutant == "stock_mux":
        stock = (HERE.parent / "mux" / "pcileech_mux_stock.sv").read_text()
        (src / "pcileech_mux.sv").write_text(stock)
    elif a.mutant:
        old, new, _ = MUTANTS[a.mutant]
        p = src / "pcileech_pcie_tlp_a7.sv"
        t = p.read_text()
        if t.count(old) != 1:
            raise SystemExit(f"mutant {a.mutant} does not apply")
        p.write_text(t.replace(old, new))
    (work / "source-sha256.json").write_text(json.dumps(
        {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(src.iterdir())},
        indent=2) + "\n")
    b = a.vivado / "bin"
    out = run([b / "xvlog", "--sv", "-i", src, a.vivado / "data/verilog/src/glbl.v",
               src / "fifo_134_134_clk2.v", src / "pcileech_mux.sv",
               src / "pcileech_pcie_tlp_a7.sv", src / "dst_fifo_reference.sv",
               src / "tb_dst_mux.sv"], work, "compile")
    if not out.startswith("rc=0") or re.search(r"(?m)^ERROR:", out):
        raise SystemExit(f"compile failed\n{out[-4000:]}")
    points = [(s, c) for s in range(1, a.seeds + 1) for c in CLOCKS]
    killed = False
    for i, (seed, (ph, sh)) in enumerate(points):
        name = f"seed{seed}-clk{CLOCKS.index((ph, sh))}"
        out = run([b / "xelab", "-L", "fifo_generator_v13_2_15", "-L", "xpm", "-L", "unisims_ver",
                   "-generic_top", f"SEED={seed}", "-generic_top", f"PCIE_HALF={ph}",
                   "-generic_top", f"SYS_HALF={sh}", "work.tb_dst_mux", "work.glbl",
                   "-s", f"snap{i}"], work, f"elab-{name}")
        if not out.startswith("rc=0") or re.search(r"(?m)^ERROR:", out):
            raise SystemExit(f"elaborate failed\n{out[-4000:]}")
        out = run([b / "xsim", f"snap{i}", "-runall"], work, name)
        passed = "DST_MUX_PASS" in out and not re.search(r"(?m)^(ERROR|Fatal)", out)
        if a.mutant:
            marker = MUTANTS[a.mutant][2]
            if not passed and marker in out and "DST_MUX_PASS" not in out:
                print(f"DST_MUTANT_KILLED {a.mutant} at {name}", flush=True)
                killed = True
                break
            continue
        if not passed:
            raise SystemExit(f"{name} FAILED\n{out[-4000:]}")
        print(f"DST_STAGE_PASS {name}: " + " | ".join(
            l.strip() for l in out.splitlines() if l.startswith(("PHASE_", "DST_MUX_PASS"))), flush=True)
    if a.mutant and not killed:
        raise SystemExit(f"DST_MUTANT_SURVIVED {a.mutant}")
    if not a.mutant:
        print(f"DST_RUN_PASS points={len(points)}", flush=True)


if __name__ == "__main__":
    main()
