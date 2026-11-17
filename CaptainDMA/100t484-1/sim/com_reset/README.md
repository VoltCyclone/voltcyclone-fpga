# COM reset tests with Vivado FIFO models

`tb_com_vendor.sv` uses production `pcileech_com.sv`, real XPM reset synchronizers and
all three configured COM FIFO implementations. It injects stimulus at COM's
clock-controller and PHY stream boundaries using explicit hierarchical forces.
It does not qualify the MMCM, physical FT601 protocol or electrical timing.

Scenarios: running clocks, stopped COM clock, stopped SYS clock. Every run
checks two COM session aborts, preloaded old TX/RX traffic, a half-packed RX word,
fresh RX ordering, and TX traffic offered at the first advertised-ready cycle.
The first DW of each TX test word is a mux status DW with only non-TLP slots,
which `pcileech_com_tx_resync` passes unchanged. The idle word the COM writes
after every TX flush is not scored here; `tb_com_tx_session.sv` checks it.
The stopped-SYS case verifies one enabled, non-full FIFO write of the old
RX pair before abort, so quarantine cannot accidentally erase the setup.
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
failure after successful compile/elaboration. `return_reset` bypasses the
actual TX reset port and must expose stale TX data. A compile failure or generic
timeout never counts as a killed mutant. XSim may exit zero after `$fatal`, so
the runner also grades the output markers.

Model and reset limitations are documented in AMD PG057, pp. 127–132 and 186:
<https://docs.amd.com/v/u/en-US/pg057-fifo-generator>. Behavioral models omit
synchronization delay; functional structural models do not simulate physical
metastability or routed delays. The stream-forced reset bench settles before RX ingress; the additional
pin-driven and sequencer benches below cover earlier RX and short/adjacent
requests. They do not qualify physical clock loss or the seven PCIe
subsystem-reset FIFO destinations. R4 remains open.

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

Add `--reset-count-cycles 20 --case 0` without `--matrix` as a positive control:
extend each staged replay phase from 6 to 20 counter cycles and require the
same complete stream. The PHY must follow actual FIFO readiness, not a guessed
startup delay. Negative controls `--mutant bypass_rx_ready` and
`--mutant live_full_reset` must fail for the expected FIFO-not-ready or live-full
reset reason after successful compilation/elaboration.

This closes only the modeled earliest-RX recovery path. It does not establish
simultaneous SYS boot-command/RX behavior, TX replay across resets, sustained
full/backpressure handling, reset during active traffic, short/adjacent reset
requests, physical clock-loss reset sequencing or electrical qualification.

## Post-recovery FIFO reset replay

Run `--bench sequence --matrix` with the structural-model arguments above.
Unlike the earlier benches, `tb_com_sequence.sv` retains the production MMCM
clock-controller state machine. It models only ideal MMCM output clocks and
LOCKED/CLKINSTOPPED status; no physical MMCM behavior is established.

The MMCM COM path now separates traffic quarantine from FIFO initialization.
One SYS-register reset output feeds both asynchronous FIFOs. On unavailable
clocks/reset, completion is revoked and that output freezes. When the clock
controller certifies recovery, the coordinator qualifies any existing high
level, qualifies a low interval, issues a fresh high pulse, releases it, and
holds every FIFO enable off for one more counted low phase before completion,
so the FIFOs' internal reset synchronizers finish without relying on their
full/empty flags. Every phase counts at least six full periods in both clocks using a four-phase
request/acknowledgement handshake. Interruption discards all phase credit and
requires acknowledgement low before restarting. Requests during recovery
coalesce into the next complete transaction. COM packer/small TX FIFO, all
four asynchronous FIFO enables, host readiness and RX visibility remain
quarantined; the separate boot-command mux is preserved. RX PHY release still
requires its session-latched full-low observation; TX admission retains the
FIFO almost-full qualification. Legacy generic 0 keeps its previous behavior. Check it with
`--bench reset --legacy --matrix`; the runner stages the legacy PHY and
changes only the testbench COM parameter. This checks stream-boundary/FIFO
compatibility, not physical legacy-PHY timing.

AMD PG057 v13.2 pp. 127, 129-130 requires clocks available when reset is
applied, reset reapplication after unavailable clocks, and describes native
reset as edge sensitive. Its six-slower-clock gap wording does not identify
the endpoints. Six *high* and six *low* periods are conservative local policy;
these tests do not resolve that documentation ambiguity. Physical clock loss
can precede synchronized detection, including a FIFO reset assertion coincident
with controller invalidation; that transaction earns no completion credit and
must be replayed after certified recovery.

