#!/usr/bin/env python3
"""Run the gate and requester TX path with their real SystemVerilog interfaces.

The ordinary R1 runner uses Icarus (which cannot elaborate these modports).
This command also lints the adapter with -Wall and checks runtime NP-cap refusals.
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
        if "R1_TB_PASS tb_req_gate" not in log or "R1_TB_FAIL" in log or "\nERROR: " in "\n" + log:
            raise RuntimeError(log)
        print("[PASS] IfAXIS128 adapter lint and scoreboard")
        print(log.rstrip())

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
        if "R1_TB_PASS tb_req_tx_path" not in log or "R1_TB_FAIL" in log or "\nERROR: " in "\n" + log:
            raise RuntimeError(log)
        print(log.rstrip())

        # Review F1: subsystem reset on the RX path. The bench reproduces the
        # board RX chain; first confirm the board really wires src64 to the
        # link-session reset, then require the board wiring to pass and the
        # reviewed wiring (src64 on the subsystem reset) to fail.
        a7 = (SRC / "pcileech_pcie_a7.sv").read_text()
        src64_inst = a7[a7.index("pcileech_tlps128_src64 i_pcileech_tlps128_src64("):]
        src64_inst = src64_inst[: src64_inst.index(");")]
        if "( rst_req" not in src64_inst:
            raise RuntimeError("pcileech_pcie_a7 src64 is not on rst_req:\n" + src64_inst)
        for old_wiring in (0, 1):
            obj = work / f"rx_reset_obj{old_wiring}"
            run(
                [
                    "verilator", "--binary", "--timing", "-Wno-fatal", "-Wno-lint", "-Wno-style",
                    "--top-module", "tb_rx_subsys_reset", f"-GOLD_WIRING={old_wiring}",
                    "-I" + str(SRC), "--Mdir", str(obj),
                    str(SRC / "pcileech_pcie_a7.sv"), str(SRC / "pcileech_pcie_tlp_a7.sv"),
                    str(SRC / "pcileech_req_rx_cpl.sv"), str(SRC / "pcileech_req_table.sv"),
                    str(SRC / "pcileech_req_cto_limits.sv"), str(HERE / "tb_rx_subsys_reset.sv"),
                ]
            )
            log = run([str(obj / "Vtb_rx_subsys_reset")], timeout=120)
            passed = "R1_TB_PASS tb_rx_subsys_reset" in log and "R1_TB_FAIL" not in log and "\nERROR: " not in "\n" + log
            if passed != (old_wiring == 0):
                raise RuntimeError(f"tb_rx_subsys_reset OLD_WIRING={old_wiring} unexpected:\n{log}")
            print(f"[PASS] tb_rx_subsys_reset OLD_WIRING={old_wiring} "
                  + ("passes" if passed else "fails as expected (control)"))


if __name__ == "__main__":
    main()
