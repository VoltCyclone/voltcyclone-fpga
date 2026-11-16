# Export functional structural models of the subsystem-reset FIFOs and the
# shadow memories from existing OOC checkpoints. No synthesis, no project
# change, no bitstream.
if {$argc != 2} { error "expected existing run directory and new output directory" }
set runs [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {[file exists $out]} { error "refuse to overwrite $out" }
file mkdir $out
set_param general.maxThreads 4
set manifest [open [file join $out checkpoint-sha256.txt] w]
foreach name {fifo_64_64 fifo_32_32_clk2 fifo_49_49_clk2 fifo_43_43_clk2 fifo_134_134_clk2
              fifo_134_134_clk2_rxfifo fifo_1_1_clk2 fifo_129_129_clk1
              bram_pcie_cfgspace drom_pcie_cfgspace_writemask} {
    set dcp [file join $runs ${name}_synth_1 ${name}.dcp]
    puts $manifest [exec sha256sum -- $dcp]
    open_checkpoint $dcp
    write_verilog -mode funcsim [file join $out ${name}.v]
    close_design
}
close $manifest
puts SUBSYS_MODEL_EXPORT_PASS