The matrix runs four cases at three clock settings (12 runs). They cover
startup with stopped COM, one-SYS-cycle reset requests, adjacent requests,
lock loss immediately after reset release, stopped/restarted COM, and
interruption in every active request/acknowledgement phase (states 1-6, 8, 9).
Cases 0-2 interrupt with a SYS `rst` pulse, during which the modeled `c0`
keeps running; case 3 instead stops `clk_c` in each phase, freezing the COM
synchronizers with `ack_com` possibly high (`COM_SEQ_CLOCK_STOP` logs the
state actually hit). Every
recovery must have a fresh rising reset edge on both FIFO ports. Monitors
measure high/low times and both clock counts from each certified return,
check actual FIFO port enables and consumer quarantine, require six full
periods in both clocks after each reset release before any FIFO enable or
advertised readiness (`COM_SEQ_ENABLE_TOO_EARLY`), and send an ordered
RX pair plus eight TX words after each completed recovery. They deliberately
present a stale TX offer during unavailable clocks. Boot-command outputs are
excluded explicitly from the COM data scoreboard.

Negative controls `no_reapply`, `short_gap`, `early_ready`,
`assert_unavailable` and `no_post_hold` require
`--bench sequence`; missing replay/early completion must produce a specific
readiness failure, shortened low qualification a spacing failure,
changing reset during sampled unavailability a frozen-level failure, and
completing on the reset-release edge an enable-too-early failure. The
pin-driven `bypass_rx_ready` observer catches premature accepted pin reads;
`live_full_reset` preserves startup gating but incorrectly resets an established
PHY on runtime full. Generic timeout never counts as a killed control.

This is a component/model contract. It does not establish live-link packet
drain, physical clock quality, or endpoint-scoped reset/CDC signoff for the complete board. Boot-command
overlap is excluded structurally in MMCM mode: every `rst` resets the MMCM and
certification takes `FT601_STABLE_CYCLES` (64) SYS edges, longer than the
boot-word window; `pcileech_com.sv` checks that at elaboration. The sequence
bench also asserts that each `rst` raises `com_arst` on the next SYS edge
(`COM_RST_WITHOUT_ARST`), which `rx_ready` and the handshake rely on.

## Host output across COM aborts

`tb_com_tx_session.sv` (`--bench tx_session`) checks what the host parses when a
COM session abort cuts the TX stream. A COM abort flushes both TX FIFOs and
resets the PHY, while `pcileech_mux` resets only on the global `rst` and
resumes mid-stream. `pcileech_com_tx_resync` (end of `pcileech_com.sv`)
therefore:

- writes one all-idle word after every TX flush, which realigns a host whose
  32-byte parse was cut mid-word;
- rewrites TLP DWs without FIRST as idle until a TLP DW with FIRST, so the tail
  of a cut TLP never follows a prefix the host already holds.

The bench models the SYS side as the mux:

- TLPs of 3-40 DWs with FIRST and LAST, command DWs and idle slots;
- offer pacing that alternates trickle and burst;
- the model keeps its position across aborts, as the mux does.

The host side models the LeechCore 2.23+ parser:

- `DeviceFPGA_Session_TlpFrameStep`, with FIRST required because the board
  reports version 4.14;
- the `0xE` status scan;
- byte order as on the wire;
- one continuous session across every abort, which is the worst case of a host
  read that spans an abort.

Each run makes 12 aborts at random points, two thirds of them aimed off a word
boundary. The PHY side pulls about one DW in three. Failures:

| Marker | Failure |
| --- | --- |
| `COM_SESSION_SPLICE` | A completed TLP is not exactly one whole TLP. |
| `COM_SESSION_MALFORMED` | The parser reports a malformed TLP. |
| `COM_SESSION_MISFRAME` | A host frame starts off the COM word grid. |
| `COM_SESSION_LOST` | A TLP that was not in flight at an abort is missing, repeated or out of order. |
| `COM_SESSION_PAD` | An abort is not followed by the idle word before new data. |
| `COM_SESSION_COVERAGE` | No mid-word cut, no dropped tail, no host restart at FIRST, or too little delivery. |

One case is counted as `SESSION_RESIDUAL`, not failed: the one host frame that
straddles a mid-word cut.

- The host applies the cut word's remaining slot nibbles to the next DWs,
  which are the idle word.
- A TLP whose LAST was in the lost part of that word completes at full length,
  with idle-word DWs (`FFFFFFEF`, `FFFFFFFF`) in place of its lost DWs.
- The parser can also report a malformed TLP in that frame.
- Only a host-side change can repair this. The FPGA cannot recall DWs the
  host already holds.

The matrix (3 cases × 3 clock settings) must print
`COM_VENDOR_RUN_PASS cases=9 mutant=None`. Mutants:

| Mutant | Change |
| --- | --- |
| `resync_no_skip` | Tails are never dropped. |
| `resync_no_rearm` | A flush does not re-arm the drop. |
| `resync_no_pad` | No idle word. |
| `resync_bypass` | Previous wiring: mux words go straight into the FIFO. |

Each mutant runs on case 0 at the three clock settings with `--matrix`, and
must fail with a `COM_SESSION_` marker in every run.

The idle word does not help hosts older than LeechCore 2.23. Those parsers
ignore FIRST, so any cut prefix is joined to the next TLP.
