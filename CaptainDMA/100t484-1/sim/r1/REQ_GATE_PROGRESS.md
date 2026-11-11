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
