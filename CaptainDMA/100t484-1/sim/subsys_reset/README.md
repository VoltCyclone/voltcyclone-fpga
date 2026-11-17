# PCIe subsystem FIFO reset bench

`tb_subsys_vendor.sv` runs the production `pcileech_pcie_a7_rst`,
`pcileech_pcie_cfgword_cdc` and the four modules that own the seven
clk_sys <-> clk_pcie FIFOs reset by the PCIe subsystem reset:

| FIFO | Owner | Write / read clock |
| --- | --- | --- |
| `fifo_64_64` (cfg_tx) | `pcileech_pcie_cfg_a7` | clk_sys / clk_pcie |
| `fifo_32_32_clk2` (cfg_rx) | `pcileech_pcie_cfg_a7` | clk_pcie / clk_sys |
| `fifo_49_49_clk2` (shd_req) | `pcileech_tlps128_cfgspace_shadow` | clk_sys / clk_pcie |
| `fifo_43_43_clk2` (shd_rsp) | `pcileech_tlps128_cfgspace_shadow` | clk_pcie / clk_sys |
| `fifo_134_134_clk2` (dst) | `pcileech_tlps128_dst_fifo` | clk_pcie / clk_sys |
| `fifo_134_134_clk2_rxfifo` (src_data) | `pcileech_tlps128_src_fifo` | clk_sys / clk_pcie |
| `fifo_1_1_clk2` (src_tok) | `pcileech_tlps128_src_fifo` | clk_sys / clk_pcie |

The FIFOs, the shadow BRAM/DROM and `fifo_129_129_clk1` are functional
netlists exported from the project's out-of-context checkpoints
(`export-models.tcl`). They model the IP logic, not metastability.

A monitor bound to every FIFO checks the reset contract of these IPs
(independent clocks, asynchronous reset with reset synchronization, no safety
circuit; PG057 Fig 3-30, pp. 127-131):

- `SUBSYS_NOACCESS`: `wr_en`/`rd_en` while `rst` is high, or before 30 edges
  of both clocks have passed since it fell;
- `SUBSYS_RST_SHORT`: `rst` high for fewer than 6 edges of either clock;
- `SUBSYS_RST_GAP`: `rst` raised again fewer than 6 edges of either clock
  after it fell (6 is local policy, as for the COM FIFOs).

TX path: the host bit goes through the production `pcileech_pcie_tx_drain`,
and the production TX mux merges cfg responses, a BAR response model, the
host TX FIFO and the static TLP source. At the mux output, a packet may be
cut (by a reset or by a new first beat) only by an abort reset (global rst,
PERST#, core reset, core user reset), which also flushes the downstream gate
and converter (`SUBSYS_TX_CUT`); no beat may appear while the mux reports
idle; BAR and static TLP packets stay well formed; every host request is
applied within 30 us (`SUBSYS_DRAIN_STUCK`), and with clk_pcie stopped before
the clock returns (`SUBSYS_DRAIN_EXPECT_DEAD`); the drain skips the stop only
when the bench's clock model has clk_pcie stopped (`SUBSYS_DRAIN_FALSE_DEAD`).

Release checks on `pcileech_pcie_a7_rst`: the quarantine (`rst_subsys_sys`)
falls only after the FIFO sequence is done with no request pending
(`SUBSYS_QUAR_EARLY`), and only after the clk_pcie subsystem reset and the
FIFO pins have been released (`SUBSYS_RELEASE_ORDER`).

Four scoreboards keep traffic in every FIFO through the resets: host TX
packets (src), PCIe RX packets (dst), cfg read commands and replies, and
shadow reads. They check order, duplicates, stale delivery across a reset,
loss of anything offered 3 us after recovery, and that shadow read data never
changes. Packets cut at a FIFO output by a reset are counted, not failed.

Cases: 0 mixed reset sources with running clocks; 1 clk_pcie stopping and
resuming, with and without the core user reset; 2 adjacent requests 0-20
clk_sys cycles after the previous request ended (host subsystem reset and the
undrained core reset) and after the quarantine ended, and a second request
during reset; 3 frequent host subsystem resets during heavy TX with
downstream stalls; 4 single-beat static TLPs (cfg_a7, series of three) with
host subsystem resets in between, plus a malformed two-beat static TLP that
must not be armed (`SUBSYS_STATIC_MALFORMED_SENT`). `--matrix` repeats
them with clk_pcie at 62.5, 125 and 83 MHz.

```sh
# On the Vivado host (2026.1), from a directory holding a copy of the board:
vivado -mode batch -source board/sim/subsys_reset/export-models.tcl \
  -tclargs /path/to/project.runs models
python3 board/sim/subsys_reset/run_subsys.py --vivado "$XILINX_VIVADO" \
  --board board --models models --out run --matrix
for m in fifo_rst_follows_request no_fifo_reset quarantine_ignores_sequence release_before_pcie \
         cfg_tx_write_ungated cfg_rx_read_ungated shd_req_read_always \
         drain_no_stop drain_skips_idle mux_ignores_stop drain_ignores_dead_clock \
         static_old_end static_withdraw_on_disable \
         static_arm_unchecked static_old_valid; do
  python3 board/sim/subsys_reset/run_subsys.py --vivado "$XILINX_VIVADO" \
    --board board --models models --out mut-$m --mutant $m
done
```

The runner rewrites the staged copy of the `_bs16` header macro for XSim,
which cannot index a concatenation; its only use passes an identifier.
