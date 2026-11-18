"""Prove the registered-offer tag allocator (SymbiYosys).

1. Safety (k-induction, tagalloc_safety.sv): with the table's only FREE-removal
   being the allocator's take, an offered tag is FREE whenever it is visible or
   taken. Port-level assertions only (Yosys does not resolve hierarchical
   references here; they would become unconstrained wires).
2. Equivalence (k-induction, bitwuzla): the RTL matches tagalloc_registered_spec.sv,
   a plain modular-scan specification with the same registers, on every
   register and port. The miter exposes both modules' flip-flops as ports.
3. Negative controls: candidate mutants that must fail (safety prove, or a
   depth-5 equivalence BMC), so the proofs are known to be able to fail.

``--candidate PATH`` checks a temporary copy instead of the working RTL.
Requires sby, yosys, yices and bitwuzla (oss-cad-suite).
"""

import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SRC = HERE.parents[1] / "src" / "pcileech_req_tagalloc.sv"

SAFETY = """[options]
mode {mode}
depth {depth}

[engines]
smtbmc yices

[script]
read_verilog -sv -formal pcileech_req_tagalloc.sv
read_verilog -sv -formal tagalloc_safety.sv
prep -top tagalloc_safety

[files]
pcileech_req_tagalloc.sv
tagalloc_safety.sv
"""

EQUIV = """[options]
mode {mode}
depth {depth}

[engines]
smtbmc bitwuzla

[script]
read_verilog -sv gold.sv
read_verilog -sv gate.sv
proc
opt_clean
expose -dff gold gate
miter -equiv -flatten -make_outputs -ignore_gold_x gold gate miter
read_verilog -sv -formal tagalloc_equiv_top.sv
hierarchy -top equiv_top
proc
flatten

[files]
gold.sv
gate.sv
tagalloc_equiv_top.sv
"""

# (name, old, new, which proof must fail)
MUTANTS = [
    (
        "offer_not_excluded_on_take",
        "assign cand_take[index]  = cand[index] & (8'(index) != offer);",
        "assign cand_take[index]  = cand[index];",
        "safety",
    ),
    (
        "keep_offer_after_take",
        "{offer_ok, offer} <= next_take;",
        "{offer_ok, offer} <= next_keep;",
        "safety",
    ),
    ("pointer_frozen", "ptr <= offer + 8'd1;", "ptr <= ptr;", "equiv"),
    (
        "range_not_reapplied",
        "assign avail = offer_ok && (ext_tag_en || offer < 8'd32);",
        "assign avail = offer_ok;",
        "equiv",
    ),
]


def sby(workdir, name, config, rtl):
    work = workdir / name
    work.mkdir()
    shutil.copyfile(rtl, work / "pcileech_req_tagalloc.sv")
    shutil.copyfile(HERE / "tagalloc_safety.sv", work / "tagalloc_safety.sv")
    shutil.copyfile(HERE / "tagalloc_equiv_top.sv", work / "tagalloc_equiv_top.sv")
    (work / "gold.sv").write_text(
        (HERE / "tagalloc_registered_spec.sv")
        .read_text()
        .replace("module req_tagalloc_spec (", "module gold (", 1)
    )
    (work / "gate.sv").write_text(
        Path(rtl).read_text().replace("module pcileech_req_tagalloc (", "module gate (", 1)
    )
    (work / "proof.sby").write_text(config)
    result = subprocess.run(
        ["sby", "-f", "proof.sby"], cwd=work, capture_output=True, text=True, timeout=3600
    )
    done = [l for l in result.stdout.splitlines() if "DONE" in l]
    return result.returncode == 0, (done[-1] if done else result.stdout[-400:])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", type=Path, default=SRC)
    args = parser.parse_args()
    rtl = args.candidate.resolve()
    with tempfile.TemporaryDirectory(prefix="tagalloc-proof-") as scratch:
        root = Path(scratch)
        ok, msg = sby(root, "safety", SAFETY.format(mode="prove", depth=4), rtl)
        print(("TAGALLOC_SAFETY_PASS " if ok else "TAGALLOC_SAFETY_FAIL ") + msg, flush=True)
        if not ok:
            return 1
        ok, msg = sby(root, "equiv", EQUIV.format(mode="prove", depth=2), rtl)
        print(("TAGALLOC_EQUIV_PASS " if ok else "TAGALLOC_EQUIV_FAIL ") + msg, flush=True)
        if not ok:
            return 1
        if args.candidate != SRC:
            return 0
        original = rtl.read_text()
        killed = 0
        for name, old, new, proof in MUTANTS:
            if original.count(old) != 1:
                raise RuntimeError(f"stale mutation anchor: {name}")
            mutant = root / f"{name}.sv"
            mutant.write_text(original.replace(old, new))
            config = (
                SAFETY.format(mode="prove", depth=4)
                if proof == "safety"
                else EQUIV.format(mode="bmc", depth=5)
            )
            ok, msg = sby(root, "mut_" + name, config, mutant)
            killed += not ok
            print(("KILLED " if not ok else "SURVIVED ") + f"{name} ({proof}): {msg}", flush=True)
        print(f"TAGALLOC_MUTANTS killed={killed} total={len(MUTANTS)}", flush=True)
        return 0 if killed == len(MUTANTS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
