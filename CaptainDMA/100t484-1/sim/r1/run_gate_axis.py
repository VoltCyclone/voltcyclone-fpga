#!/usr/bin/env python3
"""Run the gate and requester TX path with their real SystemVerilog interfaces.

The ordinary R1 runner uses Icarus (which cannot elaborate these modports).
This command also lints the adapter with -Wall and tests invalid NP-cap guards.
All generated binaries live in a temporary directory.
"""
import subprocess
import tempfile
from pathlib import Path

from run_r1 import BENCHES, HERE, SRC


def run(argv, timeout=180):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(
            f"command failed: {argv}\n{result.stdout[-8000:]}{result.stderr[-8000:]}"
        )
    return result.stdout + result.stderr


def main():
    sources = [str(SRC / f) for f in BENCHES["tb_req_gate"]]
    adapter = str(SRC / "pcileech_req_gate_axis.sv")
    run(
        [
            "verilator",
            "--lint-only",
            "-Wall",
            "--top-module",
            "pcileech_req_gate_axis",
            "-GN_NP_MAX=36",
            "-I" + str(SRC),
            adapter,
            *sources,
        ]
    )
    with tempfile.TemporaryDirectory(prefix="req-gate-axis-") as tmp:
        work = Path(tmp)
        run(
            [
                "verilator",
                "--binary",
                "--timing",
                "--top-module",
                "tb_req_gate",
                "-DGATE_AXIS",
                "-I" + str(SRC),
                "--Mdir",
                str(work / "obj"),
                adapter,
                *sources,
                str(HERE / "tb_req_gate.sv"),
            ]
        )
        log = run([str(work / "obj" / "Vtb_req_gate")], timeout=60)
        if "R1_TB_PASS tb_req_gate" not in log or "R1_TB_FAIL" in log:
            raise RuntimeError(log)
        print("[PASS] IfAXIS128 adapter lint and scoreboard")
        print(log.rstrip())
        for cap in (-1, 0, 257):
            bench = work / "tb_bad_cap.sv"
            bench.write_text(
                f"module tb_bad_cap; pcileech_req_gate #(.N_NP_MAX({cap})) dut(); "
                "initial #1 $finish; endmodule\n"
            )
            out = work / "bad.vvp"
            run(
                [
                    "iverilog",
                    "-g2012",
                    "-I",
                    str(SRC),
                    "-s",
                    "tb_bad_cap",
                    "-o",
                    str(out),
                    *sources[:3],
                    str(bench),
                ]
            )
            result = subprocess.run(
                ["vvp", "-n", str(out)], capture_output=True, text=True, timeout=10
            )
            if (
                result.returncode == 0
                or "requires N_NP_MAX in 1..256" not in result.stdout
            ):
                raise RuntimeError(
                    f"invalid cap {cap} was not rejected: {result.stdout}{result.stderr}"
                )
            print(f"[PASS] rejected N_NP_MAX={cap}")

        tx_obj = work / "tx_obj"
        run(
            [
                "verilator",
                "--binary",
                "--timing",
                "--top-module",
                "tb_req_tx_path",
                "-I" + str(SRC),
                "--Mdir",
                str(tx_obj),
                adapter,
                *sources,
                str(SRC / "pcileech_pcie_a7.sv"),
                str(SRC / "pcileech_pcie_tlp_a7.sv"),
                str(SRC / "pcileech_req_tx_obs.sv"),
                str(SRC / "pcileech_req_rx_cpl.sv"),
                str(SRC / "pcileech_req_err.sv"),
                str(HERE / "tb_req_tx_path.sv"),
            ]
        )
        log = run([str(tx_obj / "Vtb_req_tx_path")], timeout=60)
        if "R1_TB_PASS tb_req_tx_path" not in log or "R1_TB_FAIL" in log:
            raise RuntimeError(log)
        print(log.rstrip())


if __name__ == "__main__":
    main()
