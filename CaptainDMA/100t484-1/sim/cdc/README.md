# CDC findings: endpoint-scoped disposition (CaptainDMA 100T)

This covers every Critical and Warning finding from `report_cdc` on the routed
design. `check_cdc.tcl` reruns the report on a routed checkpoint and fails if
any finding is new, or if an expected finding is missing:

```
vivado -mode batch -source sim/cdc/check_cdc.tcl -tclargs <routed.dcp> [report_dir]
```

It prints `CDC_CHECK_PASS`, or `CDC_CHECK_FAIL` and exits with status 1. It
also fails in these cases:

- a CDC-11 synchronizer has a stage count other than 2 (groups A and B) or 4
  (group C), or a stage without `ASYNC_REG`;
- a CDC-15 finding's start or end is outside its own FIFO;
- the Info counts are not exactly CDC-3 = 43 and CDC-9 = 7, or another Info
  ID appears;
- there is any waiver other than FIFO Generator's own CDC-1 waivers on the
  listed distributed-RAM FIFOs. Three are present: COM RX, and the shadow 43
  and 49 FIFOs;
- `check_timing` reports `no_clock` or `unconstrained_internal_endpoints`,
  which `report_cdc` cannot see.

A fail means the structure has changed, and the reasoning below must be redone
for the new endpoints. Do not extend the expected lists without that.

**A pass pins the CDC structure, not the RTL gating.** The disposition also
relies on these points, and an edit to any of them needs this review again
even when the checker passes:

- the FIFO enables in `pcileech_com.sv`, and `done`, `done_com` and `run_com`
  in its `g_fifo_replay` block;
- `pcileech_com_fifo_reset`;
- `rst_subsys_sys` and `i_fifo_reset` in `pcileech_pcie_a7_rst`;
- `pcileech_tlps128_fifo_rst_window`;
- every `acc_sys` and `acc_pcie` gate in `pcileech_pcie_cfg_a7.sv`,
  `pcileech_tlps128_cfgspace_shadow.sv` and `pcileech_pcie_tlp_a7.sv`.

The disposition was made on board `55e1f8a` (same RTL as `207e610`), on the
routed checkpoints of the `Default` and `ExtraTimingOpt` placer variants. It
was re-checked after the FT601 follow-ups (RX hold, `tx_order_err` status
bit): the only change was the new CDC-3 synchronizer, and the checker passes on
both variants.

|   ID   | Severity | Count |                                                             Disposition                                                              |
|--------|----------|-------|--------------------------------------------------------------------------------------------------------------------------------------|
| CDC-11 | Critical | 13    | Accepted per endpoint (groups A-C below)                                                                                             |
| CDC-15 | Warning  | 206   | Accepted: FIFO Generator read register, one per connected output bit                                                                 |
| CDC-3  | Info     | 43    | 1-bit synchronizers with `ASYNC_REG`. The 43rd (2026-11-18) is `g_ft601_phy.i_cdc_tx_order_err`, the status-only `tx_order_err` flag |
| CDC-9  | Info     | 7     | Async reset synchronizers with `ASYNC_REG`                                                                                           |

## CDC-11: fan-out from a launch flop to one destination clock

Each endpoint is the asynchronous preset of stage 0 of a reset synchronizer:

- inside a FIFO Generator FIFO, the `rst_rd_reg2_inst` or `rst_wr_reg2_inst`
  block, with **2** stages;
- or the `i_cdc_rst_pcie` of a `pcileech_tlps128_fifo_rst_window`, with **4**
  stages.

All stages carry `ASYNC_REG`. On its own, each crossing is a standard async
reset synchronizer. The finding is about **reconvergence**: one launch register
feeds several independent synchronizers in the same destination clock, so
their outputs can release up to one destination edge apart. A synchronizer
releases within (stages + 1) edges of the launch falling.

Each finding is safe if no destination logic can act in the cycles where one
copy is released and another is not. Every group below gates destination-side
access for far longer than that.

### Group A: COM FIFO reset sequencer → `ft601_c0` (2)

Launch: `i_pcileech_com/g_fifo_replay.i_reset/fifo_rst_reg` (`net_clk`,
`pcileech_com_fifo_reset`).

