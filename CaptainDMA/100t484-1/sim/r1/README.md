# R1 requester tracking: simulation and lint

Standalone tests for the PCIe requester tracking added to the CaptainDMA 100T
board (tag tracking, completion timeouts, error reporting, status snapshot and
the reset-held DRP startup controller). The behavioural contract these tests
enforce is maintained in the PCILeechFWGenerator repository
(`docs/development/MSIX_REQUESTER_CONTRACT.md`).

## Requirements

Icarus Verilog (`-g2012`) and Verilator 5.x on `PATH`, for example from the OSS
CAD Suite. The allocator equivalence runner also requires Yosys. Run from this directory:

```sh
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1 PATH=/usr/local/oss-cad-suite/bin:$PATH
python3 run_r1.py          # all unit benches (Icarus) + Verilator -Wall lint
python3 run_gate_axis.py   # gate/TX path/RX reset through the real interfaces
python3 lint_pcie_a7.py    # lint + clock-binding checks of integrated pcileech_pcie_a7
python3 run_a7_reset_scope.py  # requester reset scope on pcileech_pcie_a7 + its mutants
python3 prove_tagalloc.py  # SymbiYosys: offer safety + spec equivalence + negative controls
python3 mut_np_cap.py      # runtime credit sampler
python3 mut_gate.py        # mutation campaigns: each must report killed == total
python3 mut_rx.py
python3 mut_err.py
python3 mut_status.py
python3 mut_table.py
python3 mut_drp_startup.py
```

Mutation scripts edit temporary copies only; the working RTL is never changed.

## What each runner covers

| Runner | Scope |
| --- | --- |
| `run_r1.py` | One bench per module (`tb_req_*.sv`, `tb_pcie_drp_startup.sv`), some with several parameter cases (`CASES`). Each source is also linted with Verilator `-Wall`. |
| `run_gate_axis.py` | `pcileech_req_gate_axis` on real `IfAXIS128` modports (Verilator `--binary --timing`; Icarus cannot elaborate them); `tb_req_tx_path` through the width converters and host filter; `tb_rx_subsys_reset`, run with the current wiring (must pass) and with the old wiring (must fail, as a control). |
| `lint_pcie_a7.py` | Verilator lint of the integrated `pcileech_pcie_a7` with port-only stubs for vendor IP. Checks that `REQ_CLK_PCIE_HZ` reaches the timer table at 62.5 and 125 MHz and that unbound or unsupported clocks stop elaboration. |
| `run_a7_reset_scope.py` | Simulates the production `pcileech_pcie_a7` (Verilator) with the lint stubs made behavioural where resets need it: the core stub drives the user clock/reset from the bench, the `tlp_a7` stub answers `tx_stop` with `tx_idle`, and the XPM synchronizers are small models. `tb_a7_reset_scope.sv` sends host subsystem resets of several lengths on a live link (each must reach `rst_subsys`, none may reset a requester-tracker instance, `src64` or `dst64`), then a core user reset that must reach all of them. Five wiring mutants must fail. |
| `prove_tagalloc.py` | SymbiYosys proofs of the registered-offer allocator: k-induction that an offered tag is FREE whenever visible or taken, given that only `take` removes a tag from FREE (`tagalloc_safety.sv`); k-induction (bitwuzla) that every register and port matches the plain modular-scan spec `tagalloc_registered_spec.sv` (`tagalloc_equiv_top.sv` over a miter with exposed flip-flops); then four mutants that must fail. Assertions are port-level: Yosys leaves hierarchical references here as unconstrained wires. `--candidate` checks a temporary copy. `tb_req_tagalloc_spec` (in `run_r1.py`) is the fast random lockstep against the same spec. The frozen pre-registration reference and its four-state bench were retired with the registered offer (board `8f10ad1` has them). |
| `mut_*.py` | Fault injection against the real benches. `mut_table.py` covers tag lifecycle: timeout and FLR quarantine, drain interval and its start time, expiry time. Excluded equivalent mutants are named in each script's docstring. |

## Production parameters

The board top deliberately has no usable defaults for the requester and DRP plan
parameters (`REQ_CLK_PCIE_HZ`, `DRP_PLAN_*`,
`DRP_RDY_TIMEOUT_CYCLES`): elaboration stops until they are bound. The project
script sources `requester_plan.tcl`, which the generator emits from donor and
IP configuration. Values in these benches are test fixtures only.

## Simulation-only helpers

- `xpm_cdc_handshake_model.sv`: behavioural model of the XPM handshake for Icarus.
- `xpm_cdc_handshake_bbox.sv`: port-only stub for lint.

These tests establish RTL behaviour and lint only. They are not vendor-core
elaboration, synthesis, timing or hardware qualification.

The NP cap is runtime state: `pcileech_req_np_cap` samples the link partner's
initial NP-header credit once per link session (`fc_sel=101`), after the
documented two-clock selector latency. `tb_req_np_cap` covers all 256 credit
values, X/Z samples, session boundaries and no cumulative-count resampling;
`mut_np_cap.py` rejects 11 sampling/arithmetic faults. `cfg_fc_if` must be enabled
and the vendor core regenerated. Port-only stubs cannot verify that interface.
