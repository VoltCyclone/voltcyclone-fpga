# FT601 compensated clock constraints (pcileech_ft601_clk, pcileech_ft601_phy).
# Only for FT601_PHY_MMCM = 1, the default. A build with FT601_PHY_MMCM = 0
# (legacy pcileech_ft601) must leave this file out.
#
# The MMCM derives c0 (CLKOUT0, 18 deg) and c180 (CLKOUT1, 198 deg) from
# net_ft601_clk. Name them so reports and methodology checks are stable.
create_generated_clock -name ft601_c0   [get_pins -hier -filter {NAME =~ *i_ft601_clk/i_mmcm/CLKOUT0}]
create_generated_clock -name ft601_c180 [get_pins -hier -filter {NAME =~ *i_ft601_clk/i_mmcm/CLKOUT1}]

# Input capture. A word the FT601 launches at device edge E_n is valid
# 3.5..7.0 ns later and is captured by the c0 ILOGIC register at E_{n+1} + 0.5 ns,
# one c0 edge after the default. Setup only: the default hold check then
# compares the next word (earliest E_{n+1} + 3.5 ns) against that capture, a
# +0.5 ns relationship, which is the real hazard. Adding -hold 1 would compare
# against a word launched a cycle later and could never fail.
set_multicycle_path 2 -setup -end -from [get_ports {{ft601_data[*]} ft601_rxf_n ft601_txe_n}] -to [get_clocks ft601_c0]

# MMCM LOCKED and CLKINSTOPPED are asynchronous status outputs sampled by the
# ASYNC_REG synchronizers in the free-running clk domain.
set_false_path -to [get_pins -hier -filter {NAME =~ *i_ft601_clk/locked_s_reg[0]/D}]
set_false_path -to [get_pins -hier -filter {NAME =~ *i_ft601_clk/stopped_s_reg[0]/D}]
