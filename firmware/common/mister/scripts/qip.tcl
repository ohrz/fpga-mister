#-----------------------------------------------------------------------------
# Title      : Quartus .qip file lists of MiSTer cores for Vivado
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-28
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   MiSTer cores list their sources in Quartus .qip files (files.qip, sys/sys.qip,
#   sub-IP .qip):
#     set_global_assignment -name VHDL_FILE rtl/x.vhd
#     set_global_assignment -name SYSTEMVERILOG_FILE [file join $::quartus(qip_path) a.sv]
#     set_global_assignment -name QIP_FILE sub/y.qip
#   mister_qip_files reads such a file (nested QIP_FILEs included) and returns
#   a list of {type path} with absolute paths, type one of vhdl verilog
#   systemverilog other (MIF/HEX/SDC/... files, for the caller to decide).
#   Paths are relative to the .qip (Quartus: relative to the project directory,
#   which is the directory of files.qip in every MiSTer core; $::quartus(qip_path)
#   is the directory of the .qip that uses it).  Other computed paths (Tcl
#   expressions) are left out with an INFO message.
#
#   Usage:
#     source qip.tcl
#     foreach f [mister_qip_files $core_dir/files.qip] { lassign $f type path; ... }
#     mister_qip_add $core_dir/files.qip {exclude patterns}   ;# add_files for HDL
#-----------------------------------------------------------------------------

namespace eval mister_qip {
  variable types {VHDL_FILE vhdl VERILOG_FILE verilog SYSTEMVERILOG_FILE systemverilog}
}

proc mister_qip_files {qip {base ""}} {
  set qip [file normalize $qip]
  set qip_dir [file dirname $qip]
  if {$base eq ""} { set base $qip_dir }
  set result {}
  set fh [open $qip r]
  set lines [split [read $fh] "\n"]
  close $fh
  foreach line $lines {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} continue
    if {![regexp {^set_global_assignment\s+.*-name\s+(\S+)\s+(.+)$} $line -> name value]} continue
    set value [string trim $value]
    # [file join $::quartus(qip_path) x] -> qip directory / x
    if {[regexp {^\[file join \$::quartus\(qip_path\)\s+(.+)\]$} $value -> rel]} {
      set path [file normalize [file join $qip_dir [string trim $rel " \""]]]
    } elseif {[string index $value 0] eq "\["} {
      # any other Tcl expression: sys/sys.qip picks the Quartus PLL IP by Quartus version
      # ([join [list $::quartus(qip_path) pll_q ...]]); the port replaces those PLLs
      puts "INFO: mister_qip_files: computed path left out ($qip): $value"
      continue
    } else {
      set path [file normalize [file join $base [string trim $value " \""]]]
    }
    if {$name eq "QIP_FILE"} {
      # a nested .qip: its plain paths are relative to the project as well
      set result [concat $result [mister_qip_files $path $base]]
    } elseif {[dict exists $::mister_qip::types $name]} {
      lappend result [list [dict get $::mister_qip::types $name] $path]
    } elseif {[string match *_FILE $name]} {
      lappend result [list other $path]
    }
  }
  return $result
}

# add_files for the HDL of a .qip; exclude: glob patterns matched against the path
# (e.g. */sys/pll*.v for Quartus IP replaced by the port).  Returns the added files.
# Verilog files are read as SystemVerilog: Quartus accepts SystemVerilog constructs in
# .v files (declarations in unnamed blocks, ...) that Vivado's Verilog-2001 parser rejects.
proc mister_qip_add {qip {exclude {}} {fileset sources_1}} {
  set added {}
  foreach f [mister_qip_files $qip] {
    lassign $f type path
    if {$type eq "other"} continue
    set skip 0
    foreach pat $exclude { if {[string match $pat $path]} { set skip 1; break } }
    if {$skip} continue
    if {![file exists $path]} { error "mister_qip_add: $path (from $qip) does not exist" }
    add_files -fileset $fileset -norecurse $path
    if {$type ne "vhdl"} {
      set_property file_type SystemVerilog [get_files $path]
    }
    lappend added $path
  }
  return $added
}
