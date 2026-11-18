#!/usr/bin/env python3
"""Run the whole-packet capacity bench (R3) with exported Vivado FIFO models."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODELS = ("fifo_134_134_clk2", "fifo_134_134_clk2_rxfifo", "fifo_1_1_clk2")
SOURCES = ("pcileech_header.svh", "pcileech_pcie_tlp_a7.sv")
TLP = "pcileech_pcie_tlp_a7.sv"
# (case, packets per direction)
CASES = {0: 1200, 1: 3000, 2: 250}
CLOCKS = (16, 8, 12)        # clk_pcie period, ns (62.5, 125, 83.3 MHz); clk_sys 100 MHz
# name: ([(old, new), ...], case, expected marker)
MUTANTS: dict[str, tuple[list[tuple[str, str]], int, str]] = {
    # Admission on the full flags only (before R3): a packet admitted near
    # full overflows the data FIFO.
    "tx_admit_on_full": ([("(acc_sys && !full_data && !full_tok && !pfull_data && !pfull_tok)",
                           "(acc_sys && !full_data && !full_tok)")], 0, "CAP_TX_"),
    # Token FIFO unreserved: back-to-back short packets overflow it.
    "tx_token_unreserved": ([("(acc_sys && !full_data && !full_tok && !pfull_data && !pfull_tok)",
                              "(acc_sys && !full_data && !full_tok && !pfull_data)")], 1, "CAP_TX_"),
    # No DW cap: an oversize host packet outgrows its reservation.
    "tx_no_cap": ([("wire        tx_end    = dfifo_tx_last || (host_mid && tx_dw == CAP_DW - 1);",
                    "wire        tx_end    = dfifo_tx_last;")], 2, "CAP_TX_"),
    "rx_admit_on_full": ([("tlps_in.tuser[0] ? (acc_pcie && !fifo_full && !fifo_pfull)",
                           "tlps_in.tuser[0] ? (acc_pcie && !fifo_full)")], 0, "CAP_RX_"),
    "rx_no_cap": ([("wire         rx_end   = tlps_in.tlast || (!tlps_in.tuser[0] && rx_beats == CAP_BEATS - 1);",
                    "wire         rx_end   = tlps_in.tlast;")], 2, "CAP_RX_"),
}


def run(argv, work: Path, name: str, expect: str | None = None) -> str:
    """Run one tool stage; grade the log as well as the exit status."""
    with (work / f"{name}.log").open("w") as log:
        result = subprocess.run(
            [str(x) for x in argv], cwd=work, stdout=log, stderr=subprocess.STDOUT, timeout=7200
        )
    out = (work / f"{name}.log").read_text(errors="replace")
    if expect is not None:
        if re.search(r"(?m)^ERROR:", out) or expect not in out or "CAP_PASS" in out:
            raise RuntimeError(f"{name}: mutant survived or failed wrongly\n{out[-4000:]}")
        print(f"CAP_MUTANT_KILLED {name} ({expect})", flush=True)
        return out
    bad = re.search(r"(?m)^(?:ERROR:|FATAL_ERROR:|Fatal:)|CAP_FAIL", out)
    if result.returncode or bad or (name.startswith("case") and "CAP_PASS" not in out):
        raise RuntimeError(f"{name} failed rc={result.returncode}\n{out[-6000:]}")
    info = "".join(f"\n  {m}" for m in re.findall(r"(?m)^CAP_(?:INFO|OCC).*$", out))
    print(f"CAP_STAGE_PASS {name}{info}", flush=True)
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--vivado", type=Path, required=True)
    ap.add_argument("--board", type=Path, required=True)
    ap.add_argument("--models", type=Path, required=True, help="funcsim models with prog_full")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--seeds", type=int, default=2, help="seeds per case and clock")
    ap.add_argument("--mutant", choices=tuple(MUTANTS))
    args = ap.parse_args()

    work = args.out.resolve()
    work.mkdir(parents=True, exist_ok=False)
    src = work / "src"
    src.mkdir()
    for name in SOURCES:
        shutil.copy2(args.board / "src" / name, src / name)
    # XSim cannot index a concatenation ({v}[7:0]); see sim/subsys_reset.
    hdr = src / "pcileech_header.svh"
    old_bs = "`define _bs16(v)   {{v}[7:0], {v}[15:8]}"
    if hdr.read_text().count(old_bs) != 1:
        raise ValueError("_bs16 macro changed; review the XSim rewrite")
    hdr.write_text(hdr.read_text().replace(old_bs, "`define _bs16(v)   {v[7:0], v[15:8]}"))
    if args.mutant:
        edits, _case, _marker = MUTANTS[args.mutant]
        text = (src / TLP).read_text()
        for old, new in edits:
            if text.count(old) != 1:
                raise ValueError(f"mutant {args.mutant}: anchor count {text.count(old)}")
            text = text.replace(old, new)
        (src / TLP).write_text(text)
    bench = src / "tb_fifo_capacity.sv"
    shutil.copy2(HERE / bench.name, bench)
    models = []
    for name in MODELS:
        shutil.copy2(args.models / f"{name}.v", src / f"{name}.v")
        models.append(src / f"{name}.v")
    manifest = {
        str(p.relative_to(work)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(src.iterdir())
    }
    (work / "source-sha256.json").write_text(json.dumps(manifest, indent=2) + "\n")

    vbin = args.vivado / "bin"
    run([vbin / "xvlog", "--sv", "-i", src, args.vivado / "data/verilog/src/glbl.v", *models,
         src / TLP, bench], work, "compile")
    run([vbin / "xelab", "-mt", "4", "-L", "xpm", "-L", "unisims_ver", "-L", "unimacro_ver",
         "work.tb_fifo_capacity", "work.glbl", "-s", "cap"], work, "elaborate")

    def sim(case: int, pns: int, seed: int, expect: str | None = None) -> None:
        argv = [vbin / "xsim", "cap", "-runall", "-sv_seed", str(seed)]
        for a in (f"CASE={case}", f"PCIE_NS={pns}", f"SEED={seed}", f"PKTS={CASES[case]}"):
            argv += ["-testplusarg", a]
        run(argv, work, f"case-{case}-pcie{pns}-seed{seed}", expect=expect)

    if args.mutant:
        _edits, case, marker = MUTANTS[args.mutant]
        for pns in CLOCKS:
            try:
                sim(case, pns, 1, expect=marker)
                print(f"CAP_RUN_PASS mutant={args.mutant}", flush=True)
                return
            except RuntimeError:
                print(f"CAP_MUTANT_SURVIVED_CLOCK pcie{pns}", flush=True)
        raise SystemExit(f"CAP_MUTANT_SURVIVED {args.mutant}")
    n = 0
    for case in CASES:
        for pns in CLOCKS:
            for seed in range(1, args.seeds + 1):
                sim(case, pns, seed)
                n += 1
    print(f"CAP_RUN_PASS runs={n}", flush=True)


if __name__ == "__main__":
    main()
