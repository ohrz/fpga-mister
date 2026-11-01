# ----------------------------------------------------------------------------------
#  Title      : Build Vivado project
#  Project    : --
# ----------------------------------------------------------------------------------
#  File       : build-vivado-project.tcl
#  Author     : Konstantin Schmidt
#  Company    : OHRZ
#  Created    : 2024-08-23
# ----------------------------------------------------------------------------------
#  Description: Synthesis and implementation up to write_bitstream of
#               <project_name>/<project_name>.xpr (cwd: firmware/build/<platform>/<ver>/hw)
# ----------------------------------------------------------------------------------
#  Copyright (c) 2021-2024 -- OHRZ
# ----------------------------------------------------------------------------------

# vivado -mode batch -source build-vivado-project.tcl -tclargs --project_name <name> [--jobs <n>]

set start_time [clock seconds]

# Set the project name
set _xil_proj_name_ ""
# parallel runs (out-of-context IPs) for synthesis and implementation
set jobs 16

proc print_help {} {
  puts "usage: vivado -mode batch -source build-vivado-project.tcl -tclargs --project_name <name> \[--jobs <n>\]"
  exit 0
}

# stop with exit code 1 when a run did not complete
proc check_run { run } {
  if { [get_property PROGRESS [get_runs $run]] ne "100%" } {
    puts "ERROR: $run failed: [get_property STATUS [get_runs $run]]"
    close_project
    exit 1
  }
}

if { $::argc > 0 } {
  for {set i 0} {$i < $::argc} {incr i} {
    set option [string trim [lindex $::argv $i]]
    switch -regexp -- $option {
      "--project_name" { incr i; set _xil_proj_name_ [lindex $::argv $i] }
      "--jobs"         { incr i; set jobs [lindex $::argv $i] }
      "--help"         { print_help }
      default {
        if { [regexp {^-} $option] } {
          puts "ERROR: Unknown option '$option' specified, please type 'build-vivado-project.tcl -tclargs --help' for usage info.\n"
          exit 1
        }
      }
    }
  }
}

set xpr_file_name ${_xil_proj_name_}/${_xil_proj_name_}.xpr

puts "Vivado Project file: $xpr_file_name"

open_project $xpr_file_name

# Synthesize project
reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
check_run synth_1

# Generate bitstream
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
check_run impl_1

# we're done
close_project

set end_time [clock seconds]
puts "Build project: [clock format [expr $end_time - $start_time] -format %H:%M:%S -gmt 1]"
