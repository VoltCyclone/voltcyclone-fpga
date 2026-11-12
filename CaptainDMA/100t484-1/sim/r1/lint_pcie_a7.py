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

Also checks the requester clock binding (review F2): for each supported
REQ_CLK_PCIE_HZ the value must reach i_pcileech_req_table.CLK_PCIE_HZ
(read from Verilator's JSON elaboration dump), and an absent or unsupported
value must stop elaboration.
"""
import json
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
    r"SELRANGE|LATCH|COMBDLY|BLKANDNBLK|CASEINCOMPLETE|USERFATAL))"
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
    # Wrapper so Verilator can fully elaborate (interface ports cannot sit on
    # the top module); used only for the JSON parameter dump.
    parts.append(
        "module a7_elab_top #(parameter longint REQ_CLK_PCIE_HZ = 0) (\n"
        "    input clk_sys, input rst, output [0:0] pcie_tx_p, output [0:0] pcie_tx_n,\n"
        "    input [0:0] pcie_rx_p, input [0:0] pcie_rx_n, input pcie_clk_p, input pcie_clk_n,\n"
        "    input pcie_perst_n, output led_state);\n"
        "    IfPCIeFifoCfg dfifo_cfg(); IfPCIeFifoTlp dfifo_tlp(); IfPCIeFifoCore dfifo_pcie();\n"
        "    IfShadow2Fifo dshadow2fifo();\n"
        "    pcileech_pcie_a7 #(.REQ_N_NP_MAX(36), .REQ_CLK_PCIE_HZ(REQ_CLK_PCIE_HZ),\n"
        "        .DRP_PLAN_BOUND(1), .DRP_PLAN_MASK(16'h00f0), .DRP_PLAN_VALUE(16'h0050),\n"
        "        .DRP_PLAN_CHECK_MASK(16'h0f00), .DRP_PLAN_BASE_EXPECT(16'h0200),\n"
        "        .DRP_RDY_TIMEOUT_CYCLES(64)) dut(.*);\n"
        "endmodule\n"
    )
    return "".join(parts)


def table_clock(node):
    """CLK_PCIE_HZ of the elaborated pcileech_req_table, from the JSON dump."""
    found = []

    def walk(n, module=None):
        if isinstance(n, dict):
            if n.get("type") == "MODULE":
                module = n.get("origName") or n.get("name") or ""
            if (module and module.startswith("pcileech_req_table") and n.get("type") == "VAR"
                    and n.get("name") == "CLK_PCIE_HZ" and n.get("valuep")):
                found.append(n["valuep"][0]["name"])
            for v in n.values():
                walk(v, module)
        elif isinstance(n, list):
            for v in n:
                walk(v, module)

    walk(node)
    return found


def main() -> int:
    if not shutil.which("verilator"):
        print("A7_LINT_SKIP verilator not installed")
        return 2
    failures = 0
    with tempfile.TemporaryDirectory(prefix="a7-lint-") as tmp:
        stub = Path(tmp) / "stubs.sv"
        stub.write_text(stubs())
        base = [
            "--top-module", "pcileech_pcie_a7", "-I" + str(SRC),
            "-GREQ_N_NP_MAX=36", "-GDRP_PLAN_BOUND=1", "-GDRP_PLAN_MASK=16'h00f0",
            "-GDRP_PLAN_VALUE=16'h0050", "-GDRP_PLAN_CHECK_MASK=16'h0f00",
            "-GDRP_PLAN_BASE_EXPECT=16'h0200", "-GDRP_RDY_TIMEOUT_CYCLES=64",
            str(SRC / "pcileech_header.svh"), str(SRC / "pcileech_pcie_a7.sv"),
            *sorted(str(p) for p in SRC.glob("pcileech_req_*.sv")),
            str(SRC / "pcileech_pcie_drp_startup.sv"), str(stub),
        ]
        for hz in (62_500_000, 125_000_000):
            res = subprocess.run(
                ["verilator", "--lint-only", "-Wall", "-Wno-fatal", f"-GREQ_CLK_PCIE_HZ=64'd{hz}", *base],
                capture_output=True, text=True)
            out = res.stdout + res.stderr
            gating = [line for line in out.splitlines() if GATING.match(line)]
            for line in gating:
                print(line)
            dump = Path(tmp) / f"a7-{hz}.json"
            elab = [a for a in base if a != "--top-module" and a != "pcileech_pcie_a7"
                    and not a.startswith("-GREQ_N_NP_MAX") and not a.startswith("-GDRP_")]
            subprocess.run(
                ["verilator", "--json-only", "--json-only-output", str(dump), "-Wno-fatal",
                 "--Mdir", str(Path(tmp) / f"obj-{hz}"),
                 "--top-module", "a7_elab_top", f"-GREQ_CLK_PCIE_HZ=64'd{hz}", *elab],
                capture_output=True, text=True)
            values = table_clock(json.loads(dump.read_text())) if dump.exists() else []
            bound = len(values) == 1 and int(values[0].split("'h")[1], 16) == hz
            ok = not gating and "%Error" not in out and bound
            failures += not ok
            print(f"A7_LINT_{'PASS' if ok else 'FAIL'} hz={hz} gating={len(gating)} table_clk={values}")
        for label, extra in (("unbound", []), ("unsupported", ["-GREQ_CLK_PCIE_HZ=100000000"])):
            res = subprocess.run(["verilator", "--lint-only", "-Wno-fatal", *extra, *base],
                                 capture_output=True, text=True)
            rejected = "REQ_CLK_PCIE_HZ must be bound" in res.stdout + res.stderr
            failures += not rejected
            print(f"A7_CLOCK_{'REJECTED' if rejected else 'ACCEPTED_FAIL'} {label}")
    print(f"A7_LINT_{'PASS' if failures == 0 else 'FAIL'}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
