#
# RUN FROM WITHIN "Vivado Tcl Shell" WITH COMMAND:
# source vivado_build.tcl -notrace
#
puts "-------------------------------------------------------"
puts " GENERATING IP CORES.                                  "
puts "-------------------------------------------------------"
# Handle locked IP cores with comprehensive strategy
puts "Checking IP core status..."
report_ip_status -name ip_status -file ip_status_report.txt

# Try to unlock and regenerate IP cores
set locked_ips [get_ips -filter {IS_LOCKED == true}]
if {[llength $locked_ips] > 0} {
    puts "Found [llength $locked_ips] locked IP cores, attempting to unlock..."
    foreach ip $locked_ips {
        puts "Processing locked IP: [get_property NAME $ip]"
        # Try to reset the IP to unlock it
        catch {reset_target all $ip}
        # Try to upgrade the IP
        catch {upgrade_ip $ip}
    }
}

# Force regeneration of all IP cores
puts "Force regenerating all IP cores..."
foreach ip [get_ips] {
    set ip_name [get_property NAME $ip]
    puts "Regenerating IP: $ip_name"
    # Reset target to force regeneration
    catch {reset_target all $ip}
    # Generate new targets
    catch {generate_target all $ip}
}

# Final attempt to generate all IP cores
puts "Final IP core generation attempt..."
set generation_failed 0
foreach ip [get_ips] {
    set ip_name [get_property NAME $ip]
    if {[get_property IS_LOCKED $ip]} {
        puts "WARNING: IP $ip_name is still locked after regeneration attempts"
        set generation_failed 1
    } else {
        # Try final generation
        if {[catch {generate_target all $ip} err]} {
            puts "ERROR: Failed to generate $ip_name: $err"
            set generation_failed 1
        }
    }
}

if {$generation_failed} {
    puts "WARNING: Some IP cores could not be generated. Synthesis may fail."
    puts "Consider regenerating IP cores with the current Vivado version."
} else {
    puts "All IP cores successfully generated."
}
puts "-------------------------------------------------------"
puts " STARTING SYNTHESIS STEP.                              "
puts "-------------------------------------------------------"
launch_runs synth_1
puts "-------------------------------------------------------"
puts " WAITING FOR SYNTHESIS STEP TO FINISH ...              "
puts " THIS IS LIKELY TO TAKE A VERY LONG TIME.              "
puts "-------------------------------------------------------"
wait_on_run synth_1
puts "-------------------------------------------------------"
puts " STARTING IMPLEMENTATION STEP.                         "
puts "-------------------------------------------------------"
launch_runs impl_1 -to_step write_bitstream
puts "-------------------------------------------------------"
puts " WAITING FOR IMPLEMENTATION STEP TO FINISH ...         "
puts " THIS IS LIKELY TO TAKE A VERY LONG TIME.              "
puts "-------------------------------------------------------"
wait_on_run impl_1
file copy -force ./PCILeech_NeTV2/PCILeech_NeTV2.runs/impl_1/pcileech_netv2_top.bin pcileech_netv2.bin
puts "-------------------------------------------------------"
puts " BUILD HOPEFULLY COMPLETED.                            "
puts "-------------------------------------------------------"
