#!/usr/bin/env python3
"""Check status-snapshot faults using temporary RTL copies and the real bench.

A mutant is killed by a bench failure line or by the XPM handshake model's
usage-rule check, which fails the simulation when the data being transferred
moves before the destination captures it.

Excluded as equivalent: removing the S_DRAIN wait. S_IDLE also requires
src_rcv low before it loads a word, so S_DRAIN only spends one extra cycle.
"""
import tempfile
from pathlib import Path

import run_r1

MUTANTS = [
    ("capture every cycle", "    always @(posedge clk_pcie) begin\n        case (state)",
     "    always @(posedge clk_pcie) begin\n        tx_word <= live;\n        case (state)"),
    ("send without load cycle", "                    state    <= S_LOAD;", "                    state    <= S_SEND;\n                    src_send <= 1'b1;"),
    ("drop send early", "                if (src_rcv) begin\n                    src_send <= 1'b0;",
     "                begin\n                    src_send <= 1'b0;"),
    ("capture without request", "        if (dest_req) begin\n            snapshot ", "        begin\n            snapshot "),
    ("frozen sequence", "snap_seq <= snap_seq + 16'd1;", "snap_seq <= snap_seq;"),
    ("valid at power-up", "snapshot_valid = 1'b0; end", "snapshot_valid = 1'b1; end"),
    ("wrong magic", "MAGIC = 16'h5201", "MAGIC = 16'h5200"),
    ("timeouts wrap", "sat_inc = count == 16'hffff ? count : count + 16'd1;", "sat_inc = count + 16'd1;"),
    ("timeouts survive abort", "if (rst_pcie) timed_out_count <= 16'd0;", "if (1'b0) timed_out_count <= 16'd0;"),
    ("timeouts ignored", "else if (timeout_valid) timed_out_count", "else if (1'b0) timed_out_count"),
    ("aborts count level", "if (rst_pcie && !rst_pcie_d) session_aborts", "if (rst_pcie) session_aborts"),
    ("aborts reset by abort", "        if (rst_pcie && !rst_pcie_d) session_aborts",
     "        if (rst_pcie && rst_pcie_d) session_aborts <= 16'd0;\n        else if (rst_pcie && !rst_pcie_d) session_aborts"),
    ("drop abort flag", "err_bypass, rst_pcie\n", "err_bypass, 1'b0\n"),
    ("swap stickies", "err_overflow, err_release, err_bypass,", "err_overflow, err_bypass, err_release,"),
    ("drop queue overflow sticky", "11'd0, err_overflow,", "11'd0, 1'b0,"),
    ("swap live counts", "7'd0, n_quarantined, 7'd0, n_issued,", "7'd0, n_issued, 7'd0, n_quarantined,"),
    ("swap admitted/completed", "completed_count, admitted_count,", "admitted_count, completed_count,"),
    ("swap unexpected/malformed", "superseded_count, malformed_count,\n        unexpected_count,",
     "superseded_count, unexpected_count,\n        malformed_count,"),
    ("swap BCM/CRS", "crs_count, bcm_count,", "bcm_count, crs_count,"),
    ("omit tx drop", "tx_drop_count, refuse_counts,", "16'd0, refuse_counts,"),
    ("swap level/high water", "16'(err_high_water), 16'(err_level),", "16'(err_level), 16'(err_high_water),"),
    ("swap reported/overflow", "err_overflow_count, err_suppressed_count, err_reported_count,",
     "err_reported_count, err_suppressed_count, err_overflow_count,"),
    ("nonzero reserved", "{48'd0, snapshot,", "{48'd1, snapshot,"),
]


def main() -> int:
    bench = "tb_req_status"
    rtl = run_r1.BENCHES[bench]
    original = (run_r1.SRC / rtl[0]).read_text()
    with tempfile.TemporaryDirectory(prefix="r1-status-mut-") as scratch:
        scratch_dir = Path(scratch)
        run_r1.SRC = scratch_dir
        source = scratch_dir / rtl[0]
        source.write_text(original)
        passed, log = run_r1.run_bench(bench, rtl, scratch_dir)
        if not passed:
            raise RuntimeError("status positive control failed\n" + log)
        for label, before, after in MUTANTS:
            if original.count(before) != 1:
                raise RuntimeError("stale or ambiguous mutation anchor " + label)
            source.write_text(original.replace(before, after))
            passed, log = run_r1.run_bench(bench, rtl, scratch_dir)
            killed_by = [m for m in ("R1_TB_FAIL", "XPM_MODEL_ERROR") if m in log]
            if passed or not killed_by:
                raise RuntimeError(
                    "mutation survived or failed to compile " + label + "\n" + log
                )
            print(f"KILLED {label} ({killed_by[0]})", flush=True)
    print(f"R1_STATUS_MUTATIONS killed={len(MUTANTS)} total={len(MUTANTS)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
