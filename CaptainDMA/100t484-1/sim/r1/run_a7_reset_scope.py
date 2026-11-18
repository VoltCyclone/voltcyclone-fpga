#!/usr/bin/env python3
"""R4: requester reset scope on the production pcileech_pcie_a7.

Simulates pcileech_pcie_a7 in Verilator (tb_a7_reset_scope.sv) with the stubs
of lint_pcie_a7.py, made behavioural where the reset paths need it:
- pcie_7x_0 drives user_clk_out, user_reset_out and user_lnk_up from the bench;
- pcileech_pcie_tlp_a7 reports the TX mux idle one clock after tx_stop;
- xpm_cdc_single / xpm_cdc_async_rst are small synchronizer models, and
  xpm_cdc_handshake is the existing behavioural model.
Then it checks that the bench catches the reset-scope mutants below, each
applied to a temporary copy of pcileech_pcie_a7.sv.
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import lint_pcie_a7  # noqa: E402

SRC = HERE.parents[1] / "src"

XPM_SINGLE = """module xpm_cdc_single #(parameter integer DEST_SYNC_FF=4, INIT_SYNC_FF=0,
    SIM_ASSERT_CHK=0, SRC_INPUT_REG=1)(input src_clk, input src_in, input dest_clk, output dest_out);
    reg s = 1'b0;
    always @(posedge src_clk) s <= src_in;
    wire d = (SRC_INPUT_REG != 0) ? s : src_in;
    reg [DEST_SYNC_FF-1:0] q = '0;
    always @(posedge dest_clk) q <= {q[DEST_SYNC_FF-2:0], d};
    assign dest_out = q[DEST_SYNC_FF-1];
