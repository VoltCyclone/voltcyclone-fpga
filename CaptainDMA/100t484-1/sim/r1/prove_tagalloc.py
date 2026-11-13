#!/usr/bin/env python3
"""Prove the allocator equivalent to its frozen pre-optimization baseline.

Yosys proves matched state/outputs without free-vector or pointer/range
assumptions. Icarus separately compares four-state offers for every binary
pointer/range, sparse/random vectors and X/Z inputs. Existing tb_req_tagalloc
covers reset/take/availability and range transitions. --candidate permits
negative controls on temporary copies without rewriting the working RTL.
"""

import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SRC = HERE.parents[1] / "src"
BASELINE_SHA256 = "8face52afeeaf81f163340f39c6bde3335cf3ed5420d1d81aeec8a2e95e438de"


def run(argv, timeout=180):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(
            "command failed: " + " ".join(argv) + "\n" + result.stdout + result.stderr
        )
    return result.stdout + result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--candidate", type=Path, default=SRC / "pcileech_req_tagalloc.sv"
    )
    args = parser.parse_args()
    candidate = args.candidate.read_bytes()
    candidate_sha256 = hashlib.sha256(candidate).hexdigest()
    reference = (HERE / "tagalloc_reference.sv").read_text()
    original = reference.replace(
        "module req_tagalloc_reference (", "module pcileech_req_tagalloc (", 1
    )
    if hashlib.sha256(original.encode()).hexdigest() != BASELINE_SHA256:
        raise RuntimeError("Frozen allocator reference changed")
    with tempfile.TemporaryDirectory(prefix="tagalloc-equiv-") as scratch:
        root = Path(scratch)
        candidate_source = root / "candidate.sv"
        candidate_source.write_bytes(candidate)
        reference_source = root / "reference.sv"
        reference_source.write_text(reference)
        gold = root / "gold.sv"
        gate = root / "gate.sv"
        gold.write_text(
            reference.replace("module req_tagalloc_reference (", "module gold (", 1)
        )
        gate.write_text(
            candidate.decode().replace(
                "module pcileech_req_tagalloc (", "module gate (", 1
            )
        )
        proof = root / "proof.ys"
        proof.write_text(
            "read_verilog -sv gold.sv gate.sv\nproc\nopt_clean\n"
            "equiv_make gold gate equiv\nhierarchy -top equiv\n"
            "equiv_simple\nequiv_induct -seq 2\nequiv_status -assert\n"
        )
        result = subprocess.run(
            ["yosys", "-Q", "-T", "-s", str(proof)],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=180,
        )
        if result.returncode or "Equivalence successfully proven!" not in result.stdout:
            raise RuntimeError(
                "Allocator formal equivalence failed\n" + result.stdout + result.stderr
            )
        print(
            "TAGALLOC_FORMAL_EQUIVALENCE_PASS baseline_sha256="
            + BASELINE_SHA256
            + " candidate_sha256="
            + candidate_sha256,
            flush=True,
        )
        for line in result.stdout.splitlines():
            if "equiv cells" in line or "proven" in line:
                print(line, flush=True)
        out = root / "compare.vvp"
        run(
            [
                "iverilog",
                "-g2012",
                "-Wall",
                "-s",
                "tb_req_tagalloc_equiv",
                "-o",
                str(out),
                str(candidate_source),
                str(reference_source),
                str(HERE / "tb_req_tagalloc_equiv.sv"),
            ]
        )
        simulated = run(["vvp", "-n", str(out)])
        if (
            "R1_TB_PASS tb_req_tagalloc_equiv" not in simulated
            or "R1_TB_FAIL" in simulated
        ):
            raise RuntimeError("Allocator four-state equivalence failed\n" + simulated)
        print(simulated.rstrip(), flush=True)
    print("TAGALLOC_EQUIVALENCE_PASS", flush=True)


if __name__ == "__main__":
    main()
