# FT601 MMCM PHY: simulation

Tests for `src/pcileech_ft601_phy.sv` (245 synchronous FIFO master on the
compensated c0/c180 clocks) and `src/pcileech_ft601_clk.sv` (MMCM and its reset
controller). The legacy `pcileech_ft601.sv` stays selectable with the top-level
generic `FT601_PHY_MMCM = 0`; it is not tested here.

## Requirements

Icarus Verilog (`-g2012`), for example from the OSS CAD Suite. Run from this
directory:

```sh
export PYTHONDONTWRITEBYTECODE=1 PATH=/usr/local/oss-cad-suite/bin:$PATH
python3 run_ft601.py
```

Expected output ends with `FT601_RUN_PASS` lines and
`FT601_MUT killed=14 total=14`.

## Files

| File | Purpose |
|---|---|
| `ft601_model.sv` | FT601 slave model built from datasheet v1.06 Figures 4.6–4.8 and Table 4.2. Outputs change 3.5–7.0 ns after each edge (random within the corner). A read word moves only where RXF_N and RD_N are both low; a write is accepted only where WR_N and TXE_N are both low. It checks the FPGA's 1.0 ns setup and 4.8 ns hold on every FPGA-driven pin, and releases the bus `T_HIZ` after it samples OE_N high. |
| `prims_model.sv` | Ideal Icarus models of FDRE, FDPE, IOBUF, OBUFT, IBUF, BUFG, `xpm_cdc_async_rst` and an MMCME2_ADV whose LOCKED drops 30 periods after CLKINSTOPPED. Vivado signs off real timing. |
| `tb_ft601_phy.sv` | PHY against the model with c0/c180 at 0.5/5.5 ns and zero board delay. It checks exactly-once, in-order delivery in both directions, bus contention, the queue invariant and asynchronous pad release. |
| `tb_ft601_clk.sv` | Reset controller: lock-up, clock loss and recovery (four times), an MMCM reset of at least 5 ns released after the clock returns, and `rst`. |
| `run_ft601.py` | Runs the PHY bench at four corners × four scenarios × three seeds, plus the clock bench, then 14 mutants. Each mutant must fail at least one run; a mutant that does not compile counts as a survivor. |

## PHY scenarios

| `+SCEN=` | What it does |
|---|---|
| 0 | One 100-word RX burst, then 200 TX words |
| 1 | 60 random RX bursts with continuous TX; the model fills every 24 words, so TXE_N refusals and rewinds happen tens of times per run |
| 2 | Twenty isolated single-word RX and TX transfers |
| 3 | Reset with the clocks stopped mid-traffic, a check that the pads release at once, then recovery and exact transfers |

## Corners

| TCO (ns) | T_HIZ (ns) | Purpose |
|---|---|---|
| 3.5–7.0 | 6 | Datasheet output window, random per edge |
| 3.5 | 6 | Earliest FT601 output |
| 7.0 | 6 | Latest FT601 output |
| 3.5–7.0 | 25 | Slowest bus release the 3-cycle guard tolerates |

With `T_HIZ` = 26 ns the contention check fires on every RX exit. That is the
expected limit of `GUARD_CYCLES = 3`: the FPGA drives again 25.5 ns after the
FT601 samples OE_N high.

## Assumptions these tests do not remove

The FT601 datasheet does not specify the following, so they are design
assumptions to be confirmed on hardware:

- the FT601 releases DATA/BE within 25.5 ns of sampling OE_N high;
- TXE_N, once high, stays high for at least two cycles (otherwise
  `tx_order_err` is set and the bench fails);
- the FT601 CLK duty cycle and jitter are within the MMCM input limits;
- board clock-to-data skew is within the routed timing margins.
