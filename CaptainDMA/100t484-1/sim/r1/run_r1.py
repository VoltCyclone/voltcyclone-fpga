#!/usr/bin/env python3
"""Run the R1 requester-tracking benches.

Each bench is compiled with Icarus Verilog (-g2012) against the board sources and
must print ``R1_TB_PASS``; any ``R1_TB_FAIL``/``R1_TB_FAILED`` line or a missing
pass marker fails the run. RTL under test is also linted with Verilator when it is
installed. Usage: ``python3 run_r1.py [bench ...]`` (default: all ``tb_*.sv``).
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE.parents[1] / "src"

# bench -> RTL files it exercises (relative to SRC)
BENCHES = {
    "tb_req_np_cap": ["pcileech_req_np_cap.sv"],
    "tb_req_classify": ["pcileech_req_classify.sv"],
    "tb_req_tagalloc": ["pcileech_req_tagalloc.sv"],
    "tb_req_cto_limits": ["pcileech_req_cto_limits.sv"],
    "tb_req_table": ["pcileech_req_table.sv", "pcileech_req_cto_limits.sv"],
    "tb_req_err": ["pcileech_req_err.sv"],
    "tb_req_rx_cpl": [
        "pcileech_req_rx_cpl.sv",
        "pcileech_req_table.sv",
        "pcileech_req_cto_limits.sv",
    ],
    "tb_req_tx_obs": [
        "pcileech_req_tx_obs.sv",
        "pcileech_req_table.sv",
        "pcileech_req_cto_limits.sv",
    ],
    "tb_req_gate": [
        "pcileech_req_gate.sv",
        "pcileech_req_classify.sv",
        "pcileech_req_tagalloc.sv",
        "pcileech_req_table.sv",
        "pcileech_req_cto_limits.sv",
    ],
    "tb_req_gate_counters": [
        "pcileech_req_gate.sv",
        "pcileech_req_classify.sv",
        "pcileech_req_tagalloc.sv",
    ],
    "tb_req_status": ["pcileech_req_status.sv"],
    "tb_pcie_drp_startup": ["pcileech_pcie_drp_startup.sv"],
}

# Simulation-only models (in this directory) compiled with a bench, and the
# port-only stubs that stand in for them when linting the RTL.
SIM_MODELS = {"tb_req_status": ["xpm_cdc_handshake_model.sv"]}
LINT_STUBS = {"pcileech_req_status": ["xpm_cdc_handshake_bbox.sv"]}

# bench -> parameter sets; each set is a separate run.
CASES = {
    "tb_req_gate": [{"CAP": cap} for cap in (3, 36, 256)],
    "tb_pcie_drp_startup": [{"CHECK": 65295}, {"CHECK": 3840}],
    "tb_req_status": [
        {"PCIE_PS": pcie, "SYS_PS": sys_}
        for pcie, sys_ in (
            (16000, 10000),
            (8000, 10000),
            (2700, 41000),
            (97000, 10000),
        )
    ],
}


def run_bench(name, rtl, workdir, parameters=None):
    out = workdir / f"{name}.vvp"
    argv = [
        "iverilog",
        "-g2012",
        "-Wall",
        "-I",
        str(SRC),
        "-s",
        name,
        "-o",
        str(out),
        *[f"-P{name}.{key}={value}" for key, value in (parameters or {}).items()],
        *[str(SRC / f) for f in rtl],
        *[str(HERE / f) for f in SIM_MODELS.get(name, [])],
        str(HERE / f"{name}.sv"),
    ]
    built = subprocess.run(argv, capture_output=True, text=True)
    if built.returncode != 0:
        return False, "compile failed:\n" + built.stdout + built.stderr
    ran = subprocess.run(
        ["vvp", "-n", str(out)], capture_output=True, text=True, timeout=600
    )
    text = ran.stdout + ran.stderr
    ok = (
        ran.returncode == 0
        and f"R1_TB_PASS {name}" in text
        and "R1_TB_FAIL" not in text
    )
    return ok, text


def lint(rtl):
    if not shutil.which("verilator"):
        return True, "verilator not installed; lint skipped"
    top = Path(rtl[0]).stem
    argv = ["verilator", "--lint-only", "-Wall", "--top-module", top, "-I" + str(SRC)]
    if top == "pcileech_pcie_drp_startup":
        # test fixture only; production binds the tracking plan's DRP values
        argv += ["-GPLAN_BOUND=1", "-GPLAN_MASK=16'h00f0", "-GPLAN_VALUE=16'h0050",
                 "-GPLAN_CHECK_MASK=16'h0f00", "-GPLAN_BASE_EXPECT=16'h0200",
                 "-GRDY_TIMEOUT_CYCLES=64"]
    argv += [str(SRC / f) for f in rtl]
    argv += [str(HERE / f) for f in LINT_STUBS.get(top, [])]
    res = subprocess.run(argv, capture_output=True, text=True)
    return res.returncode == 0, res.stdout + res.stderr


def main(selected):
    if not (shutil.which("iverilog") and shutil.which("vvp")):
        print("R1_RUN_SKIP iverilog/vvp not installed")
        return 2
    names = selected or sorted(BENCHES)
    failed = []
    jobs = 0
    with tempfile.TemporaryDirectory() as tmp:
        for name in names:
            for parameters in CASES.get(name, [{}]):
                jobs += 1
                label = " ".join(
                    [name, *(f"{key}={value}" for key, value in parameters.items())]
                )
                ok, text = run_bench(name, BENCHES[name], Path(tmp), parameters)
                lint_ok, lint_text = lint(BENCHES[name])
                status = "PASS" if ok and lint_ok else "FAIL"
                print(f"[{status}] {label}")
                print(text.rstrip())
                if not lint_ok:
                    print("lint:\n" + lint_text.rstrip())
                if status == "FAIL":
                    failed.append(label)
    print(f"R1_RUN_SUMMARY passed={jobs - len(failed)} failed={len(failed)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
