#!/usr/bin/env python3
"""R4: beats past the TX mux at a host subsystem reset, on the production pcileech_pcie_a7.

Simulates pcileech_pcie_a7 in Verilator (tb_a7_tx_beats.sv) with the stubs of
lint_pcie_a7.py, made behavioural as in run_a7_reset_scope.py, except:
- pcie_7x_0 also takes s_axis_tx_tready from the bench and reports a fixed
  bus/device/function and Bus Master Enable;
- pcileech_pcie_tlp_a7 holds the production TX mux (pcileech_tlps128_sink_mux1,
  copied from pcileech_pcie_tlp_a7.sv) fed by four tb_tx_src packet sources.
Then it checks that the bench catches the mutants below.
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
import run_a7_reset_scope as scope  # noqa: E402

SRC = HERE.parents[1] / "src"
TB = "tb_a7_tx_beats"

CORE_BODY = f"""    assign user_clk_out   = {TB}.clk_pcie;
    assign user_reset_out = {TB}.user_rst;
    assign user_lnk_up    = !{TB}.user_rst;
    assign s_axis_tx_tready = {TB}.core_ready;
    assign cfg_bus_number = 8'h03;
    assign cfg_device_number = 5'h00;
    assign cfg_function_number = 3'h0;
    assign cfg_command = 16'h0006;
"""
TLP_BODY = """    IfAXIS128 s1(), s2(), s3(), s4();
    tb_tx_src #(.ID(1)) i_s1(.clk(clk_pcie), .rst(rst), .o(s1.source));
    tb_tx_src #(.ID(2)) i_s2(.clk(clk_pcie), .rst(rst), .o(s2.source));
    tb_tx_src #(.ID(3)) i_s3(.clk(clk_pcie), .rst(rst), .o(s3.source));
    tb_tx_src #(.ID(4)) i_s4(.clk(clk_pcie), .rst(rst), .o(s4.source));
    pcileech_tlps128_sink_mux1 i_pcileech_tlps128_sink_mux1(
        .clk_pcie(clk_pcie), .rst(rst), .stop(tx_stop), .idle(tx_idle),
        .tlps_out(tlps_tx), .tlps_in1(s1.sink), .tlps_in2(s2.sink),
        .tlps_in3(s3.sink), .tlps_in4(s4.sink));
