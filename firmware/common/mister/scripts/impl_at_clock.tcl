#-----------------------------------------------------------------------------
# Title      : Implementation of a built design at other core clock rates
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-30
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   Diagnosis for raising core clocks: takes the linked
#   synthesis checkpoint of a board design, sets the multiplier and output
#   dividers of the core MMCM, implements (opt, place, phys_opt, route,
#   phys_opt) and writes routed.dcp, timing_summary.rpt, util.rpt and
#   paths.csv (every failing endpoint, worst path each: slack, clock pair,
#   start, end, logic levels, data path delay, share of net delay in %;
#   timing_groups.py groups it by module).  The generated core clocks must be
#   derived from the MMCM (create_generated_clock without ratio, as in
#   cores/n64/core.xdc).  Synthesis keeps the timing goals of the build: an
#   estimate, not a replacement for a build at the new rates.  Linked
#   checkpoint of a project build:
#     open_project <xpr>; open_run synth_1; write_checkpoint <dcp>
#
#   vivado -mode batch -source impl_at_clock.tcl -tclargs \
#     <dcp> <out dir> <MMCM cell glob> <CLKFBOUT_MULT_F> <CLKOUT0_DIVIDE_F> \
#     <CLKOUT1_DIVIDE> <CLKOUT2_DIVIDE>
#
#   N64 at 100 %: ... '*/emu/pll/*' 22.5 18.0 12 9   (VCO 1125 MHz)
#   N64 at 80 %:  ... '*/emu/pll/*' 18.0 18.0 12 9   (VCO 900 MHz)
#-----------------------------------------------------------------------------

lassign $argv dcp out pattern mult div0 div1 div2
file mkdir $out
open_checkpoint $dcp

set mmcm [get_cells -hier -filter "REF_NAME =~ MMCME2_* && NAME =~ $pattern"]
if {[llength $mmcm] != 1} { error "impl_at_clock: expected one MMCM for $pattern, found [llength $mmcm]" }
set_property CLKFBOUT_MULT_F  $mult $mmcm
set_property CLKOUT0_DIVIDE_F $div0 $mmcm
set_property CLKOUT1_DIVIDE   $div1 $mmcm
set_property CLKOUT2_DIVIDE   $div2 $mmcm
foreach pin {CLKOUT0 CLKOUT1 CLKOUT2} {
  set c [get_clocks -of_objects [get_pins $mmcm/$pin]]
  puts "impl_at_clock: $pin [get_property NAME $c] [get_property PERIOD $c] ns"
}

opt_design
place_design
phys_opt_design
route_design
phys_opt_design
write_checkpoint -force $out/routed.dcp
report_timing_summary -max_paths 20 -file $out/timing_summary.rpt
report_utilization -file $out/util.rpt

set f [open $out/paths.csv w]
puts $f "slack;group;start;end;levels;datapath;route_pct"
foreach p [get_timing_paths -max_paths 20000 -nworst 1 -slack_lesser_than 0 -sort_by slack] {
  set dp [get_property DATAPATH_DELAY $p]
  set nd [get_property DATAPATH_NET_DELAY $p]
  set pct [expr {$dp > 0 ? round(100.0 * $nd / $dp) : 0}]
  puts $f "[get_property SLACK $p];[get_property STARTPOINT_CLOCK $p]>[get_property ENDPOINT_CLOCK $p];[get_property STARTPOINT_PIN $p];[get_property ENDPOINT_PIN $p];[get_property LOGIC_LEVELS $p];$dp;$pct"
}
close $f
