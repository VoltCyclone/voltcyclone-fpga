# COM reset tests with Vivado FIFO models

`tb_com_vendor.sv` uses production `pcileech_com.sv`, real XPM reset synchronizers and
all three configured COM FIFO implementations. It injects stimulus at COM's
clock-controller and PHY stream boundaries using explicit hierarchical forces.
It does not qualify the MMCM, physical FT601 protocol or electrical timing.

Scenarios: running clocks, stopped COM clock, stopped SYS clock. Every run
checks two COM session aborts, preloaded old TX/RX traffic, a half-packed RX word,
fresh RX ordering, and TX traffic offered at the first advertised-ready cycle.
Old queued traffic is discarded only at the explicitly declared session abort;
the fresh-traffic scoreboard is never cleared during recovery. Each healthy
run must deliver exactly 24 RX pairs and 208 TX words.

Requirements: Python 3.11+, Vivado 2026.1/XSim, and generated simulation wrappers
from these board IP configurations. Use the environment from `settings64.sh`.
All output directories must be new; the runner refuses to overwrite them.

```sh
# From CaptainDMA/100t484-1:
python3 sim/com_reset/run_vendor.py --vivado "$XILINX_VIVADO" \
  --board . --generated-ip /path/to/project.gen/sources_1/ip \
  --out /path/to/new-behavioral-run

# Export more accurate functional structural FIFO models from existing OOC runs.
vivado -mode batch -nojournal -nolog -source sim/com_reset/export-fifos.tcl \
  -tclargs /path/to/project.runs /path/to/new-structural-models

python3 sim/com_reset/run_vendor.py --vivado "$XILINX_VIVADO" \
  --board . --generated-ip /path/to/project.gen/sources_1/ip \
  --structural /path/to/new-structural-models --matrix \
  --out /path/to/new-structural-run
```

The structural matrix is three clock-phase/rate settings × three scenarios.
The additional rates are component stress cases, not board timing claims.
Expected final marker: `COM_VENDOR_RUN_PASS cases=9 mutant=None`.

Run each mutation separately with `--mutant return_reset`, `--mutant rx_reset`
or `--mutant packer_reset`, a new `--out`, and the same structural model inputs.
The runner changes a temporary copy only and requires a specific simulation
failure after successful compile/elaboration. A compile failure or generic
timeout never counts as a killed mutant. XSim may exit zero after `$fatal`, so
the runner also grades the output markers.

Model and reset limitations are documented in AMD PG057, pp. 127–132 and 186:
<https://docs.amd.com/v/u/en-US/pg057-fifo-generator>. Behavioral models omit
synchronization delay; functional structural models do not simulate physical
metastability or routed delays. The tests hold reset while clocks return and
settle before RX ingress. They do not establish the earliest legal RX restart,
short/adjacent-reset support, a physical clock-loss reset sequence, or the
seven PCIe subsystem-reset FIFO destinations. R4 remains open.

## Pin-driven earliest RX

`tb_com_early_rx.sv` drives FT601 pins using `sim/ft601/ft601_model.sv` and keeps
the production PHY/packer/XPM/FIFO path intact. Only the MMCM clock/status
outputs are forced: c0/c180 have ideal +0.5/+5.5 ns phases. RXF_N is already
low before reset releases; there is no RX settling delay. The separate SYS
boot-command stream is allowed to finish before scoring begins.

Run with the same arguments above plus `--bench early_rx --matrix`. The nine
cases combine three reset-release phases and three SYS-clock/relative-phase
settings; the modeled FT601 clock stays at 100 MHz. Each case must deliver
48 correctly ordered pairs from exactly 96 accepted pin transfers across
initial release, a running-clock COM reset, and a stopped/restarted COM clock.
The scoreboard is not cleared between epochs. A forced-full probe after each
drained epoch checks that normal full cannot reset an established PHY session.

Add `--rx-reset-cycles 20 --case 0` without `--matrix` as a positive control:
extend the staged RX FIFO reset from 2 to 20 counter cycles and require the
same complete stream. The PHY must follow actual FIFO readiness, not a guessed
startup delay. Negative controls `--mutant bypass_rx_ready` and
`--mutant live_full_reset` must fail for the expected FIFO-not-ready or live-full
reset reason after successful compilation/elaboration.

This closes only the modeled earliest-RX recovery path. It does not establish
simultaneous SYS boot-command/RX behavior, TX replay across resets, sustained
full/backpressure handling, reset during active traffic, short/adjacent reset
requests, physical clock-loss reset sequencing or electrical qualification.