"""

A7 = "pcileech_pcie_a7.sv"
MUX = "mux"
# (name, file, [(old, new), ...], marker)
MUTANTS = [
    # Converter flushed by the host subsystem reset: held beats are lost or cut.
    ("dst64_on_subsys", A7,
     [(".rst                        ( rst_clkpcie || rst_pcie_user ),",
       ".rst                        ( rst_clkpcie || rst_pcie_user || rst_subsys ),")], "A7_TX_"),
    # Gate (and tracker) flushed by the host subsystem reset.
    ("gate_on_subsys", A7,
     [("assign rst_req = rst_clkpcie || rst_pcie_user;",
       "assign rst_req = rst_clkpcie || rst_pcie_user || rst_subsys;")], "A7_TX_"),
    # Drain applies the reset without waiting for the mux to stop.
    ("drain_skips_idle", A7,
     [("if ( idle_sys || pcie_dead ) begin", "if ( 1'b1 ) begin")], "A7_TX_"),
    # Mux keeps selecting new packets while stopped.
    ("mux_ignores_stop", MUX,
     [("? (stop ? 3'd0 : id_next_newsel) : id;", "? id_next_newsel : id;")], "A7_TX_"),
    # Converter requests a beat without a guaranteed slot (overrun on a stall).
    ("dst64_overpull", A7,
     [("assign tlps_in.tready = !rst && (q_count_next <= 1);",
       "assign tlps_in.tready = !rst && (q_count_next <= 2);")], "A7_TX_"),
]


def mux_text(tlp_src: str) -> str:
    m = re.search(r"^module pcileech_tlps128_sink_mux1\b.*?^endmodule\n", tlp_src, re.S | re.M)
    if not m:
        raise SystemExit("pcileech_tlps128_sink_mux1 not found in pcileech_pcie_tlp_a7.sv")
    return m.group(0)


def sim_stubs(mux: str) -> str:
    text = lint_pcie_a7.stubs()
    text = re.sub(r"module xpm_cdc_single\b.*?endmodule\n", lambda _: scope.XPM_SINGLE, text, count=1, flags=re.S)
    text = re.sub(r"module xpm_cdc_async_rst\b.*?endmodule\n", lambda _: scope.XPM_ASYNC_RST, text,
                  count=1, flags=re.S)
    text = text.replace((HERE / "xpm_cdc_handshake_bbox.sv").read_text(),
                        (HERE / "xpm_cdc_handshake_model.sv").read_text())
    core = re.search(r"module pcie_7x_0\(.*?\);\n", text, re.S)
    text = text[:core.end()] + CORE_BODY + text[core.end():]
    tlp = re.search(r"module pcileech_pcie_tlp_a7\b.*?\);\n", text, re.S)
    text = text[:tlp.end()] + TLP_BODY + text[tlp.end():]
    return text + "\n" + mux


def build_and_run(a7: Path, mux: str, work: Path, seed: int) -> str:
    stub = work / "stubs.sv"
    stub.write_text(sim_stubs(mux))
    argv = [
        "verilator", "--binary", "--timing", "-Wno-fatal", "-Wno-lint", "-Wno-style",
        "-Wno-MULTIDRIVEN", "--top-module", TB, "-I" + str(SRC),
        "--Mdir", str(work / "obj"), "-o", "Vtb",
        str(SRC / "pcileech_header.svh"), str(a7),
        *sorted(str(p) for p in SRC.glob("pcileech_req_*.sv")),
        str(SRC / "pcileech_pcie_drp_startup.sv"), str(stub), str(HERE / f"{TB}.sv"),
    ]
    res = subprocess.run(argv, capture_output=True, text=True)
    if res.returncode != 0:
        return "BUILD_FAIL\n" + res.stdout[-3000:] + res.stderr[-3000:]
    res = subprocess.run([str(work / "obj" / "Vtb"), f"+verilator+seed+{seed}"],
                         capture_output=True, text=True, timeout=1200)
    return res.stdout + res.stderr


def summary(log: str) -> str:
    keep = ("R1_TB", "A7_TX", "BUILD", "%Error")
    return "\n".join(l for l in log.splitlines() if l.startswith(keep))[:4000]


def main() -> int:
    if not shutil.which("verilator"):
        print("A7_TX_SKIP verilator not installed")
        return 2
    seeds = [int(s) for s in sys.argv[1:]] or [1, 2, 3]
    base_a7 = (SRC / A7).read_text()
    base_mux = mux_text((SRC / "pcileech_pcie_tlp_a7.sv").read_text())
    failures = 0
    with tempfile.TemporaryDirectory(prefix="a7-txb-") as tmp:
        for seed in seeds:
            work = Path(tmp) / f"base-{seed}"
            work.mkdir()
            log = build_and_run(SRC / A7, base_mux, work, seed)
            ok = f"R1_TB_PASS {TB}" in log and "R1_TB_FAIL" not in log
            failures += not ok
            print(("[PASS] " if ok else "[FAIL] ") + f"{TB} seed={seed}")
            print(summary(log))
        for name, target, edits, marker in MUTANTS:
            a7_text, mux = base_a7, base_mux
            for old, new in edits:
                text = mux if target == MUX else a7_text
                if text.count(old) != 1:
                    raise SystemExit(f"mutant {name}: anchor count {text.count(old)}")
                if target == MUX:
                    mux = text.replace(old, new)
                else:
                    a7_text = text.replace(old, new)
            work = Path(tmp) / name
            work.mkdir()
            a7 = work / A7
            a7.write_text(a7_text)
            log = build_and_run(a7, mux, work, seeds[0])
            killed = "R1_TB_FAIL" in log and marker in log and "BUILD_FAIL" not in log
            failures += not killed
            first = next((l for l in log.splitlines() if l.startswith("A7_TX_ERR")), "")
            print(f"{'KILLED' if killed else 'SURVIVED'} {name}: {first[:200]}")
            if not killed:
                print(summary(log)[-2000:])
    print(f"A7_TX_{'PASS' if failures == 0 else 'FAIL'}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
