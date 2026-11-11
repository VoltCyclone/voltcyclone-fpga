# R1 requester tracking — handoff for `req_gate` (next session)

## Checkpoint update: gate implemented (2026-11-10)

The gate task below is now implemented, still **uncommitted and not connected to
the board/project TCL**. The next R1 implementation is **`req_tx_obs`**, followed
by `req_rx_cpl`; the original gate brief is retained below as acceptance context.

- `src/pcileech_req_gate.sv`: flat-port core for Icarus, instantiates the real
  classifier/allocator and drives the table's admission port. Checks 7–8 refuse
  without admitting; accepted reads rewrite only Tag. Classification and table
  reservation occur at input arrival with live controls/counts, independently of
  downstream ready. Disposition remains fixed through `tlast`, even if a dropped
  continuation falsely carries `first`. Orphan tails after reset are discarded.
- `src/pcileech_req_gate_axis.sv`: real `IfAXIS128.sink`/`.source` adapter for the
  intended merged-TX → dst64 boundary. No board files have been connected yet.
- The input buffer has **two entries**, with a separate registered downstream
  pull response. This covers an input beat already promised when the downstream
  abruptly stalls; a one-register suggestion below was not sufficient by itself.
  Output valid answers the **previous** pull, regardless of current ready.
- `N_NP_MAX` is mandatory in practice: its zero default fails at time zero,
  as do values outside 1..256. Test caps 3/36/256 are fixtures; production sizing
  from advertised NP credits remains an integration obligation.
- Counters: `admitted_count[15:0]`; `refuse_counts[111:0]` packs seven saturating
  16-bit counts, reason 1 in [15:0] through reason 7 in [111:96]. Reset is a link
  session abort, shared with the table and stream endpoints, never `rst_subsys`.
- The gate has **no release output**. A refused request was never RESERVED.
  Any later proven pre-core discard of an admitted packet must be identified by
  the component doing that discard; `tx_err_drop` is count-only, never a release.

Verification commands (run from the board directory with OSS-CAD tools on PATH):

```
python3 sim/r1/run_r1.py
python3 sim/r1/run_gate_axis.py
python3 sim/r1/mut_gate.py
```

The first command includes the existing four benches, the gate with caps 3/36/256,
and the 17-check saturation bench. The stream bench uses the actual table and
checks stalls, round-robin, live controls, each refusal, issued/reserved cap
accounting, quarantine exclusion, timeout/drain recovery, and reset. The second
command runs the same scoreboard through the real interfaces using Verilator,
plus adapter `-Wall` lint and invalid-cap guards. The third kills **29/29**
non-equivalent mutants; compile errors and missing PASS markers never count as
kills. Saturation mutations fail the counter bench explicitly.

Logs: `req_gate_red.log`, `req_gate_suite.log`, `req_gate_axis.log`,
`req_gate_mutations.log`, and `req_gate_mutations.json` (source/test hashes).
Progress and design decisions: `REQ_GATE_PROGRESS.md`. Independent hardware review
found no RTL defect and corrected the old `tx_err_drop` guidance below.
No new synthesis, routed image, live core integration or hardware qualification
has been performed for the gate. Prior table-only synthesis numbers below do not
include it.

---

Written 2026-11-10. Everything below is in the isolated upstream checkout
`/private/tmp/pcileech-completion/upstream/CaptainDMA/100t484-1`. All R1 RTL is
**uncommitted** and **not wired into the board top or the project TCL**. Build the
donor only in the authorized isolated/logged/time-bounded scope
(`ramsey@192.168.3.252`, `~/tmp2026/msix-completion`); physical reset/rebind/flash
are **not** authorized.

Contract: `PCILeechFWGenerator/docs/development/MSIX_REQUESTER_CONTRACT.md`
(§3 classification/admission, §4 entry, §5 tags, §6 lifecycle). The companion
`MSIX_IMPLEMENTATION_HANDOFF.md` item 3 tracks the whole R1 build.

## Current state (all green)

Run: `PATH=/usr/local/oss-cad-suite/bin:$PATH python3 sim/r1/run_r1.py`
(Icarus `iverilog -g2012 -Wall -I src` per bench, requires `R1_TB_PASS <name>`
and no `R1_TB_FAIL`; then `verilator --lint-only -Wall`). Tools: iverilog 13.0
devel and Verilator 5.037 at `/usr/local/oss-cad-suite/bin`.

