#!/usr/bin/env python3
"""Reject NP-credit sampling faults using temporary copies and the real bench."""
from pathlib import Path
import tempfile
import run_r1

MUTANTS = [
    ("unknown credit admits", "default: cap <= 9'd0;", "default: cap <= 9'd35;"),
    ("resample cumulative credits", "up_delay[1] && !sampled", "up_delay[1]"),
    ("sample before selector latency", "up_delay[1] && !sampled", "up_delay[0] && !sampled"),
    ("zero credit closes forever", "if (fc_nph == 8'd0) cap <= 9'd35;", "if (fc_nph == 8'd0) cap <= 9'd0;"),
    ("infinite credit overestimates", "if (fc_nph == 8'd0) cap <= 9'd35;", "if (fc_nph == 8'd0) cap <= 9'd256;"),
    ("wrong cadence multiplier", "* 9'd35;", "* 9'd36;"),
    ("late saturation", "fc_nph >= 8'd8", "fc_nph >= 8'd9"),
    ("wrong saturation", "cap <= 9'd256;", "cap <= 9'd255;"),
    ("sample survives session loss", "if (rst || !link_up) begin", "if (rst) begin"),
    ("sample survives core reset", "if (rst || !link_up) begin", "if (!link_up) begin"),
    ("unmasked link loss", "assign np_cap = (rst || !link_up) ? 9'd0 : cap;", "assign np_cap = cap;"),
]

def main():
    rtl = run_r1.BENCHES["tb_req_np_cap"]
    original = (run_r1.SRC / rtl[0]).read_text()
    with tempfile.TemporaryDirectory(prefix="r1-npcap-mut-") as scratch:
        run_r1.SRC = Path(scratch)
        source = run_r1.SRC / rtl[0]
        source.write_text(original)
        passed, log = run_r1.run_bench("tb_req_np_cap", rtl, run_r1.SRC)
        if not passed: raise RuntimeError("positive control failed\n" + log)
        for label, before, after in MUTANTS:
            if original.count(before) != 1: raise RuntimeError("ambiguous anchor " + label)
            source.write_text(original.replace(before, after))
            passed, log = run_r1.run_bench("tb_req_np_cap", rtl, run_r1.SRC)
            if passed or "R1_TB_FAIL" not in log:
                raise RuntimeError("mutant survived or did not simulate: " + label + "\n" + log)
            print("KILLED " + label, flush=True)
    print(f"R1_NP_CAP_MUTATIONS killed={len(MUTANTS)} total={len(MUTANTS)}")

if __name__ == "__main__": main()
