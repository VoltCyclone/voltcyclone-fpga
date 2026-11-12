#!/usr/bin/env python3
"""Verilator lint of the integrated pcileech_pcie_a7 (R1 board wiring).

The PCIe core, XPM macros and IBUFDS are vendor primitives, and the unchanged
pcileech_pcie_tlp_a7/pcileech_pcie_cfg_a7 pull in vendor FIFO/BRAM IP, so they
are replaced by port-only stubs:
- pcie_7x_0: ports, directions and widths from the `// <- [w]` / `// ->`
  comments on its instance in pcileech_pcie_a7.sv (every port must have one);
- tlp_a7/cfg_a7: their exact module headers with empty bodies.
Fails on any Verilator error or on width/pin/driver warnings. Style warnings
from pre-existing code (PROCASSINIT, DECLFILENAME, ...) and warnings caused by
stubbing (undriven interface members) are not gating.
Plan generics are test fixtures only; production binds the generated plan.
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE.parents[1] / "src"
GATING = re.compile(
    r"^%(Error|Warning-(WIDTH\w*|PINNOTFOUND|PINMISSING|MULTIDRIVEN|IMPLICIT|"
    r"SELRANGE|LATCH|COMBDLY|BLKANDNBLK|CASEINCOMPLETE))"
)


def stubs() -> str:
    parts = [
        "/* verilator lint_off UNUSEDSIGNAL */\n/* verilator lint_off UNDRIVEN */\n"
        "/* verilator lint_off UNUSEDPARAM */\n/* verilator lint_off DECLFILENAME */\n"
    ]
    for name in ("pcileech_pcie_tlp_a7", "pcileech_pcie_cfg_a7"):
        text = (SRC / f"{name}.sv").read_text()
        header = re.search(r"module\s+" + name + r"\s*(#\s*\(.*?\)\s*)?\(.*?\);", text, re.S)
        parts.append(header.group(0) + "\nendmodule\n")
    a7 = (SRC / "pcileech_pcie_a7.sv").read_text()
    inst = a7[a7.index("pcie_7x_0 i_pcie_7x_0"):]
    inst = inst[: inst.index("\n    );")]
    ports = []
    for line in inst.splitlines():
        if not re.match(r"\s*\.\w+\s*\(", line):
            continue
        m = re.match(r"\s*\.(\w+)\s*\(.*\)\s*,?\s*//\s*(<-|->)\s*(\[\d+:0\])?", line)
        if not m:
            raise SystemExit("pcie_7x_0 port without a direction comment: " + line.strip())
        direction = "input" if m.group(2) == "<-" else "output"
        ports.append(f"    {direction} {m.group(3) or ''} {m.group(1)}")
    parts.append("module pcie_7x_0(\n" + ",\n".join(ports) + "\n);\nendmodule\n")
    parts.append("module IBUFDS_GTE2(output O, output ODIV2, input I, input IB, input CEB);\nendmodule\n")
    parts.append(
        "module xpm_cdc_single #(parameter integer DEST_SYNC_FF=4, INIT_SYNC_FF=0, "
        "SIM_ASSERT_CHK=0, SRC_INPUT_REG=1)(input src_clk, input src_in, input dest_clk, "
        "output dest_out);\nendmodule\n"
    )
    parts.append(
        "module xpm_cdc_async_rst #(parameter integer DEST_SYNC_FF=4, INIT_SYNC_FF=0, "
        "RST_ACTIVE_HIGH=0)(input src_arst, input dest_clk, output dest_arst);\nendmodule\n"
    )
    parts.append((HERE / "xpm_cdc_handshake_bbox.sv").read_text())
    return "".join(parts)


def main() -> int:
    if not shutil.which("verilator"):
        print("A7_LINT_SKIP verilator not installed")
        return 2
    with tempfile.TemporaryDirectory(prefix="a7-lint-") as tmp:
        stub = Path(tmp) / "stubs.sv"
        stub.write_text(stubs())
        argv = [
            "verilator", "--lint-only", "-Wall", "-Wno-fatal",
            "--top-module", "pcileech_pcie_a7", "-I" + str(SRC),
            "-GREQ_N_NP_MAX=36", "-GDRP_PLAN_BOUND=1", "-GDRP_PLAN_MASK=16'h00f0",
            "-GDRP_PLAN_VALUE=16'h0050", "-GDRP_RDY_TIMEOUT_CYCLES=64",
            str(SRC / "pcileech_header.svh"), str(SRC / "pcileech_pcie_a7.sv"),
            *sorted(str(p) for p in SRC.glob("pcileech_req_*.sv")),
            str(SRC / "pcileech_pcie_drp_startup.sv"), str(stub),
        ]
        res = subprocess.run(argv, capture_output=True, text=True)
    out = res.stdout + res.stderr
    gating = [line for line in out.splitlines() if GATING.match(line)]
    for line in gating:
        print(line)
    ok = not gating and "%Error" not in out
    print(f"A7_LINT_{'PASS' if ok else 'FAIL'} gating={len(gating)}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
