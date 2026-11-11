# R1 requester tracking handoff

## New-session checkpoint — 2026-11-11

Committed as `9fa747f33da292d3ae6d3ebdee32dfbc348718fc`
(`feat: implement requester completion and error tracking`), based on `cba2c6c`.
Only requester work and one src64 width-fix hunk were committed. The unrelated
eight-file reset/CDC draft is still dirty; preserve it. Nothing was pushed.

The authoritative continuation handoff is now
`/Users/ramseymcgrath/code/PCILeechFWGenerator/docs/development/HANDOFF_REQ_GATE.md`.
It supersedes historical checkpoint counts/working-tree claims below. A clean
export matching the committed tree passed all 11 R1 cases plus the real
adapter/converter/filter simulation (6 core words, 2 host completions, 2 errors).
Durable commit patch, logs, hashes and review materials are under the parent's
`docs/development/msix-evidence/2026-11-11/r1-requester-commit/`.

The user is handling review separately. Claude's reduced production-only review
returned at shutdown and was archived **untriaged**; no findings were accepted
or fixed. It omitted the external contract and test source, so reconcile its
claims with the contract before changing policy. No review process remains.
Do not launch another review automatically. Next implementation remains status
exposure/CDC/RO map, startup DRP, board/TCL wiring, then parent plan/emitter.

## Checkpoint update for requester error reporting

`src/pcileech_req_err.sv` queues timeout, malformed and unexpected events in
same-edge priority order. It has 512 entries with up to three enqueues per edge,
four single-write RAM banks, and one report per available D0 cycle. CTO drives
posted=0/no_recovery=0, and received-completion errors drive posted=1.
`cfg_err_cpl_rdy` is irrelevant to these three channels.

The header-log output reorders raw RX DWORDs to DW0[127:96]. An unmasked first
error retains its header until `headerlog_set` indicates ownership. An already
asserted ownership level allows later reports. Review caught a deadlock if a
masked first error was allowed to wait indefinitely. RED→GREEN tests now cover
masked first/all errors and a live mask change during a hold.

`aer_uncor_mask[31:0]` must represent the core's live mask. Supplying that
coherently after host writes, or qualifying an exact-core logging protocol,
remains part of integration. CTO14, Unexpected16 and Malformed18 determine
logging eligibility. The vendor-model follow-up is pending SSH authentication.

The non-D0 policy counts/discards arrivals and queued events. Beyond capacity,
the queue preserves older entries, counts rejected newest events and raises an
overflow sticky. Report/suppression/overflow counters saturate. Occupancy and
high-water occupancy are exposed for status integration.

`tb_req_err` has 23,043 checks, including a 256-timeout plus 256-RX burst across
a 512-clock header wait, full pop+push, wrap, masked events, power changes,
pending reset, header order and counter saturation. Run
`python3 sim/r1/mut_err.py` for the error-queue mutation campaign (23/23).
`run_gate_axis.py` now completes two reads through the actual converters and
routes one duplicate and one malformed completion through req_err to the error
outputs. Current standalone suite has 11 cases.

Next is status exposure and `drp_startup`. Board wiring, live AER mask access,
exact-core error timing and synthesis/timing qualification remain open.

## Checkpoint update for RX completions

`src/pcileech_req_rx_cpl.sv` and `sim/r1/tb_req_rx_cpl.sv` implement the
completion path against the actual table. The one-cycle output pipeline restores
host tags, checks completion metadata, progresses split data, preserves poison,
and removes TD/digests. Packet drops last through input tlast. The table lookup
now exposes a same-edge supersede when a new request reuses a host tag.

Run `python3 sim/r1/run_r1.py` for 10 cases including 2,742 RX checks.
Run `python3 sim/r1/mut_rx.py` for the 25 RX/table mutations. The RX bench covers
all statuses, FREE/RESERVED/QUARANTINED, split poison, gaps, all digest positions,
4096-byte encoding, zero-length reads, same-edge deadline/FLR/supersede, counters,
and reset. The interface command below also exercises two completed reads through
the real TX/RX width converters and host filter.

The receiver exposes separate combinational `unexpected_valid/header[95:0]`
and `malformed_valid/header[127:0]` events for req_err. The original internal
tag stays in error metadata. Stats count active completion retirements,
unexpected, mismatch, BCM, CRS, superseded drops and malformed frames.

The independent review caught illegal 4DW completion encodings escaping the
first decoder. Type-based recognition and a malformed event now reject them.
Header-edge updates rely on core-validated framing. Current receive ECRC checking
is off. Handling EOF `rx_ecrc_err`, which src64 currently discards, is required
when integrating a core with checking enabled. The combinational lookup/update
and supersede path needs timing qualification.

Timeout events can
coincide with RX unexpected or malformed events. RX errors can recur independently
of entry transitions, so FIFO acceptance/overflow handling must cover that traffic
as well as the 256-entry timeout burst.

## Checkpoint update for the TX issue observer

The standalone gate, classifier, allocator, table and timeout limits are in
`cba2c6c`. The TX observer is implemented in the working tree. Connect its
`tx_data/valid/ready/last` to the core-facing 64-bit AXI stream and its
`iss_valid/iss_tag` to the table. Use the link-session reset shared by the gate,
width converter and table. FLR stays on the table's FLR input.

The observer decodes Fmt/Type and retains the read flag and first-word Tag. It issues
on the accepted final word. The table checks RESERVED ownership and samples
its timestamp and control bits on that edge. `tx_err_drop` increments a
saturating 16-bit counter. The table retains the tag through a core drop.

Run `python3 sim/r1/run_r1.py` for the 9-case standalone suite, including 25
observer checks. The observer bench caught 9/9 deliberate faults. Run
`python3 sim/r1/run_gate_axis.py` for the interface test with the actual
`pcileech_tlps128_dst64` converter. The TX path scoreboard checks six accepted
words, two correctly issued tags and zero bypass events. Independent hardware
review found no observer RTL issues.

Board top and TCL wiring, status exposure, and timing qualification remain open.

## Checkpoint update: gate implemented (2026-11-10)

The original gate brief below records the acceptance context for `cba2c6c`.

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
`/private/tmp/pcileech-completion/upstream/CaptainDMA/100t484-1`. Board top and
project TCL wiring are pending. Build the
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

`req_rx_cpl` (§7 completion match/progress/restore, fixed-latency pipeline), then
`req_err` (§9 FIFO),
status counters + the `pcileech_fifo.sv` `ro` map (§9), `drp_startup` (§11). Then wire
into the board top + project TCL, build the parent `RequesterTrackingPlan`/emitter/
manifest, run `hardware-safety-reviewer`, and the R2–R6 gates.
**ask before committing** and use **no Co-Authored-By trailer**.
