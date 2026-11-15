# `pcileech_mux` output queue

`pcileech_mux` packs port DWs into 256-bit words for the COM TX FIFO. Its
consumer ready `rd_en` is `com_din_ready`, which falls on COM TX FIFO
almost-full, and the COM side writes every cycle `valid` is high.

Ports are pulled while `rd_en` is high and answer a cycle later (`en`), and a
word completes the cycle after that (`dout_valid`), so up to two words can
still complete after `rd_en` falls. The stock code had one buffer slot that it
loaded only while `en` was low:

- a word completing in the cycle `rd_en` fell (`en` still high) was neither
  presented (`valid` is gated by `rd_en`) nor buffered: **lost**;
- when `rd_en` rose while `en` was still low, the buffered word was presented
  in that cycle and again in the next: **written twice**.

Either corrupts the 256-bit word stream to the host whenever the USB side
backs up. The fix queues every completed word (eight entries) and presents the
head while `rd_en` is high; `valid` never rises while `rd_en` is low.

For timing, port answers are also registered before packing, together with
per-port prefix counts, so each port's slot index is `idx_base + q_pre[k]`
(one 4-bit add) instead of the stock eight-stage ripple. That ripple, behind
the dst FIFO lane gate, set the worst `net_clk` path. Words reach the COM FIFO
two cycles later than stock.

## Checks

- `run_mux_ready.py` (iverilog): `tb_mux_ready.sv` drives the ports as the
  board does (a 1..4-DW TLP beat on p3..p6, sparse p0..p2, p7 unused, at most
  seven DWs per cycle, the mux output capacity) and requires every DW once, in
  order, with its ctx. Modes: random ready, long ready/not-ready runs
  (almost-full-like), ready held. The current mux passes all modes and seeds;
  the frozen stock mux (`pcileech_mux_stock.sv`) must fail the two toggling
  modes and pass with ready held.
- `prove_mux_oq.py` (SymbiYosys, `abc pdr`): queue occupancy never exceeds
  four for any `rd_en` and port pattern after reset; a three-entry bound must
  fail (the bound is reached).
- `../dst_fifo/run_dst_mux.py` also checks the decoded mux output exactly,
  with `--mutant stock_mux` as a control.

The mux assumes at most seven DWs per cycle across its ports on average (it
has no input backpressure); that is unchanged.

## Other boards

Every board that carried this stock mux now carries the identical fixed file
(CaptainDMA 35t325_x1, 35t325_x4, 35t484_x1, 75t484_x1; EnigmaX1; GBOX;
PCIeSquirrel; ScreamerM2; ZDMA/100T; ac701_ft601), so the benches here cover
them. Out-of-context synthesis on each part used (xc7a35t csg325/fgg484,
xc7a75t, xc7a100t, xc7a200t) is clean and smaller than stock: 2,310 vs 2,409
LUTs, 521 vs 767 registers (the queue maps to LUT RAM).

acorn_ft2232h, pciescreamer, NeTV2 and sp605_ft601 use an older, different mux
whose `valid` is not gated by `rd_en` (`rd_en` only throttles port requests,
and sp605 has no `rd_en`); it does not have this defect and is unchanged.
