#-----------------------------------------------------------------------------
# Title      : <CORE> core profile (<Checkout>_MiSTer)  -- TEMPLATE, copy to cores/<core>/
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : <date>
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   What a Zynq design needs to know about the core (doc/PORTING.md §3), read by
#   mister_core_add (scripts/mister_project.tcl).  Every value below comes from
#   the core's sources; write down where (file:line) next to it, as the MSX and
#   menu profiles do.
#     core_name        checkout in _Checkouts/ (firmware/common/checkouts.txt)
#     core_exclude     files of its .qip lists the port does not use (Quartus PLL,
#                      lcell rings, unused IP)
#     core_add         replacement files, relative to firmware/common/mister
#                      (same module name and ports as the excluded original)
#     core_xdc         core constraints (derived clocks of pll.vhd), relative to
#                      firmware/common/mister
#     core_master_mhz  stage C master clock = the fastest core clock a few percent
#                      above nominal (PORTING §3.3), with G_PACE_NUM/G_PACE_DEN
#     core_defines     VERILOG_MACRO lines of the .qsf plus port macros
#                      (MISTER_ZYNQ_NO_DOWNSCALE when the picture never exceeds 720p)
#     core_vhdl_std    optional: 2008 when the .qsf has VHDL_INPUT_VERSION VHDL_2008
#                      (default 93)
#     core_generics    generics of mister_zynq (PORTING §3.4: SDRAM geometry and
#                      read phase, BRAM region, cache order, size and split, pacer;
#                      G_CACHE_SPLIT 1 when tools/perf.py shows misses on lines
#                      replaced from the other half of the address space;
#                      G_DDRAM 1 when the core uses DDRAM_* and its DDRAM_CLK runs
#                      free: the board generator connects it to HP2; G_FREE_CLK 1
#                      when the core waits on its memories by handshake: CLK_50M =
#                      free clk_master, no stage C, PORTING §3.3)
#     core_vhdl2008    optional: replacement files (of core_add) read as VHDL 2008,
#                      e.g. when they use VHDL-2008 packages of the core
#     core_ooc_timing  optional: 1 = out-of-context synthesis of mister with clocks
#                      and core_xdc (timing driven; default 0: no constraints)
#     core_synth_options  optional: more synth_design options of that run
#     core_impl_props  optional: properties of impl_1 (directives) as name value list
#
#   SDRAM (<controller file>): CL <n>, burst <n>, address mapping <...>,
#   data sampled at edge CL+<0|1> -> G_SD_RD_ADJ.
#   Clocks (<pll file>): <outclk_0 ...>; replaced by cores/<core>/pll.vhd.
#-----------------------------------------------------------------------------

set core_name    <Checkout>_MiSTer
set core_exclude {*/rtl/pll*}
set core_add     {cores/<core>/pll.vhd}
set core_xdc     {cores/<core>/core.xdc}
set core_master_mhz 90.0
set core_defines {}
set core_generics {
  G_SD_BANK_BITS     2
  G_SD_ROW_BITS      13
  G_SD_COL_BITS      9
  G_SD_RD_ADJ        0
  G_B0_BITS          0
  G_CACHE_COL_HIGH   0
  G_CACHE_LINE_LOG2  2
  G_CACHE_INDEX_BITS 9
  G_CACHE_SPLIT      0
  G_PACE_NUM         1
  G_PACE_DEN         1
  G_PACE_BUCKET      1024
}
