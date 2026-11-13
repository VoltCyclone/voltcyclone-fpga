#!/usr/bin/env python3
"""Run production COM with configured Vivado FIFO models, preserving all logs."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIFOS = ("fifo_64_64_clk2_comrx", "fifo_256_32_clk2_comtx", "fifo_32_32_clk1_comtx")
SOURCES = (
    "pcileech_com.sv",
    "pcileech_header.svh",
    "pcileech_ft601_clk.sv",
    "pcileech_ft601_phy.sv",
)
MUTANTS = {
    "return_reset": (
        "rst_comtx_fifo <= rst || rst_comrx_fifo_clk;",
        "rst_comtx_fifo <= rst;",
        1,
        "COM_READY_WITH_STOPPED_READ_CLOCK",
    ),
    "rx_reset": (
        ".rst            ( rst_comrx_fifo            )",
        ".rst            ( 1'b0                     )",
        2,
        "COM_RX_",
    ),
    "packer_reset": (
        "if ( rst_com | (~com_rx_valid32",
        "if ( rst | (~com_rx_valid32",
        0,
        "COM_RX_ORDER",
    ),
}


def run(
    argv: list[str | Path],
    work: Path,
    name: str,
    require_pass: bool = False,
    expected_failure: str | None = None,
) -> None:
    """Run one tool stage and grade its log as well as its exit status."""
    with (work / f"{name}.log").open("w") as log:
        result = subprocess.run(
            [str(x) for x in argv],
            cwd=work,
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=240,
        )
    output = (work / f"{name}.log").read_text(errors="replace")
    if expected_failure:
        if result.returncode != 0 or not re.search(
            r"(?m)^Fatal: " + re.escape(expected_failure), output
        ):
            raise RuntimeError(
                f"{name} mutant survived or failed incorrectly\n{output[-6000:]}"
            )
        print(f"COM_MUTANT_KILLED {name}", flush=True)
        return
    errors = re.search(
        r"(?m)^(?:ERROR:|FATAL_ERROR:|Fatal:)|\bCOM_(?:RX_|TX_|NO_RECOVERY|READY_|COUNTS|VENDOR_TIMEOUT)",
        output,
    )
    if (
        result.returncode
        or errors
        or (require_pass and "COM_VENDOR_PASS" not in output)
    ):
        raise RuntimeError(f"{name} failed rc={result.returncode}\n{output[-6000:]}")
    print(f"COM_STAGE_PASS {name}", flush=True)


def main() -> None:
    """Stage immutable inputs and run the selected model/mutation cases."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vivado", type=Path, required=True)
    parser.add_argument("--board", type=Path, required=True)
    parser.add_argument("--generated-ip", type=Path, required=True)
    parser.add_argument(
        "--structural", type=Path, help="directory of exported functional FIFO netlists"
    )
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--case", type=int, choices=(0, 1, 2), default=None)
    parser.add_argument("--mutant", choices=tuple(MUTANTS))
    parser.add_argument(
        "--matrix", action="store_true", help="three relative clock phases/rates"
    )
    args = parser.parse_args()
    work = args.out.resolve()
    work.mkdir(parents=True, exist_ok=False)
    src = work / "src"
    src.mkdir()
    for name in SOURCES:
        shutil.copy2(args.board / "src" / name, src / name)
    if args.mutant:
        old, new, _case, _failure = MUTANTS[args.mutant]
        rtl = src / "pcileech_com.sv"
        original = rtl.read_text()
        if original.count(old) != 1:
            raise ValueError(f"mutant {args.mutant} match count {original.count(old)}")
        rtl.write_text(original.replace(old, new))
    shutil.copy2(HERE / "tb_com_vendor.sv", src / "tb_com_vendor.sv")
    models = []
    for name in FIFOS:
        source = (
            args.structural / f"{name}.v"
            if args.structural
            else args.generated_ip / name / "sim" / f"{name}.v"
        )
        shutil.copy2(source, src / source.name)
        models.append(src / source.name)
    manifest = {
        str(p.relative_to(work)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(src.iterdir())
    }
    (work / "source-sha256.json").write_text(json.dumps(manifest, indent=2) + "\n")
    bin_dir = args.vivado / "bin"
    run(
        [
            bin_dir / "xvlog",
            "--sv",
            "-i",
            src,
            args.vivado / "data/verilog/src/glbl.v",
            *models,
            *[src / n for n in SOURCES if n.endswith(".sv")],
            src / "tb_com_vendor.sv",
        ],
        work,
        "compile",
    )
    run(
        [
            bin_dir / "xelab",
            "-mt",
            "4",
            "-L",
            "fifo_generator_v13_2_15",
            "-L",
            "xpm",
            "-L",
            "unisims_ver",
            "work.tb_com_vendor",
            "work.glbl",
            "-s",
            "com_vendor",
        ],
        work,
        "elaborate",
    )
    cases = (
        [MUTANTS[args.mutant][2]]
        if args.mutant
        else ([args.case] if args.case is not None else [0, 1, 2])
    )
    clocks = [(5.0, 5.0, 1.3)]
    if args.matrix:
        clocks += [(4.0, 5.0, 2.7), (5.0, 6.5, 0.9)]
    for index, (sys_half, com_half, phase) in enumerate(clocks):
        for scenario in cases:
            argv = [bin_dir / "xsim", "com_vendor", "-runall"]
            for arg in (
                f"CASE={scenario}",
                f"SYS_HALF={sys_half}",
                f"COM_HALF={com_half}",
                f"PHASE={phase}",
            ):
                argv += ["-testplusarg", arg]
            run(
                argv,
                work,
                f"case-{scenario}-clock-{index}",
                require_pass=True,
                expected_failure=MUTANTS[args.mutant][3] if args.mutant else None,
            )
    print(
        f"COM_VENDOR_RUN_PASS cases={len(cases)*len(clocks)} mutant={args.mutant}",
        flush=True,
    )


if __name__ == "__main__":
    main()
