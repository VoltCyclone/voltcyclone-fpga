#!/usr/bin/env python3
"""FT601 MMCM PHY bench runner and mutation campaign (Icarus Verilog).

Runs tb_ft601_phy against pcileech_ft601_phy at the datasheet output-delay
corners (FT601 TCO 3.5..7.0 ns), with several seeds and every scenario, and
tb_ft601_clk against the clock/reset controller. Then applies each mutant to a
temporary copy of the RTL and requires at least one run to fail. Mutants that
do not compile are reported as bad and count as survivors. The working RTL is
never changed.

Prints FT601_RUN_PASS / FT601_RUN_FAIL and FT601_MUT killed=<n> total=<n>.
"""

import itertools
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
RTL = HERE.parent.parent / "src" / "pcileech_ft601_phy.sv"
CLK_RTL = HERE.parent.parent / "src" / "pcileech_ft601_clk.sv"
BENCH = ["tb_ft601_phy.sv", "ft601_model.sv", "prims_model.sv"]

# (TCO_MIN, TCO_MAX, T_HIZ) in ns.
CORNERS = [(3.5, 7.0, 6.0), (3.5, 3.5, 6.0), (7.0, 7.0, 6.0), (3.5, 7.0, 25.0)]
SCENARIOS = [0, 1, 2, 3]
SEEDS = [1, 7, 42]

# Clock/reset controller mutants, run against tb_ft601_clk.
CLK_MUTANTS = [
    ("clk_no_second_reset",
     "if ( clk_ok && seen_lock ) begin",
     "if ( clk_ok ) begin"),
    ("clk_ready_ignores_loss",
     "                if ( !clk_ok ) begin\n                    seen_lock     <= 1'b0;",
     "                if ( 1'b0 ) begin\n                    seen_lock     <= 1'b0;"),
    ("clk_ignores_clkinstopped",
     "wire clk_ok = locked_s[2] && !stopped_s[2];",
     "wire clk_ok = locked_s[2];"),
]

# (name, original text, replacement). Each original must occur exactly once.
MUTANTS = [
    ("rx_valid_unaligned",
     "dout_valid <= !rst && !in_rxf_n && !rd_d1;",
     "dout_valid <= !rst && !in_rxf_n && !o_rd_n;"),
    ("rx_valid_from_state",
     "dout_valid <= !rst && !in_rxf_n && !rd_d1;",
     "dout_valid <= !rst && !in_rxf_n && (state == S_RX);"),
    ("tx_accept_unaligned",
     "wire tx_accept = !wr_d1 && !in_txe_n;\n    wire tx_refuse = !wr_d1 &&  in_txe_n;",
     "wire tx_accept = !o_wr_n && !in_txe_n;\n    wire tx_refuse = !o_wr_n &&  in_txe_n;"),
    ("tx_no_rewind",
     "ip         <= ( tx_refuse || tx_refused ) ? ap : ip;",
     "ip         <= ip;"),
    ("tx_ignore_refusal",
     "if ( tx_refuse || tx_refused || !q_unissued )\n                        state <= S_TX_END;",
     "if ( !q_unissued )\n                        state <= S_TX_END;"),
    ("tx_no_drain",
     "if ( tx_refuse || tx_refused || !q_unissued )\n                        state <= S_TX_END;",
     "if ( tx_refuse || tx_refused || !q_unissued ) begin\n"
     "                        ip <= ( tx_refuse || tx_refused ) ? ap : ip;\n"
     "                        tx_refused <= 1'b0;\n"
     "                        state <= S_IDLE;\n"
     "                    end"),
    ("guard_one_cycle",
     "else if ( guard_cnt == 4'(GUARD_CYCLES - 1) ) begin",
     "else if ( guard_cnt == 0 ) begin"),
    ("rd_with_oe",
     "o_oe_n <= 1'b0;\n                    state  <= S_RX_OE;\n                end\n                S_RX_OE",
     "o_oe_n <= 1'b0;\n                    o_rd_n <= 1'b0;\n                    state  <= S_RX;\n                end\n                S_RX_OE"),
    ("din_req_unbounded",
     "assign din_req_data = !rst && (q_used <= 12);",
     "assign din_req_data = !rst;"),
    ("oe_pad_sync_reset",
     ".PRE ( rst_c180 ), .D ( o_oe_n ), .Q ( FT601_OE_N ) );",
     ".PRE ( 1'b0 ), .D ( o_oe_n ), .Q ( FT601_OE_N ) );"),
    ("rx_no_byteswap",
     "dout       <= {in_d[7:0], in_d[15:8], in_d[23:16], in_d[31:24]};",
     "dout       <= in_d;"),
]


