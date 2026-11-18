# Post place_design hook: replicate the COM TX FIFO pointer and RAM reset registers.
#
# fifo_256_32_clk2_comtx (8192 x 256 in, 32 out) spans about 57 block RAMs.
# Its read and write pointer registers drive every block RAM address, and its
# in-domain RAM reset registers (sckt_rd_rst_ic / sckt_wr_rst_ic, fanout ~200)
# every RAM reset, with no logic between, so the far RAMs set the ft601_c0 and
# net_clk limits (up to 8.7 ns of routing). The FIFO Generator IP is synthesized
# out of context, so MAX_FANOUT cannot reach these registers; replicate them
# after placement. None is a synchronizer stage (ASYNC_REG): each is fed by
# logic in its own clock domain, so every replica holds the same value.
set comtx_ptr_nets [get_nets -quiet -of_objects [get_pins -quiet -hierarchical -filter {
    NAME =~ "*i_fifo_256_32_clk2_comtx/*/rpntr/gc0.count_d1_reg*/Q" ||
    NAME =~ "*i_fifo_256_32_clk2_comtx/*/wpntr/gic0.gc1.count_d3_reg*/Q" ||
    NAME =~ "*i_fifo_256_32_clk2_comtx/*/rstblk/*sckt_rd_rst_ic_reg/Q" ||
    NAME =~ "*i_fifo_256_32_clk2_comtx/*/rstblk/*sckt_wr_rst_ic_reg/Q"}]]
# The FIFO exists in every build of this board; finding none means the IP or
# instance was renamed and the timing fix would silently not apply.
if {[llength $comtx_ptr_nets] == 0} {
    error "place_design_post: COM TX FIFO pointer/reset nets not found; update the net patterns"
} else {
    puts "INFO: place_design_post: replicating [llength $comtx_ptr_nets] COM TX FIFO pointer/reset nets"
    phys_opt_design -force_replication_on_nets $comtx_ptr_nets
}

# Global SYS reset: the top-level rst register (pcileech_100t484_x1_top.sv,
# MAX_FANOUT 50). Synthesis counts each out-of-context FIFO IP as one load, so
# after linking one copy can still drive ~300 FIFO-internal reset pins across
# the die (sweep seeds17, ExtraTimingOpt: net_clk +0.048 ns, rst_reg ->
# i_fifo_cmd_tx, 8.7 ns of routing). Every copy is a clk-domain register with
# the same D, so replicas hold the same value.
set sys_rst_regs [get_cells -quiet -filter {
    PRIMITIVE_TYPE =~ FLOP_LATCH.*.* && (NAME == "rst_reg" || NAME =~ "rst_reg_rep*")}]
if {[llength $sys_rst_regs] == 0} {
    error "place_design_post: top-level rst register not found; update the cell pattern"
}
# Only the copies that still drive 100 or more pins (the synthesis replicas
# carry about 50 each).
set sys_rst_nets [get_nets -quiet -of_objects [get_pins -of_objects $sys_rst_regs \
    -filter {REF_PIN_NAME == Q}] -filter {FLAT_PIN_COUNT >= 100}]
if {[llength $sys_rst_nets] > 0} {
    puts "INFO: place_design_post: replicating [llength $sys_rst_nets] top-level rst nets: $sys_rst_nets"
    phys_opt_design -force_replication_on_nets $sys_rst_nets
}
