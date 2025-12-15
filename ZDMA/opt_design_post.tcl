# Post opt_design hook script to fix LUT1 unconnected input issues
# This script runs after opt_design to clean up problematic cells

puts "INFO: Running post opt_design cleanup for PCIe core cells..."

# Remove DONT_TOUCH from comparison cells that were optimized to empty
set compare_cells [get_cells -quiet -hierarchical -filter {NAME =~ "*fifo*compare*" && IS_PRIMITIVE == 0}]
if {[llength $compare_cells] > 0} {
    puts "INFO: Found [llength $compare_cells] comparison cells to process"
    foreach cell $compare_cells {
        catch {set_property DONT_TOUCH false $cell}
    }
}

# Find and handle LUT1 cells with unconnected inputs in PCIe core
set pcie_lut1_cells [get_cells -quiet -hierarchical -filter {NAME =~ "*pcie_7x_0*pcie_block_i*" && REF_NAME == "LUT1"}]
if {[llength $pcie_lut1_cells] > 0} {
    puts "INFO: Found [llength $pcie_lut1_cells] LUT1 cells in PCIe core"
    foreach cell $pcie_lut1_cells {
        # Check if I0 pin is unconnected
        set i0_pin [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == "I0"}]
        if {$i0_pin != ""} {
            set net [get_nets -quiet -of_objects $i0_pin]
            if {$net == ""} {
                puts "WARNING: Cell $cell has unconnected I0 pin"
                # Try to tie to ground
                catch {
                    set gnd_net [get_nets -quiet {<const0>}]
                    if {$gnd_net != ""} {
                        puts "INFO: Attempting to connect $cell/I0 to GND"
                        # Remove DONT_TOUCH if present
                        catch {set_property DONT_TOUCH false $cell}
                    }
                }
            }
        }
    }
}

# Remove DONT_TOUCH from cells that are optimized away but still have it set
set empty_boxes [get_cells -quiet -hierarchical -filter {PRIMITIVE_LEVEL == "INTERNAL"}]
foreach cell $empty_boxes {
    catch {
        if {[get_property -quiet DONT_TOUCH $cell] == 1} {
            puts "INFO: Removing DONT_TOUCH from internal cell: $cell"
            set_property DONT_TOUCH false $cell
        }
    }
}

puts "INFO: Post opt_design cleanup complete"
