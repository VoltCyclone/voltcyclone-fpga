#!/usr/bin/env python3
"""Exercise RX completion faults in temporary copies of the source files."""
import shutil
import tempfile
from pathlib import Path

import run_r1

RX = "pcileech_req_rx_cpl.sv"
TABLE = "pcileech_req_table.sv"
MUTANTS = [
    (
        "free on poison",
        RX,
        "!success || final_data;",
        "!success || final_data || in_data[14];",
    ),
    ("clear poison", RX, "restored[15] = 1'b0;", "restored[15:14] = 2'b00;"),
    ("skip TC", RX, "in_data[22:20] == lk_tc && ", ""),
    ("skip Attr", RX, " && in_data[13:12] == lk_attr", ""),
    ("skip Byte Count", RX, "byte_count == lk_remaining && ", ""),
    ("skip Lower Address", RX, " && lower_addr == lk_next_la", ""),
    ("excess payload", RX, "!progress_match || !length_ok", "!progress_match"),
    ("skip format", RX, "!format_ok || !shape_ok", "!shape_ok"),
    ("skip shape", RX, "!format_ok || !shape_ok", "!format_ok"),
    (
        "allow locked completion",
        RX,
        "locked || success != has_data",
        "success != has_data",
    ),
    (
        "allow RESERVED match",
        RX,
        "lk_state == `REQ_ST_ISSUED;",
        "lk_state == `REQ_ST_ISSUED || lk_state == `REQ_ST_RESERVED;",
    ),
    (
        "report active BCM",
        RX,
        "count_bcm = 1'b1;\n                unexpected_valid = quarantined;",
        "count_bcm = 1'b1;\n                unexpected_valid = 1'b1;",
    ),
    (
        "report active CRS",
        RX,
        "count_crs = 1'b1;\n                    unexpected_valid = quarantined;",
        "count_crs = 1'b1;\n                    unexpected_valid = 1'b1;",
    ),
    (
        "ignore late BCM",
        RX,
        "count_bcm = 1'b1;\n                unexpected_valid = quarantined;",
        "count_bcm = 1'b1;",
    ),
    (
        "ignore late CRS",
        RX,
        "count_crs = 1'b1;\n                    unexpected_valid = quarantined;",
        "count_crs = 1'b1;",
    ),
    ("preserve stale TD", RX, "restored[15] = 1'b0;", "restored[15] = in_data[15];"),
    ("forward digest tail", RX, " && (!strip || words_left != 0)", ""),
    ("keep digest DW valid", RX, "in_keep & keep_for_words(words_left)", "in_keep"),
    ("leave old tlast", RX, "strip ? words_left <= 11'd4 : in_last", "in_last"),
    (
        "rewrite RID",
        RX,
        "restored[79:72] = lk_host_tag;",
        "restored[79:72] = lk_host_tag; restored[95:80] = 16'h0240;",
    ),
    (
        "omit tag restore",
        RX,
        "restored[79:72] = lk_host_tag;",
        "restored[79:72] = in_data[79:72];",
    ),
    ("deliver superseded", RX, "else if (lk_superseded)", "else if (1'b0)"),
    ("omit same-edge supersede", TABLE, " || (sup_hit && sup_old == lk_tag)", ""),
    ("deliver FLR partial", RX, " || (flr && !up_retire)", ""),
    (
        "wrap telemetry",
        RX,
        "count == 16'hffff ? count : count + 16'd1",
        "count + 16'd1",
    ),
]


def main() -> int:
    bench = "tb_req_rx_cpl"
    rtl = run_r1.BENCHES[bench]
    source_dir = run_r1.SRC
    originals = {name: (source_dir / name).read_text() for name in rtl}
    with tempfile.TemporaryDirectory(prefix="r1-rx-mut-") as scratch:
        scratch_dir = Path(scratch)
        run_r1.SRC = scratch_dir
        shutil.copyfile(
            source_dir / "pcileech_req_defs.svh", scratch_dir / "pcileech_req_defs.svh"
        )
        for name, source in originals.items():
            (scratch_dir / name).write_text(source)
        passed, log = run_r1.run_bench(bench, rtl, scratch_dir)
        if not passed:
            raise RuntimeError("RX positive control failed\n" + log)
        for label, filename, before, after in MUTANTS:
            if originals[filename].count(before) != 1:
                raise RuntimeError("stale or ambiguous mutation anchor " + label)
            for name, source in originals.items():
                (scratch_dir / name).write_text(
                    source.replace(before, after) if name == filename else source
                )
            passed, log = run_r1.run_bench(bench, rtl, scratch_dir)
            if passed or "R1_TB_FAIL" not in log:
                raise RuntimeError(
                    "mutation survived or failed to compile " + label + "\n" + log
                )
            print("KILLED " + label + " " + log.splitlines()[0], flush=True)
    print(f"R1_RX_MUTATIONS killed={len(MUTANTS)} total={len(MUTANTS)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
