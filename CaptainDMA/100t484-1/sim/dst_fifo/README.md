# PCIe-to-SYS TLP FIFO prefetch (`pcileech_tlps128_dst_fifo`)

`pcileech_mux` pulls with `rx_rd_en` in cycle n and writes only the response
present in cycle n+1. Previously that response came straight from the
`fifo_134_134_clk2` block-RAM output (standard mode, no output register): the
per-DW `tkeepdw` decode, the reset-window gate and the mux's nine-stage index
ripple all sat behind block-RAM clock-to-out, and that was the worst `net_clk`
path (+0.028 to +0.420 ns across seven placer directives on board `e210d72`).

The SYS side now reads up to three beats ahead into a small buffer and serves
each pull from registers. A FIFO read is issued only while buffered plus
in-flight beats leave room, so the rate stays one beat per cycle. The reset
window flushes the buffer (`acc_sys` low), and the output lanes are gated with
`rst` so nothing is presented in any cycle in which the old combinational mask
(`acc_sys = ok_sys && !rst`) would have dropped it. The write side is
unchanged.

## Bench

`tb_dst_mux.sv` runs the frozen reference (`dst_fifo_reference.sv`, the module
as of `e210d72`) and the new module side by side from the same PCIe RX stream,
reset pulses and consumer ready, each driving a real `pcileech_mux`, with the
real `fifo_134_134_clk2` simulation model, `xpm_cdc` and reset-window logic.

- Writes into both FIFOs must be identical (write side unchanged).
- At the dfifo/mux boundary (lanes accepted while the mux `en` is high),
  each design delivers its written DWs in order with the written first/last
  flags; a written DW may be skipped only if it is older than a reset.
- Pull contract: a lane is valid only in the cycle after `rx_rd_en`.
- No lane is presented with data older than the design's last read-side
  flush.
- Phase A (no resets, random consumer): everything delivered, nothing skipped.
- Phase B (preloaded FIFO, full-rate drain): prefetch cycles <= reference + 4.
- Phase C (60 random reset pulses of 1-4 cycles): nothing written after the
  last window is skipped; everything is delivered.
- Phase D (consumer always ready): the mux output, decoded back into DWs,
  matches the accepted stream exactly.

Stock `pcileech_mux` output is exact only while `rd_en` stays high: `en`
lags `rd_en` by one cycle, so around `rd_en` transitions a completed word
can be lost (`rd_en` falls as it becomes valid) or the buffered word
repeated (`rd_en` rises while `en` is still low). The bench counts these
outside phase D (`stock_mux_anomalies`) for both designs at similar rates;
they are a property of the unchanged mux, not of this change. On the board
`rd_en` is `com_din_ready`.

## Running

```sh
# From CaptainDMA/100t484-1, in a Vivado 2026.1 environment:
python3 sim/dst_fifo/run_dst_mux.py --vivado "$XILINX_VIVADO" --board . \
  --generated-ip /path/to/project.gen/sources_1/ip --out /path/to/new-run
# Mutants (each must fail for its stated reason):
for m in no_pull_gate deep_prefetch no_flush no_rst_out_gate no_inflight_count; do
  python3 sim/dst_fifo/run_dst_mux.py ... --mutant $m --seeds 2 --out /path/to/mut-$m
done
```

Each run covers `--seeds` seeds at three PCIe/SYS clock ratios (62.5/100,
62.5/55.6 and 62.5/64.9 MHz). Outputs must be new directories.
