# ----------------------------------------------------------------------------------
#  Title      : Export XSA from vivado project
#  Project    : --
# ----------------------------------------------------------------------------------
#  File       : export-xsa-from-vivado.tcl
#  Author     : Konstantin Schmidt
#  Company    : OHRZ
#  Created    : 2024-08-23
# ----------------------------------------------------------------------------------
#  Description: Writes <project_name>.xsa (with bitstream) of
#               <project_name>/<project_name>.xpr (cwd: firmware/build/<platform>/<ver>/hw).
#               Default: the platform type of the project. --fixed: fixed XSA
#               without bitstream (the MiSTer designs, for the FSBL).
# ----------------------------------------------------------------------------------
#  Copyright (c) 2021-2024 -- OHRZ
# ----------------------------------------------------------------------------------
# vivado -mode batch -source export-xsa-from-vivado.tcl -tclargs --project_name <name> [--fixed]

set start_time [clock seconds]

# Set the project name
set _xil_proj_name_ ""
set fixed 0

proc print_help {} {
  puts "usage: vivado -mode batch -source export-xsa-from-vivado.tcl -tclargs --project_name <name> \[--fixed\]"
  exit 0
}

if { $::argc > 0 } {
  for {set i 0} {$i < $::argc} {incr i} {
    set option [string trim [lindex $::argv $i]]
    switch -regexp -- $option {
      "--project_name" { incr i; set _xil_proj_name_ [lindex $::argv $i] }
      "--fixed"        { set fixed 1 }
      "--help"         { print_help }
      default {
        if { [regexp {^-} $option] } {
          puts "ERROR: Unknown option '$option' specified, please type 'export-xsa-from-vivado.tcl -tclargs --help' for usage info.\n"
          exit 1
        }
      }
    }
  }
}

set xpr_file_name ${_xil_proj_name_}/${_xil_proj_name_}.xpr

puts "Vivado Project file: $xpr_file_name"

open_project $xpr_file_name

# Export XSA (-force: a second export overwrites the previous one)
if { $fixed } {
  write_hw_platform -fixed -force -file ${_xil_proj_name_}.xsa
} else {
  write_hw_platform -include_bit -force -hw -file ${_xil_proj_name_}.xsa
}

# we're done
close_project

set end_time [clock seconds]
puts "Export XSA from Vivado project: [clock format [expr $end_time - $start_time] -format %H:%M:%S -gmt 1]"
