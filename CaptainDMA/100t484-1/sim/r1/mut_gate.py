#!/usr/bin/env python3
"""Mutation checks for the requester gate; never modify the working RTL.

Only an explicit R1_TB_FAIL from a successfully compiled simulation kills a
mutant. Compile errors, missing markers and timeouts are campaign errors.
"""
import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from run_r1 import BENCHES, HERE, SRC

GATE = "pcileech_req_gate.sv"
# name, old text, replacement, bench, CAP (for the stream bench).
MUTANTS = [
    (
        "ignore_class",
        "else if (cls == `REQ_CLS_REFUSE)",
        "else if (1'b0)",
        "tb_req_gate",
        36,
    ),
    ("pass_orphan_tail", "if (!in_user[0])", "if (1'b0)", "tb_req_gate", 36),
    ("ignore_no_tag", "if (!tag_avail)", "if (1'b0)", "tb_req_gate", 36),
    ("omit_np_cap", "n_np >= 10'(N_NP_MAX)", "1'b0", "tb_req_gate", 36),
    (
        "cap_from_tag_width",
        "n_np >= 10'(N_NP_MAX)",
        "n_np >= 10'd256",
        "tb_req_gate",
        36,
    ),
    (
        "cap_off_by_one",
        "n_np >= 10'(N_NP_MAX)",
        "n_np > 10'(N_NP_MAX)",
        "tb_req_gate",
        3,
    ),
    (
        "ignore_issued_count",
        "{1'b0,n_reserved} + {1'b0,n_issued}",
        "{1'b0,n_reserved}",
        "tb_req_gate",
        36,
    ),
    (
        "no_tag_rewrite",
        "rewritten[47:40] = adm_tag",
        "rewritten[47:40] = in_data[47:40]",
        "tb_req_gate",
        36,
    ),
    (
        "rewrite_rid",
        "if (adm_valid) rewritten[47:40] = adm_tag;",
        "if (adm_valid) begin rewritten[47:40] = adm_tag; rewritten[63:48] = 0; end",
        "tb_req_gate",
        36,
    ),
    ("corrupt_keep", "<= in_keep;", "<= 4'hf;", "tb_req_gate", 36),
    ("corrupt_user", "<= in_user;", "<= 9'd0;", "tb_req_gate", 36),
    ("corrupt_last", "<= in_last;", "<= 1'b1;", "tb_req_gate", 36),
    (
        "gate_admit_on_sink",
        "!rst && in_valid && start_packet &&",
        "!rst && in_valid && out_ready && start_packet &&",
        "tb_req_gate",
        36,
    ),
    ("take_tag_on_pass", ".take(adm_valid)", ".take(in_valid)", "tb_req_gate", 36),
    (
        "ignore_extended_tags",
        ".ext_tag_en(ext_tag_en)",
        ".ext_tag_en(1'b0)",
        "tb_req_gate",
        36,
    ),
    ("lowest_free_reuse", ".take(adm_valid)", ".take(1'b0)", "tb_req_gate", 36),
    (
        "request_without_slot",
        "q_count_next <= 2'd1",
        "q_count_next <= 2'd2",
        "tb_req_gate",
        36,
    ),
    (
        "ignore_promised_input",
        "q_count_next <= 2'd1",
        "q_count <= 2'd1",
        "tb_req_gate",
        36,
    ),
    (
        "pop_without_pull",
        "!rst && out_ready && (q_count != 0)",
        "!rst && (q_count != 0)",
        "tb_req_gate",
        36,
    ),
    ("suppress_output", "out_valid <= pop;", "out_valid <= 0;", "tb_req_gate", 36),
    ("dont_advance_head", "q_head <= ~q_head;", "q_head <= q_head;", "tb_req_gate", 36),
    ("overwrite_head", "q_head ^ q_count[0]", "q_head", "tb_req_gate", 36),
    (
        "forget_packet_drop",
        "start_packet ? refuse : drop_packet",
        "refuse",
        "tb_req_gate",
        36,
    ),
    (
        "reclassify_mid_packet",
        "wire start_packet = !in_packet;",
        "wire start_packet = in_user[0];",
        "tb_req_gate",
        36,
    ),
    ("has_data_stuck_low", "!rst && (q_count != 0);", "1'b0;", "tb_req_gate", 36),
    (
        "reverse_reason_counters",
        "refuse_counts[(g-1)*16 +: 16]",
        "refuse_counts[(7-g)*16 +: 16]",
        "tb_req_gate",
        36,
    ),
    (
        "count_pass_as_admitted",
        "if (adm_valid && admitted_count",
        "if (in_valid && admitted_count",
        "tb_req_gate",
        36,
    ),
    (
        "admitted_counter_wrap",
        "adm_valid && admitted_count != 16'hffff",
        "adm_valid",
        "tb_req_gate_counters",
        36,
    ),
    (
        "refusal_counter_wrap",
        "refuse && refuse_count[refuse_reason[2:0]] != 16'hffff",
        "refuse",
        "tb_req_gate_counters",
        36,
    ),
]


