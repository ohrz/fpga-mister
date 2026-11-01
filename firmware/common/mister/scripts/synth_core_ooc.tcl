#-----------------------------------------------------------------------------
# Title      : Out-of-context synthesis of a MiSTer core with Vivado
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-28
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   First check of a core port: reads the HDL of a core's files.qip (sources
#   prepared by prepare_sources.py) and synthesizes one module out of context
#   for a Zynq part.  Shows what Vivado does not accept and how large the core
#   is, without a board design.  Writes util.txt, util_hier.txt and synth.dcp
#   to the output directory.
#
#   vivado -mode batch -source synth_core_ooc.tcl -tclargs \
#     --qip <prepared core>/files.qip [--qip <more>.qip]... --top <module> --out <dir> \
#     [--part xc7z020clg400-1] [--exclude <glob>]... [--add <hdl file>]... \
#     [--generic <name>=<value>]... [--define <name>=<value>]... [--xdc <constraints>]...
#     [--expect-bram <tiles> | --profile <cores/<core>/core.tcl>] [--vhdl2008] [--rtl]
#
#   --add reads replacement files (Intel megafunctions, core profile files) after
#   the .qip lists; the directories of all .qip files are include directories
#   (sys/emu_ports.vh, build_id.v).  --generic sets a generic of the top
#   (synth_design -generic), --define a Verilog macro (synth_design -verilog_define,
#   the core_defines of a profile), --xdc reads clock constraints; with --xdc the
#   output directory also gets timing.txt (estimate after synthesis).
#
#   --vhdl2008 (or core_vhdl_std 2008 of --profile) reads all VHDL files as VHDL
#   2008 (the core's .qsf has VHDL_INPUT_VERSION VHDL_2008, N64).
#
#   --rtl only elaborates the top (synth_design -rtl, minutes instead of the whole
#   synthesis): port connections, widths and missing modules, no reports.
#
#   --expect-bram (or core_expect_bram of --profile: block RAM tiles of the OOC
#   synthesis of emu, RAMB36 = 1, RAMB18 = 0.5) checks the result: more than 10 %
#   less or more tiles stops the run with an error.  Vivado removes RAMs without a
#   message when their enable or write port is tied to 0 (SNES VRAM, ARAM,
#   BSRAM, SA1 vanished, 30 instead of ~98 tiles).
#
#   Example 1 (MSX core without the emu wrapper and the unused VM2413 OPLL):
#     --qip firmware/build/src/MSX_MiSTer/files.qip --top emsx_top \
#     --exclude */MSX.sv --exclude */VM2413/*
#   Example 2 (the whole emu of the MSX core with the kept parts of sys/ and the
#     replacement files): doc/PORTING.md
#-----------------------------------------------------------------------------

source [file join [file dirname [info script]] qip.tcl]

set qips {}
set adds {}
set top ""
set out ""
set part xc7z020clg400-1
set exclude {}
set generics {}
set xdcs {}
set defines {}
set expect_bram ""
set vhdl2008 0
set rtl 0
for {set i 0} {$i < $::argc} {incr i} {
  switch -- [lindex $::argv $i] {
    --qip     { incr i; lappend qips [lindex $::argv $i] }
    --add     { incr i; lappend adds [lindex $::argv $i] }
    --top     { incr i; set top [lindex $::argv $i] }
    --out     { incr i; set out [lindex $::argv $i] }
    --part    { incr i; set part [lindex $::argv $i] }
    --exclude { incr i; lappend exclude [lindex $::argv $i] }
    --generic { incr i; lappend generics [lindex $::argv $i] }
    --xdc     { incr i; lappend xdcs [lindex $::argv $i] }
    --define  { incr i; lappend defines [lindex $::argv $i] }
    --expect-bram { incr i; set expect_bram [lindex $::argv $i] }
    --vhdl2008 { set vhdl2008 1 }
    --rtl      { set rtl 1 }
    --profile {
      incr i
      namespace eval ::profile [list source [lindex $::argv $i]]
      if {[info exists ::profile::core_expect_bram]} { set expect_bram $::profile::core_expect_bram }
      if {[info exists ::profile::core_vhdl_std] && $::profile::core_vhdl_std eq "2008"} { set vhdl2008 1 }
    }
    default   { error "unknown option [lindex $::argv $i]" }
  }
}
if {[llength $qips] == 0 || $top eq "" || $out eq ""} {
  error "usage: -tclargs --qip <files.qip>... --top <module> --out <dir> \[--part <part>\] \[--exclude <glob>\]... \[--add <file>\]... \[--generic <name>=<value>\]... \[--define <name>=<value>\]... \[--xdc <file>\]..."
}
file mkdir $out

proc read_hdl {type path} {
  switch $type {
    vhdl          { if {$::vhdl2008} { read_vhdl -vhdl2008 $path } else { read_vhdl $path } }
    verilog       -
    systemverilog { read_verilog -sv $path }
    default       { puts "INFO: not HDL, left out: $path"; return 0 }
  }
  return 1
}

set n 0
set incdirs {}
foreach qip $qips {
  lappend incdirs [file dirname [file normalize $qip]]
  foreach f [mister_qip_files $qip] {
    lassign $f type path
    set skip 0
    foreach pat $exclude { if {[string match $pat $path]} { set skip 1; break } }
    if {$skip} continue
    incr n [read_hdl $type $path]
  }
}
foreach path $adds {
  switch -glob -- $path {
    *.vhd   { set type vhdl }
    *.vhdl  { set type vhdl }
    default { set type systemverilog }
  }
  incr n [read_hdl $type [file normalize $path]]
}
puts "INFO: $n HDL files from [join $qips {, }] and [llength $adds] added files"

foreach path $xdcs { read_xdc -mode out_of_context [file normalize $path] }
set gen_args {}
foreach g $generics { lappend gen_args -generic $g }
foreach d $defines { lappend gen_args -verilog_define $d }
if {$rtl} {
  synth_design -rtl -top $top -part $part -mode out_of_context -include_dirs $incdirs {*}$gen_args
  puts "INFO: RTL elaboration of $top done"
  return
}
synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy rebuilt -include_dirs $incdirs \
  {*}$gen_args
report_utilization -file [file join $out util.txt]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $out util_hier.txt]
if {[llength $xdcs] > 0} {
  report_timing_summary -max_paths 10 -file [file join $out timing.txt]
  report_clock_interaction -file [file join $out clock_interaction.txt]
}
write_checkpoint -force [file join $out synth.dcp]

# block RAM tiles against the expected number (RAMs that vanished without a message)
if {$expect_bram ne ""} {
  set fh [open [file join $out util.txt]]
  set util [read $fh]
  close $fh
  if {![regexp {\|\s*Block RAM Tile\s*\|\s*([0-9.]+)} $util -> tiles]} {
    error "BRAM CHECK: no 'Block RAM Tile' line in util.txt"
  }
  if {abs($tiles - $expect_bram) > 0.1 * $expect_bram} {
    error "BRAM CHECK FAIL: $tiles block RAM tiles, expected $expect_bram (+-10 %): RAMs removed or added"
  }
  puts "BRAM CHECK PASS: $tiles block RAM tiles, expected $expect_bram (+-10 %)"
}
