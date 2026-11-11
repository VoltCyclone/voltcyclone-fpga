# req_gate progress — HANDOFF_REQ_GATE.md

Scope: implement and verify the gate in the existing isolated upstream checkout;
leave board/TCL integration for the later R1 steps. Do not commit.

Baseline: all four existing R1 benches + Verilator -Wall pass, 2026-11-10.

Pre-flight: classifier and allocator interfaces match the handoff; table exposes
free, n_reserved, n_issued and admission/release ports. Refusals never release tags;
release belongs only to a proven pre-core discard. Core tx_err_drop never releases.

Decisions:
- Use two input queue entries plus a registered pull response: this guarantees
  space for the already requested input beat on sudden downstream backpressure.
  The handoff suggests one skid register; its requirement is pull equivalence.
- Keep the gate core ports flat for Icarus; provide a separate IfAXIS128 adapter
  for the board insertion point and verify it with Verilator.
- Admission and classification occur when an input beat arrives, using live
  controls/table state. Packets keep their disposition through tlast. Orphan
  continuation beats after reset are discarded until tlast.
- N_NP_MAX must be explicitly bound (zero default fails elaboration/simulation);
  live-credit sizing and hardware qualification remain later integration gates.

Tasks:
1. Write pull-source/sink scoreboard bench against real classifier/allocator/table;
   demonstrate RED, implement gate + adapter, demonstrate GREEN.
2. Add mutation campaign and run all R1 benches/lint plus interface verification.
3. Independent hardware review, resolve material findings, update handoffs/evidence.

Completed 2026-11-10:
- RED: interface-only implementation failed `stream drains without deadlock`;
  req_gate_red.log records the functional failure before implementation.
- GREEN: run_r1.py: 8/8 cases, including all four pre-existing R1 benches;
  gate scoreboard checks=24821/25895/29792 at CAP=3/36/256, counters=17.
- run_gate_axis.py: real IfAXIS128 adapter scoreboard (25895 checks), -Wall
  adapter lint, and cap -1/0/257 rejection all pass.
- mut_gate.py: positive controls pass, 29/29 non-equivalent mutants killed by
  explicit behavioral failures, including both counter saturation removals.
- Independent hardware reviewer: no RTL finding. Corrected stale handoff
  tx_err_drop release guidance against contract section6; no code fix required.
- Entire gate core + adapter, test scripts and source/test hashes preserved in
  the parent repository's docs/development/msix-evidence/2026-11-10/r1-req-gate/.
- Black cache permission failure reproduced even outside sandbox; formatting
  completed successfully using the task's temporary cache directory.

Limits: gate synthesis/timing not run, no board/TCL or live-core integration,
no hardware qualification; live-credit sizing still must bind N_NP_MAX. No
commits or hardware operations performed. Next implementation: req_tx_obs.

RX checkpoint, 2026-11-10:
- Gate and standalone dependencies committed as cba2c6c at user request.
- TX observer and RX completion path are now in the working tree.
- run_r1.py passes all 10 cases, including 2,742 RX checks with the real table.
- mut_rx.py catches 25/25 deliberate faults. A mutation that omitted format
  checking initially survived because another shape check masked it. The invalid
  format fixture now isolates the format check and that mutant is caught.
- Independent review found a 4DW completion encoding escaping exact Fmt/Type
  recognition. A failing regression preceded the Type-based malformed path fix.
- Same-edge supersede is exposed in the table lookup. Terminal TC/Attr matching
  and late BCM/CRS Unexpected handling are explicit in the parent contract.
- run_gate_axis.py passes the actual gate/TX/RX converter/host-filter round trip
  with two restored host completions, including a digest-only tail removal.
- Sized the pre-existing src64 next_len addition explicitly for Verilator.
- RX decisions/updates occur at the header edge. Core framing checks, the
  measured ECRC-check-off baseline and combinational table lookup underpin this
  implementation. EOF ECRC-error handling, exact core qualification and timing
  remain integration work.
- Next implementation is req_err. Coordinate timeout/RX concurrent events and
  repeated RX errors with its queue capacity and overflow behavior.

Error-report checkpoint, 2026-11-10:
- req_err and its bench implement the three requester error channels, one report
  per D0 clock, AER header DWORD order/retention, and a 512-entry four-bank FIFO.
- tb_req_err passes 23,043 checks. The full timeout sweep plus 256 legal-rate RX
  errors survives a 512-clock AER ownership delay. Full pop+push, bank wrap,
  non-D0 discard accounting, pending reset and saturating telemetry also pass.
- Review caught the initial masked-first-error wait deadlock. A regression failed
  before the fix. Live mask eligibility and mask-change tests now cover it.
  No arbitrary acknowledgement timeout was introduced.
- mut_err.py catches 23/23 non-equivalent faults. The redundant latch eligibility
  check can be removed without changing behavior because the live hold predicate
  also checks eligibility. That equivalent mutation was excluded.
- The converter-path fixture completes two reads and then injects a duplicate
  and an illegal 4DW completion. Both reach the correct serialized error output.
- Follow the documented non-D0 discard policy for queued and arriving events.
  Finite-capacity overflow preserves old data and counts rejected newest events.
- Synthesis/timing, coherent live AER-mask integration, and exact-core ANFE/mask/
  acknowledgement behavior remain open. Both normal and escalated SSH attempts
  to ramsey@192.168.3.252 failed authentication. A user question is pending.
- Next implementation is status exposure and drp_startup.

Status-exposure checkpoint, 2026-11-11 (uncommitted):
- pcileech_req_status samples every requester counter, live count and sticky
  on one clk_pcie edge and carries the word to clk_sys through
  xpm_cdc_handshake (pattern of the draft's pcileech_pcie_cfgword_cdc; no reset
  on the handshake, FSM, sequence or snapshot). It owns the timed_out counter
  (counts table to_valid; abort-reset) and a saturating session-abort count
  that survives the abort. Continuous snapshots; a stopped clk_pcie leaves the
  last one readable with a frozen sequence word.
- 512-bit block at pcileech_fifo ro +0x028 (ro grows to [831:0], SIZEOF 0x68)
  via new IfPCIeFifoCore.req_status. Layout documented in the module header,
  magic/version 0x5201. Driver of dfifo_pcie.req_status lands with board
  integration (step 3); until then the field is undriven.
- tb_req_status: coherence (all fields decode to one edge), layout, counter
  saturation/reset, flags, liveness and stopped clock at four clock ratios
  (16/10, 8/10, 2.7/41, 97/10 ns). sim/r1 now carries a sim-only XPM handshake
  model and a lint blackbox. run_r1.py: 15/15 runs pass with -Wall lint.
- mut_status.py: 23/23 killed (3 by the XPM usage-rule check). Equivalent
  mutant excluded: removing the S_DRAIN wait (S_IDLE also waits for !src_rcv).
- Not covered: DRP_STARTUP_FAIL/word (added with drp_startup), synthesis/timing
  and Vivado CDC report on the handshake, board integration.
- Pre-existing, unrelated: pcileech_fifo assigns dpcie.pcie_cfg_* fields that
  IfPCIeFifoCore does not declare.
