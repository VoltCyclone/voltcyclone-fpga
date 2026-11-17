#!/usr/bin/env python3
"""Check tag-lifecycle faults in pcileech_req_table using temporary RTL copies
and the real tb_req_table bench (R4: no unsafe tag reuse after a timeout).

Every mutant here would let a tag be handed out again while a completion for
its previous use can still arrive (or would keep a tag out of use for ever).
A mutant is killed only by an R1_TB_FAIL from a bench that compiled and ran.

Excluded: the table's response to an admission of a tag that is not FREE.
The allocator never offers one (tb_req_tagalloc_spec proves it against the
registered spec); the table bench does not drive that illegal input.
"""
import tempfile
from pathlib import Path

import run_r1

MUTANTS = [
    # timeout frees the tag at once: a late completion would match its next use
    ("timeout frees", "            if (sw_expire_raw)\n                st[sw_idx] <= `REQ_ST_QUARANTINED;",
     "            if (sw_expire_raw)\n                st[sw_idx] <= `REQ_ST_FREE;"),
    # quarantined entries offered to the allocator
    ("quarantined counted free", "assign free[g] = (st[g] == `REQ_ST_FREE);",
     "assign free[g] = (st[g] == `REQ_ST_FREE) || (st[g] == `REQ_ST_QUARANTINED);"),
    # drain after half the window
    ("drain at Q/2", "(sw_age_q >= sw_q);", "(sw_age_q >= (sw_q >> 1));"),
    # drain measured from issue instead of the quarantine time
    ("drain from issue time", "wire [W-1:0] sw_age_q   = now - sw_tq;",
     "wire [W-1:0] sw_age_q   = now - sw_iss[W+4:5];"),
    # quarantine never drains: tags are lost until a link reset
    ("no drain", "(sw_age_q >= sw_q);", "1'b0;"),
    # FLR leaves issued requests live (no quarantine)
    ("FLR keeps ISSUED", "if (st[i] == `REQ_ST_ISSUED)   st[i] <= `REQ_ST_QUARANTINED;",
     "if (1'b0)   st[i] <= `REQ_ST_QUARANTINED;"),
    # an entry RESERVED at an FLR becomes ISSUED instead of QUARANTINED on issue
    ("FLR-reserved issue goes live", "wire iss_q = flr || fl[iss_tag];", "wire iss_q = flr;"),
    # FLR quarantine drains from the issue time instead of the FLR time
    ("FLR drain from issue", "fl[sw_idx] ? t_flr : tqr[sw_idx];", "tqr[sw_idx];"),
    # expiry before the timeout window
    ("expire at T/2", "(sw_age_iss >= sw_t) && !flr;", "(sw_age_iss >= (sw_t >> 1)) && !flr;"),
]


def main() -> int:
    bench = "tb_req_table"
    rtl = run_r1.BENCHES[bench]
    original = (run_r1.SRC / rtl[0]).read_text()
    others = {name: (run_r1.SRC / name).read_text() for name in rtl[1:]}
    with tempfile.TemporaryDirectory(prefix="r1-table-mut-") as scratch:
        scratch_dir = Path(scratch)
        headers = list(run_r1.SRC.glob("*.svh"))
        run_r1.SRC = scratch_dir
        for name, text in others.items():
            (scratch_dir / name).write_text(text)
        for header in headers:
            (scratch_dir / header.name).write_text(header.read_text())
        source = scratch_dir / rtl[0]
        source.write_text(original)
        passed, log = run_r1.run_bench(bench, rtl, scratch_dir)
        if not passed:
            raise RuntimeError("table positive control failed\n" + log)
        for label, before, after in MUTANTS:
            if original.count(before) != 1:
                raise RuntimeError("stale or ambiguous mutation anchor " + label)
            source.write_text(original.replace(before, after))
            passed, log = run_r1.run_bench(bench, rtl, scratch_dir)
            if passed or "R1_TB_FAIL" not in log:
                raise RuntimeError("mutation survived or failed to compile " + label + "\n" + log[-3000:])
            first = next((l for l in log.splitlines() if "FAIL" in l and "R1_TB_FAIL" not in l), "R1_TB_FAIL")
            print(f"KILLED {label} ({first.strip()[:100]})", flush=True)
    print(f"R1_TABLE_MUTATIONS killed={len(MUTANTS)} total={len(MUTANTS)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
