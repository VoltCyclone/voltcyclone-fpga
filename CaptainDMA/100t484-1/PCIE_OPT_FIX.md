# PCIe Core Optimization Fix for 100t484-1

## Issue

During implementation, users were encountering the following error during opt_design:

```
ERROR: [Opt 31-67] Problem: A LUT1 cell in the design is missing a connection on input pin I0, 
which is used by the LUT equation. This pin has either been left unconnected in the design or 
the connection was removed due to the trimming of unused logic. 
The LUT cell name is: i_pcileech_pcie_a7/i_pcie_7x_0/inst/inst/pcie_top_i/pcie_7x_i/pcie_block_i_i_1.
```

Additionally, warnings about empty box cells:

```
INFO: [Opt 31-120] Instance i_pcileech_pcie_a7/i_pcileech_pcie_cfg_a7/i_fifo_pcie_cfg_rx/U0/
inst_fifo_gen/gconvfifo.rf/grf.rf/gntv_or_sync_fifo.gl0.wr/gwas.wsts/gaf.c3 
(fifo_32_32_clk2_compare_1) has been optimized to an empty box cell during sweep but it has 
constraints that prevent its removal.
```

## Root Cause

The PCIe 7x IP core and FIFO IP cores generate comparison logic that gets optimized away during
synthesis, leaving empty box cells with DONT_TOUCH properties. During opt_design, Vivado creates
LUT1 cells for buffering/fanout control, but these cells end up with unconnected inputs after
further optimization.

## Solution

The fix involves three components:

### 1. Aggressive Optimization Directive

Modified `vivado_generate_project_captaindma_100t.tcl` to use the `ExploreWithRemap` directive
for opt_design, which is more aggressive at remapping and removing redundant logic:

```tcl
set_property -name "steps.opt_design.args.directive" -value "ExploreWithRemap" -objects $obj
set_property -name "steps.opt_design.args.more_options" -value "-debug_log" -objects $obj
```

### 2. Post-Optimization Hook Script

Created `opt_design_post.tcl` that runs after opt_design to:
- Remove DONT_TOUCH properties from optimized-away comparison cells
- Detect and handle LUT1 cells with unconnected inputs in the PCIe core
- Clean up internal empty box cells

The hook is registered in the project generation script:

```tcl
set_property -name "steps.opt_design.tcl.post" -value "[file normalize "$origin_dir/opt_design_post.tcl"]" -objects $obj
```

### 3. Debug Logging

Added `-debug_log` to opt_design to provide detailed information about what logic is being trimmed,
making it easier to diagnose future issues.

## Files Modified

1. `vivado_generate_project_captaindma_100t.tcl` - Added opt_design directives and post-hook
2. `opt_design_post.tcl` - New post-optimization cleanup script

## Testing

After applying this fix:
1. Regenerate the Vivado project: `source vivado_generate_project_captaindma_100t.tcl`
2. Run the build: `source vivado_build.tcl`
3. The opt_design step should complete successfully without the LUT1 unconnected input error

## Technical Details

The `pcie_block_i_i_1` cell is created by Vivado's optimization engine as part of the PCIe core's
internal logic. When certain signals are tied to constants or optimized away, the tools may create
buffer cells (LUT1) that later have their inputs removed. The ExploreWithRemap directive prevents
this by being more thorough in the initial optimization pass, and the post-hook ensures any
remaining problematic cells are cleaned up.

## Related Issues

- Vivado Answer Record AR# 54117 - LUT with unconnected input after optimization
- Vivado Answer Record AR# 67462 - Empty box cells with DONT_TOUCH constraints

## Date

December 14, 2025
