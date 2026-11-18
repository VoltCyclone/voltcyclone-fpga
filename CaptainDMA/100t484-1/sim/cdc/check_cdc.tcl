# Endpoint-scoped CDC check for a routed CaptainDMA 100T checkpoint.
#
#   vivado -mode batch -source sim/cdc/check_cdc.tcl -tclargs <routed.dcp> [report_dir]
#
# Runs report_cdc and accepts only the findings dispositioned in
# sim/cdc/README.md. It fails if any Critical or Warning finding is new or
# missing, so a disposition never silently covers a different endpoint.
#   CDC-11: exactly the 13 launch -> first-stage pairs below. Each endpoint is
#           the PRE of stage 0 of an asynchronous reset synchronizer: two
#           stages inside a FIFO Generator reset block, or the four-stage
#           i_cdc_rst_pcie of a pcileech_tlps128_fifo_rst_window.
#   CDC-15: only inside the four distributed-RAM FIFOs below, one per
#           connected dout bit (the read-side output register, CE = rd_en).
#   Info:   only CDC-3 (42) and CDC-9 (7), synchronizers with ASYNC_REG.
# It also fails when a CDC-11 synchronizer loses a stage or ASYNC_REG on any
# stage, when a waiver other than FIFO Generator's own CDC-1 waivers on the
# listed LUTRAM FIFOs exists, and when check_timing reports registers
# without a clock or unconstrained internal endpoints (report_cdc does not
# see those). Exit status is 1 on failure. A pass pins the CDC structure only:
# the RTL gating the disposition relies on is listed in README.md and needs
# re-review when edited.
if {[llength $argv] < 1} { error "usage: -tclargs <routed.dcp> \[report_dir\]" }
set dcp [lindex $argv 0]
set out [expr {[llength $argv] > 1 ? [lindex $argv 1] : "."}]
file mkdir $out
open_checkpoint $dcp
report_cdc -details -file $out/cdc-details.rpt

set A7  i_pcileech_pcie_a7
set TLP $A7/i_pcileech_pcie_tlp_a7
set RB  U0/inst_fifo_gen/gconvfifo.rf/grf.rf/rstblk/ngwrdrst.grst.g7serrst.gnsckt_wrst
set COM_RST i_pcileech_com/g_fifo_replay.i_reset/fifo_rst_reg/C
set A7_FIFO_RST $A7/i_pcileech_pcie_a7_rst/i_fifo_reset/fifo_rst_reg/C
set A7_SUBSYS $A7/i_pcileech_pcie_a7_rst/rst_subsys_sys_reg/C
set S0 arststages_ff_reg\[0\]/PRE

# {group launch endpoint}; group C synchronizers have 4 stages, A and B 2.
set expect11 [list \
    [list A $COM_RST i_pcileech_com/i_fifo_256_32_clk2_comtx/$RB.gic_rst.rst_rd_reg2_inst/$S0] \
    [list A $COM_RST i_pcileech_com/i_fifo_64_64_clk2_comrx/$RB.rst_wr_reg2_inst/$S0] \
    [list B $A7_FIFO_RST $A7/i_pcileech_pcie_cfg_a7/i_fifo_pcie_cfg_rx/$RB.rst_wr_reg2_inst/$S0] \
    [list B $A7_FIFO_RST $A7/i_pcileech_pcie_cfg_a7/i_fifo_pcie_cfg_tx/$RB.gic_rst.rst_rd_reg2_inst/$S0] \
    [list B $A7_FIFO_RST $TLP/i_pcileech_tlps128_cfgspace_shadow/i_fifo_43_43_clk2/$RB.rst_wr_reg2_inst/$S0] \
    [list B $A7_FIFO_RST $TLP/i_pcileech_tlps128_cfgspace_shadow/i_fifo_49_49_clk2/$RB.gic_rst.rst_rd_reg2_inst/$S0] \
    [list B $A7_FIFO_RST $TLP/i_pcileech_tlps128_dst_fifo/i_fifo_134_134_clk2/$RB.rst_wr_reg2_inst/$S0] \
    [list B $A7_FIFO_RST $TLP/i_pcileech_tlps128_src_fifo/i_fifo_134_134_clk2_rxfifo/$RB.gic_rst.rst_rd_reg2_inst/$S0] \
    [list B $A7_FIFO_RST $TLP/i_pcileech_tlps128_src_fifo/i_fifo_1_1_clk2/$RB.gic_rst.rst_rd_reg2_inst/$S0] \
    [list C $A7_SUBSYS $A7/i_pcileech_pcie_cfg_a7/i_rst_window/i_cdc_rst_pcie/$S0] \
    [list C $A7_SUBSYS $TLP/i_pcileech_tlps128_cfgspace_shadow/i_rst_window/i_cdc_rst_pcie/$S0] \
    [list C $A7_SUBSYS $TLP/i_pcileech_tlps128_dst_fifo/i_rst_window/i_cdc_rst_pcie/$S0] \
    [list C $A7_SUBSYS $TLP/i_pcileech_tlps128_src_fifo/i_rst_window/i_cdc_rst_pcie/$S0] \
]
set expect15 [list \
    i_pcileech_com/i_fifo_64_64_clk2_comrx \
    $A7/i_pcileech_pcie_cfg_a7/i_fifo_pcie_cfg_tx \
    $TLP/i_pcileech_tlps128_cfgspace_shadow/i_fifo_43_43_clk2 \
    $TLP/i_pcileech_tlps128_cfgspace_shadow/i_fifo_49_49_clk2 \
]