|              Endpoint (stage 0 PRE)               | Synchronizer |
|---------------------------------------------------|--------------|
| COM TX FIFO `i_fifo_256_32_clk2_comtx`, read side | 2 stages     |
| COM RX FIFO `i_fifo_64_64_clk2_comrx`, write side | 2 stages     |

- **When the copies release:** each FIFO's `c0` side leaves reset ≤ 3 `c0`
  edges after `fifo_rst` falls.
- **When access opens:** both `c0`-side enables are gated by `fifo_run_com`
  (`pcileech_com.sv`):
  - COM RX `wr_en` (`com_rx_valid64 && fifo_run_com`);
  - COM TX `rd_en` (`~com_tx_almost_full && fifo_run_com`).

  `fifo_run_com` is a register of `done_com`, which is `done` passed through a
  4-stage `xpm_cdc_single`. The sequencer raises `done` only after `POST_LOW`,
  which counts 6 full periods of **both** clocks after `fifo_rst` falls. The
  first `c0` access is therefore ≥ 6 + 4 + 1 = 11 `c0` edges after the
  release.
  Counting the handshake round trips, the real minimum is about 20 `c0`
  edges. CDC needs about 3. The COM FIFOs follow the project's six-period
  policy rather than PG057's 30-cycle no-access zone, which the PCIe windows
  use. That functional choice is covered by the vendor-model benches.

- **Data check:** the vendor-model COM reset benches cover this with real FIFO
  Generator models, including mutants that drop the post-release hold
  (`no_post_hold`) and shorten the gap (`short_gap`). See
  [com_reset](../com_reset/README.md), and the generator's
  `docs/development/msix-evidence/2026-11-13/com-review-followups`.

### Group B: PCIe FIFO reset sequencer → `userclk1` (7)

Launch: `i_pcileech_pcie_a7/i_pcileech_pcie_a7_rst/i_fifo_reset/fifo_rst_reg`
(`net_clk`). This is `rst_subsys_fifo`, the `rst` pin of all seven
`clk_sys`↔`clk_pcie` FIFOs.

|                      FIFO                      | Side in `userclk1` |          Window that gates it          |
|------------------------------------------------|--------------------|----------------------------------------|
| `cfg_a7` `i_fifo_pcie_cfg_rx`                  | write              | `cfg_a7/i_rst_window`                  |
| `cfg_a7` `i_fifo_pcie_cfg_tx`                  | read               | `cfg_a7/i_rst_window`                  |
| shadow `i_fifo_43_43_clk2`                     | write              | `cfgspace_shadow/i_rst_window`         |
| shadow `i_fifo_49_49_clk2`                     | read               | `cfgspace_shadow/i_rst_window`         |
| `dst_fifo` `i_fifo_134_134_clk2`               | write              | `dst_fifo/i_rst_window`                |
| `src_fifo` `i_fifo_134_134_clk2_rxfifo` (data) | read               | `src_fifo/i_rst_window`                |
| `src_fifo` `i_fifo_1_1_clk2` (token)           | read               | `src_fifo/i_rst_window` (same as data) |

- **When the copies release:** each FIFO's `clk_pcie` side leaves reset ≤ 3
  `clk_pcie` edges after `rst_subsys_fifo` falls.
- **When access opens:** `rst_subsys_sys`, each window's `rst`, falls one
  `clk_sys` cycle after the sequencer's `done`. `done` comes after `POST_LOW`:
  6 full periods of both clocks after the pin falls. Each window's `clk_pcie`
  side then releases through its own 4-stage synchronizer and counts 30
  `clk_pcie` cycles. It opens (`acc_pcie`) only once the `clk_sys` side has
  also counted 30 cycles, and that crosses through another 4-stage
  synchronizer. The first `clk_pcie` access is therefore ≥ 6 + 4 + 30 = 40
  `clk_pcie` edges after the release.
- **Data and token stay coherent:** the TLP TX data FIFO and its token FIFO
  share one pin and one window. Neither can be written or read until both are
  out of reset and the window has opened, so the token count cannot get ahead
  of the data.
