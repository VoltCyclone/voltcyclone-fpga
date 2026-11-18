# Whole-packet capacity bench (R3)

Checks that `pcileech_tlps128_src_fifo` (host TX) and
`pcileech_tlps128_dst_fifo` (PCIe RX) never split a packet when their FIFOs
fill. Both modules admit a packet only at its first beat, and only when the
FIFO's `prog_full` is low; the threshold leaves room for the largest legal TLP.

| FIFO | Depth | `prog_full` threshold | Reserved |
| --- | --- | --- | --- |
| `fifo_134_134_clk2_rxfifo`: TX data, despite the IP name | 1023 | 763 | 258 beats + 2 in flight |
| `fifo_1_1_clk2`: TX tokens | 15 | 13 | 1 token + 2 in flight |
| `fifo_134_134_clk2`: RX data | 2047 | 1787 | 258 beats + 2 in flight |

258 beats is 1029 DW: a 4 DW header, 1024 DW of data and a 1 DW digest. The
writers cap every admitted packet at that size. TX writes DW 1029 of a longer
host packet as its last and drops the rest; RX ends at beat 258 (the PCIe core
never delivers a longer TLP). `prog_full` counts writes at once and reads only
after they cross clock domains, so it can over-report free space by at most the
2 writes of the previous packet that the flag has not shown yet. The thresholds
include those 2.

## Bench

`tb_fifo_capacity.sv` drives both modules with the exported FIFO Generator
functional models (Vivado 2026.1). Both sources are unstallable, as in
production. Both readers start with a 4000-cycle stall and then alternate
random bursts and long stalls. Every DW carries its packet id and index.

Checked, per direction (`CAP_TX_*` / `CAP_RX_*`):

- no packet starts while another is still open at the output (`CUT`);
- no DW outside a packet (`ORPHAN`);
- packets come out in admission order with every DW in place (`ORDER`);
- each packet is `min(sent, cap)` long (`LEN`);
- no write into a full FIFO (`OVERFLOW`);
- every admitted packet is delivered after the final drain (`LOST`);
- the `prog_full` budget holds (`LAG`). The bench counts each FIFO's true
  occupancy from the model pins (`wr_en && !full`, `rd_en && !empty`). At every
  write edge with `prog_full` low, occupancy may exceed threshold − 1 by at
  most 2. The maximum excess and the minimum free space are printed as
  `CAP_OCC`;
- the run refused packets, raised `prog_full`, and (cases 0 and 2) capped an
  oversize packet (`CAP_COVERAGE`).

Cases (`+CASE`):

- 0: mixed lengths, including oversize packets;
- 1: 1–2 DW packets back to back, which fill the token FIFO;
- 2: maximum and oversize packets.

The token FIFO is read into the packet counter every `clk_pcie` cycle. It fills
only when 1-DW packets arrive faster than `clk_pcie`, so case 1 requires token
`prog_full` only when `clk_pcie` is below 100 MHz.

## Running

```
python3 run_capacity.py --vivado $XILINX_VIVADO --board ../.. \
    --models <dir with the three funcsim .v models> --out <new dir>
python3 run_capacity.py ... --mutant <name>
```

The models come from the board XCIs: read each into an in-memory 2026.1 project,
`upgrade_ip`, `synth_ip`, then `write_verilog -mode funcsim`.

Over the 18 runs the maximum excess was 1 on both data FIFOs, and always
negative on the token FIFO, whose flag asserts early because reads cross into
`clk_sys` slowly. Cases 0 and 2 drove the data FIFOs down to as few as 4 free
beats (RX) and 6 (TX) without an overflow.

The matrix is 3 cases × 3 `clk_pcie` periods (16, 8, 12 ns; `clk_sys` 10 ns)
× 2 seeds = 18 runs. Mutants, each killed by one of those runs:

| Mutant | Change | Caught by |
| --- | --- | --- |
| `tx_admit_on_full` | TX admits on `full` only | case 0 |
| `tx_token_unreserved` | TX ignores token `prog_full` | case 1 |
| `tx_no_cap` | TX does not cap at 1029 DW | case 2 |
| `rx_admit_on_full` | RX admits on `full` only | case 0 |
| `rx_no_cap` | RX does not cap at 258 beats | case 2 |
