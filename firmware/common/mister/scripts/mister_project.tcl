#-----------------------------------------------------------------------------
# Title      : MiSTer core sources in a Vivado project
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-28
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   Board-independent part of a MiSTer design script (firmware/targets/<p>/scripts/
#   <ver>/<p>_mister.tcl, called with CORE= and VIDEO=).  mister_core_add, called after create_project:
#     1. reads the core profile firmware/common/mister/cores/<core>/core.tcl
#     2. prepares the core's checkout _Checkouts/<name> into firmware/build/src/<name>
#        (prepare_sources.py: Vivado rules incl. the profile's rules.py,
#        sys/sys_top_zynq.sv, cores/<core>/patches/*.patch)
#     3. adds the HDL of its files.qip and sys/sys.qip without the Cyclone V parts
#        the port replaces, the Intel megafunction replacements, the own HDL
#        (hdl/*.vhd with mister_zynq, the module reference of the block design)
#        and the core's replacement files; with core_vhdl_std 2008 in the profile
#        (VHDL_INPUT_VERSION VHDL_2008 in the core's .qsf) the VHDL files of the
#        core's .qip lists are read as VHDL 2008, and the replacement files the
#        profile lists in core_vhdl2008 as well
#     4. adds the core constraints (before the board's, see cores/<core>/core.xdc)
#     5. sets the Verilog macros of the core (core_defines, the VERILOG_MACRO lines
#        of its .qsf) on sources_1, so the module reference elaborates with them
#   and returns a dict: name, generics (mister_zynq generics as a name value list),
#   master_mhz (stage C master clock), runs (the optional run settings of the profile).
#   mister_runs, called after make_wrapper, applies those run settings (only when the
#   profile has any): core_ooc_timing 1 gives the out-of-context synthesis of mister
#   (design_1_mister_0_synth_1, without constraints otherwise) clocks on its clock
#   ports and the core's core_xdc, so synthesis is timing driven at the core's rates;
#   core_synth_options are more synth_design options of that run (e.g. -global_retiming
#   on); core_impl_props are properties of impl_1 (directives, post-route phys_opt).
#
#   Usage:
#     source <root>/firmware/common/mister/scripts/mister_project.tcl
#     set core [mister_core_add <root> msx]
#     set_property -dict [mister_bd_config $core] [get_bd_cells mister]
#     if {[mister_ddram $core]} { ... S_AXI_HP2 for mister/m_axi_ddram ... }
#     if {[mister_coremem $core]} { ... S_AXI_HP3 for mister/m_axi_coremem ... }
#     if {[mister_direct_video $core]} { ... transmitter on mister/vid_clk, vid_clk_ser ... }
#     ... make_wrapper ...
#     mister_runs $core design_1.bd <project dir> {clk_100 10.0 clk_50 20.0 ...}
#-----------------------------------------------------------------------------

source [file join [file dirname [info script]] qip.tcl]

namespace eval mister_project {
  variable dir [file normalize [file join [file dirname [info script]] ..]]
  # Cyclone V parts of sys/ that sys_top_zynq has as ports (mister_zynq connects them)
  variable exclude {*/sys/pll_hdmi.v */sys/pll_audio.v */sys/pll_cfg/* */sys/pll_hdmi/* */sys/pll_audio/*
                    */sys/sys_top.v */sys/sysmem.sv */sys/f2sdram_safe_terminator.sv}
}

proc mister_core_add {root core} {
  set m $::mister_project::dir
  # optional in a profile
  set core_defines {}
  set core_vhdl_std 93
  set core_vhdl2008 {}
  set core_ooc_timing 0
  set core_synth_options {}
  set core_impl_props {}
  source [file join $m cores $core core.tcl]
  set src [file join $root _Checkouts $core_name]
  set dst [file join $root firmware build src $core_name]
  if {![file isdirectory $src]} {
    error "mister_core_add: $src missing (PLATFORM=<p> FLOW=vivado make setup)"
  }
  # source rules of the profile (cores/<core>/rules.py), if it has any
  set rules [file join $m cores $core rules.py]
  set rules_arg [expr {[file exists $rules] ? [list $rules] : {}}]
  puts [exec python3 [file join $m scripts prepare_sources.py] $core_name $src $dst {*}$rules_arg 2>@1]

  set exclude [concat $::mister_project::exclude $core_exclude]
  set hdl {}
  foreach qip [list [file join $dst files.qip] [file join $dst sys sys.qip]] {
    set hdl [concat $hdl [mister_qip_add $qip $exclude]]
  }
  set n [llength $hdl]
  if {$core_vhdl_std eq "2008"} {
    set vhd [lsearch -all -inline -glob $hdl *.vhd]
    if {[llength $vhd]} { set_property file_type {VHDL 2008} [get_files $vhd] }
  } elseif {$core_vhdl_std ne "93"} {
    error "mister_core_add: core_vhdl_std $core_vhdl_std (93 or 2008)"
  }
  # `include targets (sys/emu_ports.vh, build_id.v): a module reference only elaborates
  # with them in the project, as Verilog headers
  set incdirs [list $dst [file join $dst sys]]
  set headers {}
  foreach f $hdl {
    if {[string match *.vhd $f]} continue
    set fh [open $f r]
    foreach {- inc} [regexp -all -inline -line {^\s*`include\s+"([^"]+)"} [read $fh]] {
      foreach d [concat [list [file dirname $f]] $incdirs] {
        set p [file normalize [file join $d $inc]]
        if {[file exists $p]} { if {$p ni $headers} { lappend headers $p }; break }
      }
    }
    close $fh
  }
  if {[llength $headers]} {
    add_files -norecurse $headers
    set_property file_type {Verilog Header} [get_files $headers]
  }
  set own [concat [glob [file join $m hdl *.vhd]] [glob [file join $m hdl intel *.vhd]]]
  foreach f $core_add { lappend own [file join $m $f] }
  add_files -norecurse $own
  # replacement files that use the core's VHDL-2008 packages (Vivado reads own files as VHDL-93)
  foreach f $core_vhdl2008 { set_property file_type {VHDL 2008} [get_files [file join $m $f]] }
  set_property include_dirs $incdirs [get_filesets sources_1]
  foreach f $core_xdc { add_files -fileset constrs_1 -norecurse [file join $m $f] }
  if {[llength $core_defines]} {
    set_property verilog_define $core_defines [get_filesets sources_1]
  }
  puts "INFO: mister_core_add: $core_name, $n files from the .qip lists, [llength $headers] headers,\
        [llength $own] own and replacement files, defines {$core_defines}, VHDL $core_vhdl_std"
  set xdc {}
  foreach f $core_xdc { lappend xdc [file join $m $f] }
  return [dict create name $core_name generics $core_generics master_mhz $core_master_mhz \
    runs [dict create ooc_timing $core_ooc_timing synth_options $core_synth_options \
            impl_props $core_impl_props xdc $xdc]]
}

# run settings of the profile (see the header): bd is the block design file name, dir the
# project directory (for the generated constraints), clocks the period in ns of every
# clock input of mister_zynq as a name value list (port names, as in the block design)
proc mister_runs {core bd dir clocks} {
  set r [dict get $core runs]
  if {![dict get $r ooc_timing] && ![llength [dict get $r synth_options]] && ![llength [dict get $r impl_props]]} {
    return
  }
  # the out-of-context runs of the block design exist only after this (launch_runs keeps them)
  generate_target all [get_files $bd]
  create_ip_run [get_files $bd]
  set ooc [get_runs -filter {NAME =~ *_mister_0_synth_1}]
  if {[llength $ooc] != 1} { error "mister_runs: no out-of-context run of mister" }
  if {[dict get $r ooc_timing]} {
    set xdc [file join $dir mister_ooc.xdc]
    set fh [open $xdc w]
    puts $fh "# generated by mister_runs (scripts/mister_project.tcl): clocks of mister_zynq for its"
    puts $fh "# out-of-context synthesis, asynchronous to each other (implementation uses the full constraints)"
    set groups {}
    dict for {port period} $clocks {
      puts $fh "create_clock -name ooc_$port -period $period \[get_ports $port\]"
      append groups " -group \[get_clocks -include_generated_clocks ooc_$port\]"
    }
    puts $fh "set_clock_groups -asynchronous$groups"
    close $fh
    set pre [file join $dir mister_ooc_pre.tcl]
    set fh [open $pre w]
    puts $fh "# generated by mister_runs: constraints of the out-of-context synthesis of mister"
    foreach f [concat [list $xdc] [dict get $r xdc]] { puts $fh "read_xdc -mode out_of_context [list $f]" }
    close $fh
    set_property STEPS.SYNTH_DESIGN.TCL.PRE $pre $ooc
  }
  if {[llength [dict get $r synth_options]]} {
    # -name/-value: a value starting with '-' would be read as an option of set_property
    set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value [dict get $r synth_options] -objects $ooc
  }
  if {[llength [dict get $r impl_props]]} {
    set_property -dict [dict get $r impl_props] [get_runs impl_1]
  }
  puts "INFO: mister_runs: $ooc ooc_timing [dict get $r ooc_timing], options {[dict get $r synth_options]},\
        impl_1 {[dict get $r impl_props]}"
}

# CONFIG.<generic> list for set_property -dict on the mister_zynq cell
proc mister_bd_config {core} {
  set cfg {}
  dict for {k v} [dict get $core generics] { lappend cfg CONFIG.$k $v }
  return $cfg
}

# 1 when the profile sets G_DDRAM (the core's DDRAM_* on m_axi_ddram, clocked by ddram_clk):
# the board generator then enables a third HP port for it
proc mister_ddram {core} {
  set g [dict get $core generics]
  return [expr {[dict exists $g G_DDRAM] && [dict get $g G_DDRAM] != 0}]
}

# 1 when the profile sets G_COREMEM (memory port of a replaced SDRAM controller on
# m_axi_coremem, clocked by coremem_clk): the board generator then enables a fourth HP port
proc mister_coremem {core} {
  set g [dict get $core generics]
  return [expr {[dict exists $g G_COREMEM] && [dict get $g G_COREMEM] != 0}]
}

# 1 when the profile sets G_DIRECT_VIDEO (sys_top without ascal, MISTER_DEBUG_NOHDMI): the board
# generator then clocks the HDMI transmitter with mister/vid_clk, vid_clk_ser, vid_locked
proc mister_direct_video {core} {
  set g [dict get $core generics]
  return [expr {[dict exists $g G_DIRECT_VIDEO] && [dict get $g G_DIRECT_VIDEO] != 0}]
}