set errors 0
proc bad {msg} { global errors; incr errors; puts "CDC_CHECK_FAIL $msg" }

# Every expected endpoint must still be stage 0 of a synchronizer with the
# expected number of stages, all ASYNC_REG.
foreach e $expect11 {
    set c [get_cells -quiet -of_objects [get_pins -quiet [lindex $e 2]]]
    if {$c eq ""} { bad "missing cell for [lindex $e 2]"; continue }
    set parent [string range $c 0 [expr {[string last / $c] - 1}]]
    set stages [get_cells -quiet $parent/arststages_ff_reg*]
    set want [expr {[lindex $e 0] eq "C" ? 4 : 2}]
    if {[llength $stages] != $want} { bad "$parent: [llength $stages] stages, expected $want" }
    foreach s $stages { if {![get_property ASYNC_REG $s]} { bad "no ASYNC_REG on $s" } }
}
# Waivers: only FIFO Generator's own CDC-1 waivers (asynchronous LUTRAM read
# into the read register), scoped to one of the LUTRAM FIFOs listed below.
foreach w [get_waivers -quiet] {
    set scope [get_property SCOPE $w]
    if {[get_property USER $w] ne "fifo_generator" || [get_property ID $w] ne "CDC-1" ||
        [lsearch -exact [lmap i $expect15 {set i "$i/U0"}] $scope] < 0} {
        bad "unexpected waiver $w ([get_property USER $w] [get_property ID $w] scope $scope)"
    } else { puts "CDC_CHECK_OK waiver $w (fifo_generator CDC-1, $scope)" }
}
set ct [check_timing -quiet -override_defaults {no_clock unconstrained_internal_endpoints} -return_string]
foreach k {no_clock unconstrained_internal_endpoints} {
    if {![regexp "checking $k \\((\\d+)\\)" $ct -> n]} { bad "check_timing: no $k line" } elseif {$n != 0} {
        bad "check_timing: $k $n"
    } else { puts "CDC_CHECK_OK check_timing $k 0" }
}
set info_expect {CDC-3 42 CDC-9 7}

set seen11 {}
foreach v [get_cdc_violations] {
    set chk [get_property CHECK $v]
    set from [get_property STARTPOINT_PIN $v]
    set to   [get_property ENDPOINT_PIN $v]
    if {[get_property SEVERITY $v] eq "Info"} {
        if {![dict exists $info_expect $chk]} { bad "unexpected Info $chk $from -> $to" } else { dict incr ninfo $chk }
    } elseif {$chk eq "CDC-11"} {
        set hit ""
        foreach e $expect11 { if {[lindex $e 1] eq $from && [lindex $e 2] eq $to} { set hit [lindex $e 0] } }
        if {$hit eq ""} { bad "unexpected CDC-11 $from -> $to" } else {
            lappend seen11 "$from $to"
            puts "CDC_CHECK_OK CDC-11 group $hit $from -> $to"
        }
    } elseif {$chk eq "CDC-15"} {
        set ip ""
        foreach i $expect15 {
            if {[string first "$i/U0/" $to] == 0 && [string first "$i/U0/" $from] == 0} { set ip $i }
        }
        if {$ip eq ""} { bad "unexpected CDC-15 $from -> $to" } else { dict incr n15 $ip }
    } else {
        bad "unexpected [get_property SEVERITY $v] $chk $from -> $to"
    }
}
foreach e $expect11 {
    if {[lsearch -exact $seen11 "[lindex $e 1] [lindex $e 2]"] < 0} {
        bad "expected CDC-11 not reported (structure changed, re-disposition): [lindex $e 1] -> [lindex $e 2]"
    }
}
foreach ip $expect15 {
    set used 0
    foreach p [get_pins -quiet $ip/dout*] { if {[get_nets -quiet -of_objects $p] ne ""} { incr used } }
    set n [expr {[info exists n15] && [dict exists $n15 $ip] ? [dict get $n15 $ip] : 0}]
    if {$n != $used} { bad "CDC-15 in $ip: $n findings, $used connected dout bits" } else {
        puts "CDC_CHECK_OK CDC-15 $ip: $n (one per connected dout bit)"
    }
}
dict for {k n} $info_expect {
    set got [expr {[info exists ninfo] && [dict exists $ninfo $k] ? [dict get $ninfo $k] : 0}]
    if {$got != $n} { bad "$k: $got findings, expected $n (re-review)" } else { puts "CDC_CHECK_OK $k $got" }
}
if {$errors == 0} { puts "CDC_CHECK_PASS" } else { puts "CDC_CHECK_FAIL $errors"; exit 1 }
