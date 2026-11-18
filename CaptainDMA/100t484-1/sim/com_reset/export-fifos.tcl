# Export functional structural models from existing OOC FIFO checkpoints.
# This does not synthesize, modify a project, or write a bitstream.
if {$argc != 2} { error "expected existing run directory and new output directory" }
set runs [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {[file exists $out]} { error "refuse to overwrite $out" }
file mkdir $out
set_param general.maxThreads 4
set manifest [open [file join $out checkpoint-sha256.txt] w]
foreach name {fifo_64_64_clk2_comrx fifo_256_32_clk2_comtx fifo_32_32_clk1_comtx} {
    set dcp [file join $runs ${name}_synth_1 ${name}.dcp]
    puts $manifest [exec sha256sum -- $dcp]
    open_checkpoint $dcp
    write_verilog -mode funcsim [file join $out ${name}.v]
    close_design
}
close $manifest
puts COM_FIFO_EXPORT_PASS