| Module | Bench checks | Mutants | Notes |
|---|---|---|---|
| `pcileech_req_classify.sv` (comb) | 60 | 9/9 | §3 checks 1–6, §4 Byte Count / Lower Address |
| `pcileech_req_tagalloc.sv` | 16 | 5/5 | §5 round-robin, one alloc/cycle |
| `pcileech_req_cto_limits.sv` | — (proof) | 7/7 | §8 code → T/Q ticks, all 16 codes @ 62.5/125 MHz |
| `pcileech_req_table.sv` | 85 | 21/21 pre-FLR + 23/23 FLR/release | §4/§6/§8/§9 incl. FLR + release |

Mutation scripts live in the session scratchpad
`/private/tmp/claude-501/-Users-ramseymcgrath-code-PCILeechFWGenerator/87091eee-0260-4622-86d7-c50e72031dba/scratchpad/`
(`mut_flr.py` is the latest). Pre-change backups of the table + bench are there too
(`*.pre-flr.sv`).

OOC synthesis dir on the build server: `~/tmp2026/msix-completion/r1-rtl-synth-20261110`
(`synth.tcl`, xc7a100tfgg484-1, 16 ns). Latest table (with FLR + release):
**8,191 LUTs (12.9%), 1,427 FFs, WNS +4.1 ns**. 100T qualified image is 12,155 LUTs
(19%), so ~32% total. **35T is out of scope for now (user, 2026-11-10)** — do not
spend effort on the entry-count parameter / 32-entry fit.

## `req_table` interface the gate drives

Ports the gate uses (admit side + status), from `src/pcileech_req_table.sv`:

```
// admit (req_gate): FREE -> RESERVED
input  adm_valid; input [7:0] adm_tag, adm_host_tag;
input  [12:0] adm_bc; input [6:0] adm_la; input [2:0] adm_tc; input [1:0] adm_attr;
// release (req_gate): RESERVED -> FREE when its packet is discarded
input  rel_valid; input [7:0] rel_tag;
// status
output [255:0] free;                 // free[tag] == 1 when FREE
output [8:0]   n_reserved, n_issued; // for the N_np_max in-flight cap (§3 check 8)
output         err_release;          // sticky: release of a non-RESERVED tag
```

`pcileech_req_tagalloc.sv`: `free[255:0], ext_tag_en, take -> avail, tag`. It offers
the lowest free tag at/after an internal pointer (round-robin, §5). `take && avail`
advances the pointer past the taken tag. `ext_tag_en = cfg_dcommand[8]`.

`pcileech_req_classify.sv` (combinational) consumes the first beat and `live_rid`,
`bme`, `mrrs_code` and returns `cls` (PASS/TRACK/REFUSE), `reason`, `host_tag`, `tc`,
`attr`, `byte_count`, `lower_addr`. **Checks 7–8 are not in the classifier** — the
gate adds them (contract §3): a TRACK result still needs a free tag (else
`REFUSE_NO_TAG`) and `n_reserved + n_issued < N_np_max` (else `REFUSE_NP_CAP`).

## What `req_gate` must do (contract §3)

Insertion point: between the merged 128-bit TX stream `tlps_tx` (arbiter output) and
`pcileech_tlps128_dst64`, i.e. `pcileech_pcie_a7.sv:169–174`. Sink modport upstream,
source modport downstream.

1. Classify the **first beat** (`tuser[0]`). PASS → forward the whole packet
   unmodified, untracked. TRACK + admit → rewrite only the Tag field
   (`tdata[47:40]`) on the first beat to the internal tag, write the entry RESERVED
   (§4 fields from the classifier), forward. TRACK-but-refused or REFUSE → **discard
   the whole packet through `tlast`** and bump the matching reason counter.
2. Checks 7 (`REFUSE_NO_TAG`, no free tag) and 8 (`REFUSE_NP_CAP`,
   `n_reserved+n_issued >= N_np_max`) are **refusals, not stalls** (a stall would
   block posted traffic behind a read). `N_np_max` is sized from the live advertised
   NP credit so accept-to-transmit delay stays under the tightest CTO window — for
   the bench, make it a parameter.