class CompileError(Exception):
    pass


def run_one(rtl: Path, work: Path, corner, scen: int, seed: int) -> bool:
    tco_min, tco_max, thiz = corner
    vvp = work / "tb.vvp"
    cmd = [
        "iverilog", "-g2012",
        f"-DTCO_MIN_NS={tco_min}", f"-DTCO_MAX_NS={tco_max}", f"-DT_HIZ_NS={thiz}",
        "-o", str(vvp), *[str(HERE / f) for f in BENCH], str(rtl),
    ]
    comp = subprocess.run(cmd, capture_output=True, text=True)
    if comp.returncode != 0:
        raise CompileError(comp.stdout + comp.stderr)
    sim = subprocess.run(["vvp", "-n", str(vvp), f"+SCEN={scen}", f"+SEED={seed}"],
                         capture_output=True, text=True, timeout=600)
    out = sim.stdout + sim.stderr
    errors = [ln for ln in out.splitlines() if "ERROR" in ln or "Assert" in ln]
    return sim.returncode == 0 and "FT601_TB_PASS" in out and not errors


def matrix(rtl: Path, work: Path, stop_on_fail: bool):
    failed = []
    for corner, scen, seed in itertools.product(CORNERS, SCENARIOS, SEEDS):
        if not run_one(rtl, work, corner, scen, seed):
            failed.append((corner, scen, seed))
            if stop_on_fail:
                break
    return failed


def run_clk(rtl: Path, work: Path) -> bool:
    vvp = work / "clk.vvp"
    comp = subprocess.run(["iverilog", "-g2012", "-o", str(vvp), str(HERE / "tb_ft601_clk.sv"),
                           str(HERE / "prims_model.sv"), str(rtl)], capture_output=True, text=True)
    if comp.returncode != 0:
        raise CompileError(comp.stdout + comp.stderr)
    sim = subprocess.run(["vvp", "-n", str(vvp)], capture_output=True, text=True, timeout=600)
    out = sim.stdout + sim.stderr
    return sim.returncode == 0 and "FT601_CLK_PASS" in out and "ERROR" not in out


def campaign(src: str, mutants, work: Path, name: str, check) -> int:
    killed = 0
    for mname, old, new in mutants:
        if src.count(old) != 1:
            print(f"FT601_MUT_BAD {mname}: original text found {src.count(old)} times")
            continue
        mut = work / name
        mut.write_text(src.replace(old, new))
        try:
            dead = check(mut)
        except CompileError as exc:
            print(f"FT601_MUT_BAD {mname}: does not compile\n{exc}")
            continue
        killed += dead
        print(f"FT601_MUT_{'KILLED' if dead else 'SURVIVED'} {mname}")
    return killed


def main() -> int:
    if not (shutil.which("iverilog") and shutil.which("vvp")):
        print("FT601_RUN_SKIP iverilog/vvp not installed")
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        failed = matrix(RTL, work, stop_on_fail=False)
        total = len(CORNERS) * len(SCENARIOS) * len(SEEDS)
        if failed:
            for f in failed:
                print(f"FT601_RUN_FAIL corner={f[0]} scen={f[1]} seed={f[2]}")
            return 1
        print(f"FT601_RUN_PASS runs={total}")

        if not run_clk(CLK_RTL, work):
            print("FT601_RUN_FAIL tb_ft601_clk")
            return 1
        print("FT601_RUN_PASS tb_ft601_clk")

        killed = campaign(RTL.read_text(), MUTANTS, work, "pcileech_ft601_phy.sv",
                          lambda m: bool(matrix(m, work, stop_on_fail=True)))
        killed += campaign(CLK_RTL.read_text(), CLK_MUTANTS, work, "pcileech_ft601_clk.sv",
                           lambda m: not run_clk(m, work))
        total = len(MUTANTS) + len(CLK_MUTANTS)
        print(f"FT601_MUT killed={killed} total={total}")
        return 0 if killed == total else 1


if __name__ == "__main__":
    sys.exit(main())
