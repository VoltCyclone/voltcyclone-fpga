#!/usr/bin/env python3
"""Check DRP startup faults using temporary RTL copies and the real bench.

Excluded as equivalent: ignoring the abort at the first read's completion.
The abort flag stays set, the write's completion honours it, and the re-run
reads and verifies the whole word, so the extra write of the same planned
word changes neither the final register nor when drp_ok rises.
"""
import tempfile
from pathlib import Path

import run_r1

MUTANTS = [
    ("drp_ok survives reset source", "            drp_ok <= 1'b0;\n            need_run <= 1'b1;", "            need_run <= 1'b1;"),
    ("no re-run per reset", "            drp_ok <= 1'b0;\n            need_run <= 1'b1;", "            drp_ok <= 1'b0;"),
    ("runs while reset source held", "wire start = state == S_IDLE && need_run && !rst_src;", "wire start = state == S_IDLE && need_run;"),
    ("no base check", "else if ((drp_do & ~PLAN_MASK) != PLAN_BASE_EXPECT) finish_fail(R_BASE);", "else if (1'b0) finish_fail(R_BASE);"),
    ("no verify compare", "else if (drp_do != write_word) finish_fail(R_VERIFY);", "else if (1'b0) finish_fail(R_VERIFY);"),
    ("verify only planned bits", "else if (drp_do != write_word) finish_fail(R_VERIFY);", "else if ((drp_do & PLAN_MASK) != PLAN_VALUE) finish_fail(R_VERIFY);"),
    ("no read timeout", "                end else if (timed_out) finish_fail(R_TIMEOUT);\n            S_WRITE:", "                end\n            S_WRITE:"),
    ("late timeout", "wait_cycles == 16'(RDY_TIMEOUT_CYCLES - 1)", "wait_cycles == 16'(2 * RDY_TIMEOUT_CYCLES)"),
    ("write unmasked value", "issue(1'b1, PLAN_ADDR, planned);", "issue(1'b1, PLAN_ADDR, PLAN_VALUE);"),
    ("always write", "else if (drp_do == planned) begin", "else if (1'b0) begin"),
    ("ignore abort in verify", "                    verify_word <= drp_do;\n                    if (abort || rst_src)", "                    verify_word <= drp_do;\n                    if (1'b0)"),
    ("no host refusal", "wire refuse_host = hp_valid && hp_we && hp_addr == PLAN_ADDR;", "wire refuse_host = 1'b0;"),
    ("refuse host reads too", "wire refuse_host = hp_valid && hp_we && hp_addr == PLAN_ADDR;", "wire refuse_host = hp_valid && hp_addr == PLAN_ADDR;"),
    ("refused host gets core data", "                    host_do <= 16'd0;", "                    host_do <= drp_do;"),
    ("host request dropped", "            hp_valid <= 1'b1; hp_we <= host_we;", "            hp_valid <= 1'b0; hp_we <= host_we;"),
    ("host issued while startup busy", "                end else if (timed_out) finish_fail(R_TIMEOUT);\n            S_WRITE:",
     "                end else if (timed_out) finish_fail(R_TIMEOUT);\n                else if (hp_valid) issue(hp_we, hp_addr, hp_di);\n            S_WRITE:"),
    ("failed not cleared on retry", "                    failed <= 1'b0;\n", ""),
    ("fail count wraps", "if (fail_count != 8'hff) fail_count", "if (1'b1) fail_count"),
    ("swap fail reasons", "localparam [1:0] R_NONE = 2'd0, R_TIMEOUT = 2'd1, R_BASE = 2'd2, R_VERIFY = 2'd3;",
     "localparam [1:0] R_NONE = 2'd0, R_TIMEOUT = 2'd1, R_BASE = 2'd3, R_VERIFY = 2'd2;"),
    ("refusals not counted", "                        host_refused_count <= host_refused_count + 8'd1;", "                        host_refused_count <= host_refused_count;"),
    ("unbounded host transaction", "    wire timed_out = (waiting || state == S_HOST) && window_end;", "    wire timed_out = waiting && window_end;"),
    ("no drain after host timeout", "                        host_timeout_count <= host_timeout_count + 8'd1;\n                    state <= S_DRAIN;",
     "                        host_timeout_count <= host_timeout_count + 8'd1;\n                    state <= S_IDLE;"),
    ("no drain after startup timeout", "state <= reason == R_TIMEOUT ? S_DRAIN : S_IDLE;", "state <= S_IDLE;"),
    ("drain ignores late rdy window", "                if (drp_rdy || window_end) state <= S_IDLE;", "                state <= S_IDLE;"),
    ("timed-out host gets stale data", "                    host_do <= 16'hffff;", "                    host_do <= drp_do;"),
    ("host timeouts not counted", "                        host_timeout_count <= host_timeout_count + 8'd1;", "                        host_timeout_count <= host_timeout_count;"),
    ("failure not sticky", "            fail_sticky <= 1'b1;\n", ""),
    ("drp_en held", "        drp_en <= 1'b0;\n        drp_we <= 1'b0;", "        drp_we <= 1'b0;"),
]


def main() -> int:
    bench = "tb_pcie_drp_startup"
    rtl = run_r1.BENCHES[bench]
    original = (run_r1.SRC / rtl[0]).read_text()
    with tempfile.TemporaryDirectory(prefix="r1-drp-mut-") as scratch:
        scratch_dir = Path(scratch)
        run_r1.SRC = scratch_dir
        source = scratch_dir / rtl[0]
        source.write_text(original)
        passed, log = run_r1.run_bench(bench, rtl, scratch_dir)
        if not passed:
            raise RuntimeError("drp startup positive control failed\n" + log)
        for label, before, after in MUTANTS:
            if original.count(before) != 1:
                raise RuntimeError("stale or ambiguous mutation anchor " + label)
            source.write_text(original.replace(before, after))
            passed, log = run_r1.run_bench(bench, rtl, scratch_dir)
            killed_by = [m for m in ("R1_TB_FAIL",) if m in log]
            if passed or not killed_by:
                raise RuntimeError(
                    "mutation survived or failed to compile " + label + "\n" + log
                )
            print(f"KILLED {label} ({killed_by[0]})", flush=True)
    print(f"R1_DRP_MUTATIONS killed={len(MUTANTS)} total={len(MUTANTS)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
