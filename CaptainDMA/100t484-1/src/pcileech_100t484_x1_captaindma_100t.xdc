set_property PACKAGE_PIN V20  [get_ports ft601_be[0]]
set_property PACKAGE_PIN V19  [get_ports ft601_be[1]]
set_property PACKAGE_PIN W20  [get_ports ft601_be[2]]
set_property PACKAGE_PIN AB20 [get_ports ft601_be[3]]
set_property PACKAGE_PIN H20  [get_ports ft601_data[0]]
set_property PACKAGE_PIN H22  [get_ports ft601_data[1]]
set_property PACKAGE_PIN J21  [get_ports ft601_data[2]]
set_property PACKAGE_PIN J22  [get_ports ft601_data[3]]
set_property PACKAGE_PIN K21  [get_ports ft601_data[4]]
set_property PACKAGE_PIN K22  [get_ports ft601_data[5]]
set_property PACKAGE_PIN L21  [get_ports ft601_data[6]]
set_property PACKAGE_PIN N18  [get_ports ft601_data[7]]
set_property PACKAGE_PIN M18  [get_ports ft601_data[8]]
set_property PACKAGE_PIN L20  [get_ports ft601_data[9]]
set_property PACKAGE_PIN L19  [get_ports ft601_data[10]]
set_property PACKAGE_PIN M20  [get_ports ft601_data[11]]
set_property PACKAGE_PIN M22  [get_ports ft601_data[12]]
set_property PACKAGE_PIN M21  [get_ports ft601_data[13]]
set_property PACKAGE_PIN N22  [get_ports ft601_data[14]]
set_property PACKAGE_PIN N20  [get_ports ft601_data[15]]
set_property PACKAGE_PIN P15  [get_ports ft601_data[16]]
set_property PACKAGE_PIN T21  [get_ports ft601_data[17]]
set_property PACKAGE_PIN R16  [get_ports ft601_data[18]]
# OLD  ft601_data[19]
set_property PACKAGE_PIN T20  [get_ports ft601_data[19]]
# NEW  ft601_data[19]
#set_property PACKAGE_PIN T18  [get_ports ft601_data[19]]
set_property PACKAGE_PIN U17  [get_ports ft601_data[20]]
set_property PACKAGE_PIN U20  [get_ports ft601_data[21]]
set_property PACKAGE_PIN U21  [get_ports ft601_data[22]]
set_property PACKAGE_PIN V22  [get_ports ft601_data[23]]
set_property PACKAGE_PIN W22  [get_ports ft601_data[24]]
set_property PACKAGE_PIN W21  [get_ports ft601_data[25]]
set_property PACKAGE_PIN Y22  [get_ports ft601_data[26]]
set_property PACKAGE_PIN Y21  [get_ports ft601_data[27]]
set_property PACKAGE_PIN AB22 [get_ports ft601_data[28]]
set_property PACKAGE_PIN AA21 [get_ports ft601_data[29]]
set_property PACKAGE_PIN AB21 [get_ports ft601_data[30]]
set_property PACKAGE_PIN AA20 [get_ports ft601_data[31]]
set_property PACKAGE_PIN W17  [get_ports ft601_oe_n]
set_property PACKAGE_PIN P16  [get_ports ft601_rd_n]
set_property PACKAGE_PIN AA18 [get_ports ft601_rxf_n]
set_property PACKAGE_PIN AB18 [get_ports ft601_siwu_n]
set_property PACKAGE_PIN AA19 [get_ports ft601_txe_n]
set_property PACKAGE_PIN W19  [get_ports ft601_wr_n]
set_property PACKAGE_PIN N13  [get_ports ft601_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports {ft601_txe_n ft601_rxf_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {{ft601_be[*]} {ft601_data[*]}}]
set_property IOSTANDARD LVCMOS33 [get_ports {ft601_wr_n ft601_rd_n ft601_oe_n ft601_siwu_n ft601_rst_n}]
set_property SLEW FAST [get_ports {{ft601_be[*]} {ft601_data[*]}}]
set_property SLEW FAST [get_ports {ft601_wr_n ft601_rd_n ft601_oe_n ft601_siwu_n ft601_rst_n}]

set_property PACKAGE_PIN G21 [get_ports user_ld1_n]
set_property PACKAGE_PIN G22 [get_ports user_ld2_n]
set_property PACKAGE_PIN F19 [get_ports user_sw1_n]
set_property PACKAGE_PIN F20 [get_ports user_sw2_n]
set_property IOSTANDARD LVCMOS33 [get_ports {user_ld1_n user_ld2_n user_sw1_n user_sw2_n}]

# SYSCLK
set_property PACKAGE_PIN J19 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name net_clk -waveform {0.000 5.000} [get_ports clk]

# FT601 CLK
create_clock -period 10.000 -name net_ft601_clk -waveform {0.000 5.000} [get_ports ft601_clk]
set_property IOSTANDARD LVCMOS33 [get_ports ft601_clk]
set_property PACKAGE_PIN K18 [get_ports ft601_clk]

# FTDI FT600/FT601 datasheet v1.06 table 4.2: at 100 MHz, input arrival
# spans 3.5..7.0 ns; receiver setup/hold are 1.0/4.8 ns. SDC represents
# the positive external hold requirement with NEGATIVE output -min.
# AN_421's 6.5/+4.8 example values do not express these datasheet limits.
# These device-pin values still assume zero board delay. Board qualification
# must add clock/data trace mismatch to inputs and round-trip delay to outputs;
# the board trace delays have not been measured or established here.
set_input_delay -clock [get_clocks net_ft601_clk] -min 3.5 [get_ports {ft601_data[*]}]
set_input_delay -clock [get_clocks net_ft601_clk] -max 7.0 [get_ports {ft601_data[*]}]
set_input_delay -clock [get_clocks net_ft601_clk] -min 3.5 [get_ports ft601_rxf_n]
set_input_delay -clock [get_clocks net_ft601_clk] -max 7.0 [get_ports ft601_rxf_n]
set_input_delay -clock [get_clocks net_ft601_clk] -min 3.5 [get_ports ft601_txe_n]
set_input_delay -clock [get_clocks net_ft601_clk] -max 7.0 [get_ports ft601_txe_n]

set_output_delay -clock [get_clocks net_ft601_clk] -max 1.0 [get_ports {ft601_wr_n ft601_rd_n ft601_oe_n}]
set_output_delay -clock [get_clocks net_ft601_clk] -min -4.8 [get_ports {ft601_wr_n ft601_rd_n ft601_oe_n}]
set_output_delay -clock [get_clocks net_ft601_clk] -max 1.0 [get_ports {{ft601_be[*]} {ft601_data[*]}}]
set_output_delay -clock [get_clocks net_ft601_clk] -min -4.8 [get_ports {{ft601_be[*]} {ft601_data[*]}}]

set_property IOB TRUE [get_cells i_pcileech_com/i_pcileech_ft601/FT601_OE_N_reg]
set_property IOB TRUE [get_cells i_pcileech_com/i_pcileech_ft601/FT601_RD_N_reg]
set_property IOB TRUE [get_cells i_pcileech_com/i_pcileech_ft601/FT601_WR_N_reg]
# Data OFFs and tristate TFFs request IOB packing on their RTL instances.

# Per-pin FT601 tristate registers are timed as ordinary single-cycle outputs.
# The former OE_reg multicycle exception does not apply to these registers.
# Clock-domain crossings are made in RTL with XPM synchronizers (xpm_cdc_single,
# xpm_cdc_async_rst, xpm_cdc_handshake), which carry their own scoped
# constraints. The only additional internal exception is the documented
# asynchronous PCIe IP reset boundary below; no clock groups are disabled.
#
# Asynchronous board inputs with no clock relationship, each feeding only its
# XPM synchronizer in pcileech_100t484_x1_top:
#   user_sw2_n   - pushbutton -> xpm_cdc_single (D pin of the first ASYNC_REG stage)
#   pcie_present - slot PRSNT# status level -> xpm_cdc_single (D pin of the first stage)
#   pcie_perst_n - PERST# -> xpm_cdc_async_rst: drives the asynchronous
#                  clear/preset pins of ALL its reset stages (asynchronous
#                  assert, clk release), possibly through an inverter.
# Synthesized fanout was checked on Vivado 2026.1: the two level inputs
# reach only stage-0 D, and PERST# reaches the four reset-stage CLR pins.
set_false_path -from [get_ports user_sw2_n] -to [get_pins -hier -filter {NAME == "i_cdc_user_sw2_n/syncstages_ff_reg[0]/D"}]
set_false_path -from [get_ports pcie_present] -to [get_pins -hier -filter {NAME == "i_cdc_pcie_present/syncstages_ff_reg[0]/D"}]
set_false_path -from [get_ports pcie_perst_n] -to [get_pins -hier -filter {NAME =~ i_cdc_pcie_perst_n/arststages_ff_reg*/CLR}]

# PG054 System Interface defines sys_rst_n as asynchronous. AMD's 2026.1
# pcie_7x_v3_3/ttcl/xilinx_pcie_2_1_7x_x0y0_xdc.ttcl exempts that input in
# the example design. Here its source is a clk_sys register, so restrict the
# equivalent exception to that register AND this IP reset input. Routed
# all_fanout/report_exceptions verified seven endpoints, all inside this IP.
# Reset pulse duration is enforced in pcileech_pcie_a7_rst; this exception
# does not waive any FIFO reset crossing or user logic timing path.
set_false_path -from [get_pins i_pcileech_pcie_a7/i_pcileech_pcie_a7_rst/rst_pcie_n_reg/C] -through [get_pins i_pcileech_pcie_a7/i_pcie_7x_0/sys_rst_n]
# Outputs with no clock relationship to any external device:
#   user_ld1_n, user_ld2_n - indicator LEDs
#   ft601_rst_n            - FT601 RESET_N, an asynchronous reset input of the
#                            FT601, driven by the rst register in clk (glitch-free,
#                            at least 65 clk periods low)
set_false_path -to [get_ports {user_ld1_n user_ld2_n ft601_rst_n}]

#PCIe signals
set_property PACKAGE_PIN A13 [get_ports pcie_present]
set_property PACKAGE_PIN C13 [get_ports pcie_perst_n]
set_property PACKAGE_PIN B13 [get_ports pcie_wake_n]
set_property IOSTANDARD LVCMOS33 [get_ports pcie_present]
set_property IOSTANDARD LVCMOS33 [get_ports pcie_perst_n]
set_property IOSTANDARD LVCMOS33 [get_ports pcie_wake_n]

set_property PACKAGE_PIN C9 [get_ports {pcie_rx_n[0]}]
set_property PACKAGE_PIN D9 [get_ports {pcie_rx_p[0]}]
set_property PACKAGE_PIN C7 [get_ports {pcie_tx_n[0]}]
set_property PACKAGE_PIN D7 [get_ports {pcie_tx_p[0]}]

set_property PACKAGE_PIN E10 [get_ports pcie_clk_n]
set_property PACKAGE_PIN F10 [get_ports pcie_clk_p]

create_clock -name pcie_sys_clk_p -period 10.0 [get_nets pcie_clk_p]

set_property CFGBVS Vcco [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 66 [current_design]