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
| `tb_ft601_phy.sv` | PHY against the model with c0/c180 at 0.5/5.5 ns and zero board delay. It checks exactly-once, in-order delivery in both directions, bus contention, the queue invariant, asynchronous pad release, and that `dout_valid` stays low while `rst` is held. An RX word counts as delivered at a `c0` edge with `rst` low, which is where the COM RX FIFO would write it. |
| `tb_ft601_clk.sv` | Reset controller: lock-up, clock loss and recovery (four times), an MMCM reset of at least 5 ns released after the clock returns, and `rst`. |
| `run_ft601.py` | Runs the PHY bench at four corners × six scenario settings × three seeds (72 runs; scenario 4 at `LOSS_NS` 80 and 120), plus the clock bench, then 17 mutants. `rx_hold_six` (`RX_HOLD` = 6) passes at 80 ns and fails at 120 ns, so the hold keeps margin beyond the model. Each mutant must fail at least one run; a mutant that does not compile counts as a survivor. |

## PHY scenarios

| `+SCEN=` | What it does |
|---|---|
| 0 | One 100-word RX burst, then 200 TX words |
| 1 | 60 random RX bursts with continuous TX; the model fills every 24 words, so TXE_N refusals and rewinds happen tens of times per run |
| 2 | Twenty isolated single-word RX and TX transfers |
| 3 | Reset with the clocks stopped mid-traffic, a check that the pads release at once, then recovery and exact transfers |
| 4 | Clock loss with MMCM holdover: the FT601 clock stops inside an RX burst while `c0`/`c180` keep running, and `arst` follows `+LOSS_NS` later (default 80). No word the FT601 did not transfer may be delivered. Then recovery as in 3 |

### Clock loss (scenario 4)

A real MMCM's outputs after input loss are undocumented, so the bench assumes
the worst case: `c0` keeps running at the nominal period while the pins stay
frozen. A read burst then leaves RXF_N low and the next word on DATA, and every
`c0` edge looks like a new read word.

The 80 ns default is the `phy_not_ready` latency, the sum of:

- the model's CLKINSTOPPED, up to 40 ns;
- three `clk` synchronizer edges plus the FSM register, up to 40 ns.

`pcileech_ft601_phy` holds each RX word for `RX_HOLD` = 12 `c0` cycles in
registers that `rst` clears. Any word sampled after the last FT601 edge is
therefore discarded, provided the reset comes in time.

| PHY | `+LOSS_NS` | Result |
|---|---|---|
| Before the hold | 80 | 15 words delivered, 10 transferred: 5 stale repeats |
| `RX_HOLD` = 12 | 80, 130, 150 | Pass. Stale words are discarded, along with up to 7 transferred words that were still in the hold. |
| `RX_HOLD` = 12 | 155 and above | Fail: the limit of the hold |

Discarding transferred words at a clock loss is acceptable: the loss aborts the
COM session, which loses the words in flight anyway.

TX needs no hold. Words accepted against a frozen TXE_N belong to the COM
session that the loss aborts.

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
- TXE_N, once high, stays high for at least two cycles. Otherwise
  `tx_order_err` is set and the bench fails. On hardware, the flag sets a
  sticky status bit that the host can read: `+022` bit 2 (`ro[274]`) in the
  FPGA status register, cleared only by an FPGA reset;
- `phy_not_ready` rises within about 130 ns of the last FT601 clock edge.
  That covers MMCM stop detection and the controller, and it is the bound the
  RX hold covers;
- the FT601 CLK duty cycle and jitter are within the MMCM input limits;
- board clock-to-data skew is within the routed timing margins.
