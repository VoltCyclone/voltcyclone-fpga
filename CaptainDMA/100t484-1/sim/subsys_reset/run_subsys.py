#!/usr/bin/env python3
"""Run the PCIe subsystem FIFO reset bench with exported Vivado FIFO models."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODELS = (
    "fifo_64_64",
    "fifo_32_32_clk2",
    "fifo_49_49_clk2",
    "fifo_43_43_clk2",
    "fifo_134_134_clk2",
    "fifo_134_134_clk2_rxfifo",
    "fifo_1_1_clk2",
    "fifo_129_129_clk1",
    "bram_pcie_cfgspace",
    "drom_pcie_cfgspace_writemask",
)
SOURCES = (
    "pcileech_header.svh",
    "pcileech_req_defs.svh",
    "pcileech_pcie_a7.sv",
    "pcileech_pcie_cfg_a7.sv",
    "pcileech_pcie_tlp_a7.sv",
    "pcileech_tlps128_cfgspace_shadow.sv",
    "pcileech_com.sv",
)
# name: (file, [(old, new), ...], case, expected error marker)
A7 = "pcileech_pcie_a7.sv"
CFG = "pcileech_pcie_cfg_a7.sv"
SHD = "pcileech_tlps128_cfgspace_shadow.sv"
SEQ_OUT = (".fifo_rst           ( rst_subsys_fifo       ),", ".fifo_rst           ( ),")
MUTANTS: dict[str, tuple[str, list[tuple[str, str]], int, str]] = {
    # FIFO reset pin follows the request again (no sequencer): adjacent resets.
    "fifo_rst_follows_request": (A7, [SEQ_OUT, ("    wire fifo_done;\n",
        "    wire fifo_done;\n    assign rst_subsys_fifo = subsys_req;\n")], 2, "SUBSYS_RST_GAP"),
    # No FIFO reset at all: data from before the reset survives it.
    "no_fifo_reset": (A7, [SEQ_OUT, ("    wire fifo_done;\n",
        "    wire fifo_done;\n    assign rst_subsys_fifo = 1'b0;\n")], 0, "_STALE"),
    # Quarantine released with the request, before the FIFO sequence is done.
    "quarantine_ignores_sequence": (A7, [("rst_subsys_sys <= subsys_req_d || subsys_req || !fifo_done;",
        "rst_subsys_sys <= subsys_req_d;")], 0, "SUBSYS_NOACCESS"),
    # Request without the clk_pcie round trip. Release order still holds (the
    # sequencer's clk_pcie half stays reset by rst_subsys_pcie_q, so it cannot
    # finish first; SUBSYS_RELEASE_ORDER does not fire), but core user resets
    # no longer reset the FIFOs and host TX packets are lost.
    "release_before_pcie": (A7, [("wire subsys_req_d = rst || pcie_rst_subsys || rst_subsys_pcie_sys;",
        "wire subsys_req_d = rst || pcie_rst_subsys;")], 0, "SUBSYS_A_LOST"),
    # Soft reset applied at once, without stopping TX: packets are cut.
    "drain_no_stop": (A7, [("state    <= pcie_dead ? S_APPLY : S_STOP;", "state    <= S_APPLY;"),
        ("soft_rst <= pcie_dead;", "soft_rst <= 1'b1;")], 3, "SUBSYS_TX_CUT"),
    # Mux keeps selecting new packets while stopped.
    "mux_ignores_stop": ("pcileech_pcie_tlp_a7.sv", [("? (stop ? 3'd0 : id_next_newsel) : id;",
        "? id_next_newsel : id;")], 3, "SUBSYS_TX_"),
    # Drain applies the reset as soon as stop is raised.
    "drain_skips_idle": (A7, [("if ( idle_sys || pcie_dead ) begin", "if ( 1'b1 ) begin")], 3, "SUBSYS_DRAIN_FALSE_DEAD"),
    # Old static TLP end: has_data stays up at the last beat and the packet
    # ends only on its second half, so the mux re-selects and waits.
    "static_old_end": (CFG, [("rwi_tlp_static_has_data && !(rwi_tlp_static_valid && tlps_static.tlast);",
        "rwi_tlp_static_has_data;"),
        ("if ( rwi_tlp_static_valid && tlps_static.tlast ) begin    // STATE (3)",
         "if ( (rwi_tlp_static_valid && rwi_tlp_static_2nd) || ~rw[RWPOS_CFG_STATIC_TLP_TX_EN] ) begin")], 4, "SUBSYS_FAIL"),
    # Old static TLP disable: withdraw an armed packet when TX_EN clears
    # (also right after arming the last of COUNT).
    "static_withdraw_on_disable": (CFG, [("if ( rwi_tlp_static_valid && tlps_static.tlast ) begin    // STATE (3)",
        "if ( (rwi_tlp_static_valid && tlps_static.tlast) || ~rw[RWPOS_CFG_STATIC_TLP_TX_EN] ) begin")], 4, "SUBSYS_FAIL"),
    # Arm a static TLP without checking its second beat.
    "static_arm_unchecked": (CFG, [("& rwi_tlp_static_wellformed ) begin", "& rw[224+2*0] ) begin")], 4, "SUBSYS_STATIC_MALFORMED_SENT"),
    # Old arming and tvalid gated by the DW0 valid bit: the malformed packet
    # is armed, its second beat never has tvalid, and the mux waits forever.
    "static_old_valid": (CFG, [("& rwi_tlp_static_wellformed ) begin", "& rw[224+2*0] ) begin"),
        ("assign tlps_static.tvalid               = rwi_tlp_static_valid;",
         "assign tlps_static.tvalid               = rwi_tlp_static_valid && rw[224+2*(rwi_tlp_static_2nd ? 4 : 0)];")], 4, "SUBSYS_FAIL"),
    # Host request with clk_pcie dead waits for the clock.
    "drain_ignores_dead_clock": (A7, [("pcie_dead <= (pcie_tog_sys == pcie_tog_q) && (quiet >= 7'(DEAD_CYCLES - 1));",
        "pcie_dead <= 1'b0;")], 1, "SUBSYS_DRAIN_EXPECT_DEAD"),
    "cfg_tx_write_ungated": (CFG, [(".wr_en          ( dfifo.tx_valid && acc_sys ),",
        ".wr_en          ( dfifo.tx_valid ),")], 0, "SUBSYS_NOACCESS cfg_tx"),
    "cfg_rx_read_ungated": (CFG, [(".rd_en          ( dfifo.rx_rd_en && acc_sys ),",
        ".rd_en          ( dfifo.rx_rd_en ),")], 0, "SUBSYS_NOACCESS cfg_rx"),
    "shd_req_read_always": (SHD, [(".rd_en          ( acc_pcie                  ),",
        ".rd_en          ( 1'b1                      ),")], 0, "SUBSYS_NOACCESS shd_req"),
}
# Equivalent, not run: ungating the shadow reply write (bram_rd_tp == USB).
# Those writes come only from shadow request reads, which are gated by
# acc_pcie; the two-cycle BRAM pipeline drains before the sequencer can raise
# the FIFO reset (>= 6 cycles of LOW_GAP), and anything written meanwhile is
# flushed by that reset. The gate stays for symmetry.
# Equivalent, not run: dropping the subsys_req term from rst_subsys_sys. Every
# reset source also raises rst_subsys_req, which asserts rst_subsys_pcie_sys
# (and so subsys_req_d) asynchronously in the next cycle, so a one-cycle
# request never leaves the cycle before the sequencer clears done uncovered.
# The term and the SUBSYS_QUAR_EARLY check stay as defence.


def run(argv, work: Path, name: str, expect: str | None = None) -> str:
    """Run one tool stage; grade the log as well as the exit status."""
    with (work / f"{name}.log").open("w") as log:
        result = subprocess.run(
            [str(x) for x in argv], cwd=work, stdout=log, stderr=subprocess.STDOUT, timeout=1800
        )
    out = (work / f"{name}.log").read_text(errors="replace")
    if expect is not None:
        if re.search(r"(?m)^ERROR:", out) or expect not in out or "SUBSYS_PASS" in out:
            raise RuntimeError(f"{name}: mutant survived or failed wrongly\n{out[-5000:]}")
        print(f"SUBSYS_MUTANT_KILLED {name} ({expect})", flush=True)
        return out
    bad = re.search(r"(?m)^(?:ERROR:|FATAL_ERROR:|Fatal:)|SUBSYS_ERR|SUBSYS_FAIL", out)
    if result.returncode or bad or (name.startswith("case") and "SUBSYS_PASS" not in out):
        raise RuntimeError(f"{name} failed rc={result.returncode}\n{out[-8000:]}")
    print(f"SUBSYS_STAGE_PASS {name}", flush=True)
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--vivado", type=Path, required=True)
    ap.add_argument("--board", type=Path, required=True)
    ap.add_argument("--models", type=Path, required=True, help="export-models.tcl output")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--case", type=int, choices=(0, 1, 2, 3, 4))
    ap.add_argument("--matrix", action="store_true", help="three clock rate/phase settings")
    ap.add_argument("--keep-going", action="store_true", help="report every case, then fail")
    ap.add_argument("--mutant", choices=tuple(MUTANTS))
    args = ap.parse_args()

    work = args.out.resolve()
    work.mkdir(parents=True, exist_ok=False)
    src = work / "src"
    src.mkdir()
    for name in SOURCES:
        shutil.copy2(args.board / "src" / name, src / name)
    # XSim cannot index a concatenation ({v}[7:0]). Every use in the staged
    # sources passes a plain identifier (pcie_id), so v[7:0] is equivalent.
    hdr = src / "pcileech_header.svh"
    old_bs = "`define _bs16(v)   {{v}[7:0], {v}[15:8]}"
    if hdr.read_text().count(old_bs) != 1:
        raise ValueError("_bs16 macro changed; review the XSim rewrite")
    hdr.write_text(hdr.read_text().replace(old_bs, "`define _bs16(v)   {v[7:0], v[15:8]}"))
    if args.mutant:
        fname, edits, _case, _marker = MUTANTS[args.mutant]
        text = (src / fname).read_text()
        for old, new in edits:
            if text.count(old) != 1:
                raise ValueError(f"mutant {args.mutant}: anchor count {text.count(old)}")
            text = text.replace(old, new)
        (src / fname).write_text(text)
    bench = src / "tb_subsys_vendor.sv"
    shutil.copy2(HERE / bench.name, bench)
    models = []
    for name in MODELS:
        shutil.copy2(args.models / f"{name}.v", src / f"{name}.v")
        models.append(src / f"{name}.v")
    manifest = {
        str(p.relative_to(work)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(src.iterdir())
    }
    ck = args.models / "checkpoint-sha256.txt"
    if ck.exists():
        manifest["checkpoints"] = ck.read_text().splitlines()
    (work / "source-sha256.json").write_text(json.dumps(manifest, indent=2) + "\n")

    vbin = args.vivado / "bin"
    run([vbin / "xvlog", "--sv", "-i", src, args.vivado / "data/verilog/src/glbl.v", *models,
         *[src / n for n in SOURCES if n.endswith(".sv")], bench], work, "compile")
    run([vbin / "xelab", "-mt", "4", "-L", "xpm", "-L", "unisims_ver", "-L", "unimacro_ver",
         "work.tb_subsys_vendor", "work.glbl", "-s", "subsys"], work, "elaborate")

    cases = [MUTANTS[args.mutant][2]] if args.mutant else ([args.case] if args.case is not None else [0, 1, 2, 3, 4])
    clocks = [(5.0, 8.0, 1.3)]
    if args.matrix or args.mutant:
        clocks += [(5.0, 4.0, 2.7), (5.0, 6.0, 0.9)]   # clk_pcie 125 MHz, 83 MHz
    if args.mutant:
        # A mutant is killed if any clock setting catches it.
        case = cases[0]
        for ci, (sh, ph, phase) in enumerate(clocks):
            argv = [vbin / "xsim", "subsys", "-runall"]
            for a in (f"CASE={case}", f"SYS_HALF={sh}", f"PCIE_HALF={ph}", f"PHASE={phase}", f"SEED={11 + ci}"):
                argv += ["-testplusarg", a]
            try:
                run(argv, work, f"case-{case}-clock-{ci}", expect=MUTANTS[args.mutant][3])
                print(f"SUBSYS_RUN_PASS mutant={args.mutant}", flush=True)
                return
            except RuntimeError:
                print(f"SUBSYS_MUTANT_SURVIVED_CLOCK {ci}", flush=True)
        raise SystemExit(f"SUBSYS_MUTANT_SURVIVED {args.mutant}")
    failed = []
    for ci, (sh, ph, phase) in enumerate(clocks):
        for case in cases:
            argv = [vbin / "xsim", "subsys", "-runall"]
            for a in (f"CASE={case}", f"SYS_HALF={sh}", f"PCIE_HALF={ph}", f"PHASE={phase}", f"SEED={11 + ci}"):
                argv += ["-testplusarg", a]
            name = f"case-{case}-clock-{ci}"
            try:
                run(argv, work, name)
            except RuntimeError as exc:
                if not args.keep_going:
                    raise
                failed.append(name)
                print(f"SUBSYS_CASE_FAIL {name}\n{str(exc)[-3000:]}", flush=True)
    if failed:
        raise SystemExit(f"SUBSYS_RUN_FAIL {failed}")
    print(f"SUBSYS_RUN_PASS cases={len(cases) * len(clocks)} mutant={args.mutant}", flush=True)


if __name__ == "__main__":
    main()