endmodule
"""
XPM_ASYNC_RST = """module xpm_cdc_async_rst #(parameter integer DEST_SYNC_FF=4, INIT_SYNC_FF=0,
    RST_ACTIVE_HIGH=0)(input src_arst, input dest_clk, output dest_arst);
    wire a = (RST_ACTIVE_HIGH != 0) ? src_arst : !src_arst;
    reg [DEST_SYNC_FF-1:0] q = '1;
    always @(posedge dest_clk or posedge a)
        if (a) q <= '1;
        else   q <= {q[DEST_SYNC_FF-2:0], 1'b0};
    assign dest_arst = (RST_ACTIVE_HIGH != 0) ? q[DEST_SYNC_FF-1] : !q[DEST_SYNC_FF-1];
endmodule
"""
CORE_BODY = """    assign user_clk_out   = tb_a7_reset_scope.clk_pcie;
    assign user_reset_out = tb_a7_reset_scope.user_rst;
    assign user_lnk_up    = !tb_a7_reset_scope.user_rst;
"""

# The TX mux is idle one clock after it is told to stop (no packet open).
TLP_BODY = """    reg idle_q = 1'b0;
    always @(posedge clk_pcie) idle_q <= tx_stop;
    assign tx_idle = idle_q;
"""

# (name, [(old, new), ...]); each must fail the bench with its marker.
MUTANTS = [
    ("tracker_on_subsys",
     [("assign rst_req = rst_clkpcie || rst_pcie_user;",
       "assign rst_req = rst_clkpcie || rst_pcie_user || rst_subsys;")], "A7_SCOPE_LEAK"),
    ("table_on_subsys",
     [("    ) i_pcileech_req_table(\n        .clk                        ( clk_pcie                  ),\n"
       "        .rst                        ( rst_req                   ),",
       "    ) i_pcileech_req_table(\n        .clk                        ( clk_pcie                  ),\n"
       "        .rst                        ( rst_req || rst_subsys     ),")], "A7_SCOPE_LEAK req_table"),
    ("dst64_on_subsys",
     [(".rst                        ( rst_clkpcie || rst_pcie_user ),",
       ".rst                        ( rst_clkpcie || rst_pcie_user || rst_subsys ),")], "A7_SCOPE_LEAK dst64"),
    ("src64_on_subsys",
     [("    pcileech_tlps128_src64 i_pcileech_tlps128_src64(\n        .rst                        ( rst_req                   ),",
       "    pcileech_tlps128_src64 i_pcileech_tlps128_src64(\n        .rst                        ( rst_subsys                ),")],
     "A7_SCOPE_LEAK src64"),
    ("tracker_misses_user_reset",
     [("assign rst_req = rst_clkpcie || rst_pcie_user;", "assign rst_req = rst_clkpcie;")], "A7_SCOPE_MISSING"),
]


def sim_stubs() -> str:
    text = lint_pcie_a7.stubs()
    text = re.sub(r"module xpm_cdc_single\b.*?endmodule\n", lambda _: XPM_SINGLE, text, count=1, flags=re.S)
    text = re.sub(r"module xpm_cdc_async_rst\b.*?endmodule\n", lambda _: XPM_ASYNC_RST, text, count=1, flags=re.S)
    text = text.replace((HERE / "xpm_cdc_handshake_bbox.sv").read_text(),
                        (HERE / "xpm_cdc_handshake_model.sv").read_text())
    core = re.search(r"module pcie_7x_0\(.*?\);\n", text, re.S)
    text = text[:core.end()] + CORE_BODY + text[core.end():]
    tlp = re.search(r"module pcileech_pcie_tlp_a7\b.*?\);\n", text, re.S)
    text = text[:tlp.end()] + TLP_BODY + text[tlp.end():]
    return text


def build_and_run(a7: Path, work: Path) -> str:
    stub = work / "stubs.sv"
    stub.write_text(sim_stubs())
    argv = [
        "verilator", "--binary", "--timing", "-Wno-fatal", "-Wno-lint", "-Wno-style",
        "-Wno-MULTIDRIVEN", "--top-module", "tb_a7_reset_scope", "-I" + str(SRC),
        "--Mdir", str(work / "obj"), "-o", "Vtb",
        str(SRC / "pcileech_header.svh"), str(a7),
        *sorted(str(p) for p in SRC.glob("pcileech_req_*.sv")),
        str(SRC / "pcileech_pcie_drp_startup.sv"), str(stub), str(HERE / "tb_a7_reset_scope.sv"),
    ]
    res = subprocess.run(argv, capture_output=True, text=True)
    if res.returncode != 0:
        return "BUILD_FAIL\n" + res.stdout[-3000:] + res.stderr[-3000:]
    res = subprocess.run([str(work / "obj" / "Vtb")], capture_output=True, text=True, timeout=600)
    return res.stdout + res.stderr


def main() -> int:
    if not shutil.which("verilator"):
        print("A7_SCOPE_SKIP verilator not installed")
        return 2
    failures = 0
    with tempfile.TemporaryDirectory(prefix="a7-scope-") as tmp:
        work = Path(tmp) / "base"
        work.mkdir()
        log = build_and_run(SRC / "pcileech_pcie_a7.sv", work)
        ok = "R1_TB_PASS tb_a7_reset_scope" in log and "R1_TB_FAIL" not in log
        failures += not ok
        print(("[PASS] " if ok else "[FAIL] ") + "tb_a7_reset_scope")
        print("\n".join(l for l in log.splitlines() if l.startswith(("R1_TB", "A7_SCOPE", "BUILD", "%Error")))[:4000])
        base = (SRC / "pcileech_pcie_a7.sv").read_text()
        for name, edits, marker in MUTANTS:
            text = base
            for old, new in edits:
                if text.count(old) != 1:
                    raise SystemExit(f"mutant {name}: anchor count {text.count(old)}")
                text = text.replace(old, new)
            work = Path(tmp) / name
            work.mkdir()
            a7 = work / "pcileech_pcie_a7.sv"
            a7.write_text(text)
            log = build_and_run(a7, work)
            killed = "R1_TB_FAIL" in log and marker in log and "BUILD_FAIL" not in log
            failures += not killed
            print(f"{'KILLED' if killed else 'SURVIVED'} {name} ({marker})")
            if not killed:
                print(log[-2000:])
    print(f"A7_SCOPE_{'PASS' if failures == 0 else 'FAIL'}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
