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
backs up. The fix queues every completed word (four entries) and presents the
head while `rd_en` is high. Words reach the COM FIFO one cycle later than
before; `valid` still never rises while `rd_en` is low.

## Checks

- `run_mux_ready.py` (iverilog): `tb_mux_ready.sv` drives the ports as the
  board does (a 1..4-DW TLP beat on p3..p6, sparse p0..p2, p7 unused, at most
  seven DWs per cycle, the mux output capacity) and requires every DW once, in
  order, with its ctx. Modes: random ready, long ready/not-ready runs
  (almost-full-like), ready held. The current mux passes all modes and seeds;
  the frozen stock mux (`pcileech_mux_stock.sv`) must fail the two toggling
  modes and pass with ready held.
- `prove_mux_oq.py` (SymbiYosys, `abc pdr`): queue occupancy never exceeds
  three for any `rd_en` and port pattern after reset; a two-entry bound must
  fail (the bound is reached).
- `../dst_fifo/run_dst_mux.py` also checks the decoded mux output exactly,
  with `--mutant stock_mux` as a control.

The mux assumes at most seven DWs per cycle across its ports on average (it
has no input backpressure); that is unchanged.
