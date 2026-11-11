#!/usr/bin/env python3
"""Check error-queue faults using temporary RTL copies and the real bench."""
import tempfile
from pathlib import Path

import run_r1

MUTANTS = [
    ("multiple reports", "report && kind == UNEXPECTED", "report"),
    ("wrong timeout qualifier", "report && kind != TIMEOUT", "report"),
    ("unrecoverable CTO", "cfg_err_no_recovery = 1'b0", "cfg_err_no_recovery = 1'b1"),
    ("ignore D0", "wire report = pop && d0;", "wire report = pop;"),
    ("hold queued non-D0 errors", "(!d0 || !hold_header)", "!hold_header"),
    ("retain non-D0 arrivals", "!rst && d0 && source_valid", "!rst && source_valid"),
    ("lose head advance", "head + AW'(pop)", "head"),
    ("advance tail by one", "tail <= tail + AW'(accepted);", "tail <= tail + AW'(1);"),
    ("overwrite queue count", "level + CW'(accepted)", "CW'(accepted)"),
    ("ignore freed full slot", " + {{CW{1'b0}}, pop}", ""),
    ("write wrong bank", "== 2'(bank)", "== 2'd0"),
    ("wrong event kind", "{TIMEOUT, 128'd0}", "{UNEXPECTED, 128'd0}"),
    (
        "reverse header order",
        "raw_header[31:0], raw_header[63:32], raw_header[95:64]",
        "raw_header[95:64], raw_header[63:32], raw_header[31:0]",
    ),
    ("log payload DW", "three_dw ? 32'd0 : raw_header[127:96]", "raw_header[127:96]"),
    ("lose retained header", "held_header <= aer_header;", "held_header <= 0;"),
    (
        "ignore AER masks",
        "{~aer_uncor_mask[16], ~aer_uncor_mask[18], ~aer_uncor_mask[14]}",
        "3'b111",
    ),
    ("wrong CTO mask", "~aer_uncor_mask[14]", "~aer_uncor_mask[13]"),
    ("wrong unexpected mask", "~aer_uncor_mask[16]", "~aer_uncor_mask[17]"),
    ("wrong malformed mask", "~aer_uncor_mask[18]", "~aer_uncor_mask[19]"),
    ("skip pending suppression", "arrivals + {2'd0, pop}", "arrivals"),
    ("lose overflow accounting", "sat_add(overflow_count, lost)", "overflow_count"),
    ("lose high water", "if (next_level > high_water)", "if (1'b0)"),
    ("wrap telemetry", "sum[16] ? 16'hffff : sum[15:0]", "sum[15:0]"),
]


def main() -> int:
    bench = "tb_req_err"
    rtl = run_r1.BENCHES[bench]
    original = (run_r1.SRC / rtl[0]).read_text()
    with tempfile.TemporaryDirectory(prefix="r1-err-mut-") as scratch:
        scratch_dir = Path(scratch)
        run_r1.SRC = scratch_dir
        source = scratch_dir / rtl[0]
        source.write_text(original)
        passed, log = run_r1.run_bench(bench, rtl, scratch_dir)
        if not passed:
            raise RuntimeError("error-queue positive control failed\n" + log)
        for label, before, after in MUTANTS:
            if original.count(before) != 1:
                raise RuntimeError("stale or ambiguous mutation anchor " + label)
            source.write_text(original.replace(before, after))
            passed, log = run_r1.run_bench(bench, rtl, scratch_dir)
            if passed or "R1_TB_FAIL" not in log:
                raise RuntimeError(
                    "mutation survived or failed to compile " + label + "\n" + log
                )
            print("KILLED " + label + " " + log.splitlines()[0], flush=True)
    print(f"R1_ERR_MUTATIONS killed={len(MUTANTS)} total={len(MUTANTS)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