- **Data check:** the subsystem bench (`sim/subsys_reset`, real FIFO Generator
  models) checks at every pin of all seven FIFOs that there is no access from
  `rst` rising until 30 edges of both clocks after it falls. It does this in
  9 runs, including a stopped `clk_pcie`, with mutants that ungate each side.
  See the generator's `docs/development/msix-evidence/2026-11-16/subsys-fifo-reset`.

### Group C: subsystem quarantine → reset windows, `userclk1` (4)

Launch: `i_pcileech_pcie_a7/i_pcileech_pcie_a7_rst/rst_subsys_sys_reg`
(`net_clk`).

Endpoints: `i_rst_window/i_cdc_rst_pcie` (4 stages) in `cfg_a7`,
`cfgspace_shadow`, `dst_fifo` and `src_fifo`.

- **When the copies release:** the four windows' `clk_pcie` sides may start
  counting one edge apart.
- **Why the skew is harmless:** each window's `acc_sys` and `acc_pcie` gate
  only the FIFOs of its own module. No logic combines two windows' outputs
  (checked by grep over `src/`, `acc_pcie|acc_sys`). A window opening one
  cycle before another affects only its own independent channel.
- **Order against group B:** every window releases after the group B release
  (see above), so a window cannot open on a FIFO still in reset.

## CDC-15: clock-enable-controlled crossing, Warning (206)

All 206 findings sit inside the four **distributed-RAM** independent-clock
FIFOs. Each finding is one read-side output register bit: the LUTRAM is
written in the write clock and captured in the read clock with CE = `rd_en`.
FIFO Generator reads a word only after its write has crossed through the
gray-coded pointer synchronizers, so the RAM output is stable when captured.
The IP's own constraints time these paths as `Max Delay Datapath Only`.

|                     FIFO                     |       Direction        | Findings | Connected `dout` bits |
|----------------------------------------------|------------------------|----------|-----------------------|
| `i_fifo_64_64_clk2_comrx`                    | `ft601_c0` → `net_clk` | 64       | 64                    |
| `cfg_a7` `i_fifo_pcie_cfg_tx` (`fifo_64_64`) | `net_clk` → `userclk1` | 50       | 50 of 64              |
| shadow `i_fifo_43_43_clk2`                   | `userclk1` → `net_clk` | 43       | 43                    |
| shadow `i_fifo_49_49_clk2`                   | `net_clk` → `userclk1` | 49       | 49                    |

The block-RAM FIFOs have no CDC-15 findings. The distributed-RAM token FIFO
`i_fifo_1_1_clk2` has none either, because its `dout` has no load: only the
empty flag is used.

## Review

An independent hardware-safety review checked the argument against the RTL
and found no blockers.

- It found no destination-side enable or valid of the nine FIFOs that is not
  gated by `fifo_run_com` or `acc_*`.
- It found no logic that combines two windows' outputs.
- No logic combines the two COM FIFOs' flags.
- In group B, the full flags are used only behind `acc_*`. `src_fifo` checks
  both data and token full at a packet's first DW, so the two cannot diverge.
- The 50 used `cfg_tx` bits match the consumers in `pcileech_pcie_cfg_a7.sv`.

Its checker hardening is applied:

- exit status;
- stage count and `ASYNC_REG` on all stages;
- CDC-15 startpoints;
- pinned Info counts;
- waivers;
- `check_timing`.

It noted one functional point that is not a CDC hazard. Because the windows can
open a few cycles apart, a TLP or command arriving in those cycles can be
dropped. This is the documented drop at a FIFO reset.

## Verification of the checker

- `Default` and `ExtraTimingOpt` give `CDC_CHECK_PASS` with exit status 0.
  That covers 24 checks:
  - 13 CDC-11, in groups A/B/C of 2/7/4;
  - the 4 CDC-15 FIFOs;
  - 3 IP waivers;
  - 2 `check_timing` categories;
  - 2 Info counts.
- Negative control: one expected CDC-11 pair and one CDC-15 FIFO were removed
  from the lists. The checker reports, and exits with status 1:
  - that pair as unexpected;
  - the FIFO's 49 findings as unexpected;
  - that FIFO's waiver as unexpected.

## Not covered

- The FIFO-internal synchronizer depth (2 stages) and its MTBF are the IP
  configuration's. They are unchanged here.
- No bitstream and no hardware run.