3. A proven pre-core discard of a RESERVED packet can use `rel_valid/rel_tag`.
   A **refused** read is never admitted, so it has no entry and never releases.
   **`tx_err_drop` must never free an entry** (contract §6): count it; the link
   session abort or ordinary timeout resolves the request. The gate does not
   discard an admitted packet except when the shared session reset clears the
   stream/table together. Any future pre-core discard needs explicit tag ownership
   and a release from the component performing it.

### Pull-stream mechanics — the hard part

`IfAXIS128` is a **pull** stream (`pcileech_header.svh:190`, `tuser[0]=first`,
`tuser[1]=last`, `tuser[8:2]=BAR`): `tready` asserted in clock *n* requests one beat
delivered in clock *n+1*, which the sink must take. The sink requests only when it
can guarantee a slot (see `pcileech_tlps128_dst64`:
`tready = !rst && (q_count_next <= 1)`). The gate must present the same contract on
both sides and add **no beat loss or duplication except its own refusal discards**
(contract §2, last para).

Two established patterns in this repo to copy from:
- **Drop-through-tlast with a registered `filter` flag**:
  `pcileech_tlps128_filter` (`pcileech_pcie_tlp_a7.sv:206–248`). It registers the
  beat, computes `filter_next = (filter && !first) || (drop condition on first)`, and
  gates `tvalid` with `!filter_next`. A whole packet is suppressed by latching
  `filter` from its first beat until `tlast`. **This is the model for gate drops.**
  But note it uses `source_lite`/`sink_lite` (no `tready`/`has_data` handshake) — it
  sits where the downstream always accepts. The gate sits on the full pull handshake,
  so it also has to forward `tready`/`has_data` correctly.
- **Arbiter packet-lock**: `pcileech_pcie_tlp_a7.sv:393–446` — once `id` selects a
  source it holds until `tvalid && tlast`, so beats of one packet arrive contiguous.
  The gate can rely on that: classification state set on `first` stays valid for the
  rest of the packet.

Because MRd is single-beat (`first && tlast`, §3 check 1), TRACK/REFUSE packets are
one beat; only PASS packets (MWr, completer responses) are multi-beat. So the drop
latch only ever matters for a refused multi-beat packet *if* a non-MRd is refused by
class — which can happen (`REFUSE_CLASS` for MRdLk etc. that may be >1 beat). Handle
the general multi-beat drop; don't assume single-beat.

Suggested structure: a 1-deep registered stage (skid) that classifies in the register
and re-drives downstream, so `tready` translation stays simple and the tag rewrite /
drop decision is made on registered `first`. Confirm the one-cycle added latency is
acceptable to dst64's queue (it is 2-deep). Test the back-to-back and stall cases.

### Bench to write (`sim/r1/tb_req_gate.sv`, test-first)

Add to `run_r1.py` BENCHES: `tb_req_gate: [pcileech_req_gate.sv,
pcileech_req_classify.sv, pcileech_req_tagalloc.sv, pcileech_req_table.sv,
pcileech_req_cto_limits.sv]`. Drive a small upstream model that honors the pull
contract and a downstream model that asserts `tready` with gaps. Cases:
- PASS packet (MWr, multi-beat) forwarded byte-for-byte, no admit.
- Completer response (Cpl/CplD) forwarded, no admit.
- TRACK MRd admitted: Tag rewritten to the allocated internal tag, entry RESERVED
  with the right bc/la/tc/attr, only the Tag DW changed.
- Each refusal: CLASS, MALFORMED, TD, RID, BME, NO_TAG (fill the tag space),
  NP_CAP (fill to N_np_max) — packet dropped through tlast, correct counter, no admit.
- Tag round-robin across several admits; re-use after retire/drain.
- Downstream stall mid-stream: no beat lost or duplicated (scoreboard the forwarded
  stream against the input minus drops).
- Reset mid-packet: nothing leaks into the next session.
Follow the same mutation-testing discipline (write a `mut_gate.py`, kill
non-equivalent mutants, fold equivalents out).

## After the gate

`req_tx_obs` (issue at accepted tlast → ISSUED, start timer), then `req_rx_cpl`
(§7 completion match/progress/restore, fixed-latency pipeline), `req_err` (§9 FIFO),
status counters + the `pcileech_fifo.sv` `ro` map (§9), `drp_startup` (§11). Then wire
into the board top + project TCL, build the parent `RequesterTrackingPlan`/emitter/
manifest, run `hardware-safety-reviewer`, and the R2–R6 gates. Nothing is committed;
**ask before committing** and use **no Co-Authored-By trailer**.