def simulate(src, bench, cap, work):
    out = work / "mut.vvp"
    parameters = [f"-P{bench}.CAP={cap}"] if bench == "tb_req_gate" else []
    argv = [
        "iverilog",
        "-g2012",
        "-I",
        str(src),
        "-s",
        bench,
        *parameters,
        "-o",
        str(out),
        *[str(src / f) for f in BENCHES[bench]],
        str(HERE / (bench + ".sv")),
    ]
    built = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    if built.returncode:
        raise RuntimeError(
            "compile error (not a kill):\n" + built.stdout + built.stderr
        )
    ran = subprocess.run(
        ["vvp", "-n", str(out)], capture_output=True, text=True, timeout=60
    )
    log = ran.stdout + ran.stderr
    if "R1_TB_FAIL" in log:
        return False, log.splitlines()[0]
    if ran.returncode or f"R1_TB_PASS {bench}" not in log:
        raise RuntimeError("invalid simulation outcome (not a kill):\n" + log)
    return True, log.splitlines()[0]


def main():
    original = (SRC / GATE).read_text()
    results = []
    with tempfile.TemporaryDirectory(prefix="req-gate-mut-") as tmp:
        work = Path(tmp)
        src = work / "src"
        src.mkdir()
        for f in {
            f
            for bench in ("tb_req_gate", "tb_req_gate_counters")
            for f in BENCHES[bench]
        }:
            shutil.copyfile(SRC / f, src / f)
        shutil.copyfile(SRC / "pcileech_req_defs.svh", src / "pcileech_req_defs.svh")
        # Positive controls ensure the two unmutated benches are valid first.
        for bench in ("tb_req_gate", "tb_req_gate_counters"):
            ok, message = simulate(src, bench, 36, work)
            if not ok:
                raise RuntimeError("positive control failed: " + message)
        for name, old, new, bench, cap in MUTANTS:
            if old not in original:
                raise RuntimeError(f"stale mutation anchor: {name}")
            (src / GATE).write_text(original.replace(old, new))
            survived, message = simulate(src, bench, cap, work)
            results.append({"name": name, "killed": not survived, "evidence": message})
            print(
                ("SURVIVED " if survived else "KILLED ") + name + ": " + message,
                flush=True,
            )
    hashes = {
        str(p.relative_to(HERE.parents[1])): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in [SRC / GATE, HERE / "tb_req_gate.sv", HERE / "tb_req_gate_counters.sv"]
    }
    (HERE / "req_gate_mutations.json").write_text(
        json.dumps({"hashes": hashes, "results": results}, indent=2) + "\n"
    )
    killed = sum(r["killed"] for r in results)
    print(f"R1_MUT_GATE_SUMMARY killed={killed} total={len(results)}")
    return 0 if killed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
