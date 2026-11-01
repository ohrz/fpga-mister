#-----------------------------------------------------------------------------
# Title      : N64 core profile (N64_MiSTer)
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-30
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   What a Zynq design needs to know about the N64 core (doc/PORTING.md §5.2),
#   read by mister_core_add (scripts/mister_project.tcl); fields as in cores/msx.
#   Goal: the core at full speed on the xc7z020 (2/3 and 80 % before).  G_DDRAM 1: DDRAM_* on HP2.
#   G_FREE_CLK 1: CLK_50M is clk_master itself (core_master_mhz 50, a free-running
#   BUFG output, no stage C); the MMCMs of pll.vhd and pll2.vhd sit on it, their
#   clocks are generated clocks of clk_master.  The G_SD_*, G_B0_*, G_CACHE_* and
#   G_PACE_* generics have no effect then (defaults).  G_COREMEM 1: stage D,
#   rtl/sdram.sv replaced by cores/n64/sdram.vhd, its Avalon master as emu port
#   COREMEM_* (rules.py) -> sys_top_zynq ZYNQ_coremem_* (MISTER_ZYNQ_COREMEM) ->
#   HP3 at G_SDRAM_BASE 0x3800_0000 (128 MB: the 64DD and savestate areas of
#   the core's DDR plan, both off).  Picture through ascal (G_DIRECT_VIDEO 0):
#   fixed 1280 x 720 at 60 Hz on clk_hdmi, frame buffer on HP1; the VI's
#   15 kHz picture goes in as it is (no scandoubler).  ascal slimmed down:
#   MISTER_ZYNQ_NO_DOWNSCALE (the N64 picture is at most 640 x 576),
#   MISTER_SMALL_VBUF (2 MB per buffer), MISTER_DISABLE_ADAPTIVE.  Earlier
#   the profile used direct video (MISTER_DEBUG_NOHDMI, G_DIRECT_VIDEO 1,
#   video_mixer with the scandoubler): a monitor showed it, not every HDMI sink
#   takes its non-CEA timing.
#   MISTER_DISABLE_YC: no composite/S-Video encoder (no analogue output).
#   MISTER_ZYNQ_SIMPLE_AUDIO: the core audio straight to I2S (HDMI and codec)
#   instead of audio_out (1.6k LUT: with ascal and audio_out the placer failed
#   at 99.9 % LUT; before that the core was silent with MISTER_ZYNQ_NO_AUDIO).
#   MISTER_ZYNQ_NO_DIRECT_VIDEO: HDMI always through ascal, no VGA OSD and
#   direct video path (about 1k LUT).
#
#   Clocks (rtl/pll.v, rtl/pll2.v): clk_1x 62.5, clk_93 93.75, clk_2x 125 MHz,
#   clk_vid 48.68 MHz (NTSC; PAL/MPAL by reconfiguration over pll_cfg_small).
#   cores/n64/pll.vhd: an MMCM with the original core clocks (62.5/93.75/125 MHz),
#   cores/n64/pll2.vhd: NTSC 48.684 MHz (PLLE2) and PAL 49.656 MHz
#   (MMCM) behind a BUFGCTRL, pll_cfg_small.vhd selects PAL from the divider
#   N64.sv writes (MPAL gets NTSC).  Both need a free-running 50 MHz
#   CLK_50M at the emu port (G_FREE_CLK), not the gated master clock of stage C.
#   SDRAM (rtl/sdram.sv, Ch1 n64top cartridge saves/TPak, Ch2 ROM download):
#   CL 2, burst 2 (32 bit per access), bank addr[24:23], row addr[22:10],
#   column addr[9:1], chip addr[26] (two chips).
#   DDRAM (rtl/DDR3Mux.vhd): RDRAM, frame buffer, ROM; DDRAM_ADDR(28:25) = 0011
#   (byte address 0x3000_0000), bursts up to 255 beats.
#   Macros (N64.qsf): MISTER_FB, MISTER_DOWNSCALE_NN, MISTER_DISABLE_ALSA (the
#   ADAPTIVE and YC lines are comments there); MISTER_ZYNQ_COREMEM,
#   MISTER_ZYNQ_NO_DOWNSCALE, MISTER_SMALL_VBUF, MISTER_DISABLE_ADAPTIVE,
#   MISTER_DISABLE_YC (above).  VHDL-2008
#   (VHDL_INPUT_VERSION).
#   Replaced Intel parts: rtl/pll* (pll.v, pll2.v, pll_cfg_small.v) by pll.vhd,
#   pll2.vhd, pll_cfg_small.vhd; rtl/cpu_mul.vhd (altera_mult_add) and
#   rtl/Shiftreg.vhd (altshift_taps) by the files of the same name here;
#   rtl/sdram.sv (SDRAM pins) by sdram.vhd (Avalon master, stage D);
#   rtl/RDP_CombineAlpha.vhd by the same behaviour with one DSP48 instead of
#   four (timing);
#   dpram*/RamMLAB through the generic hdl/intel/altsyncram and altdpram.
#   Timing patches (patches/, same outputs every cycle): 0001 cpu.vhd computes
#   the memory address with the operand forwarding select after the adder
#   (cpu_addr_fwd.vhd); 0002 cpu_cop0.vhd writes the exception address
#   (BadVAddr, EntryHi, Context, XContext) one cycle later from registers.
#   OSD options tied to constants: rules.py.
#-----------------------------------------------------------------------------

set core_name    N64_MiSTer
set core_exclude {*/rtl/pll* */rtl/cpu_mul.vhd */rtl/Shiftreg.vhd */rtl/sdram.sv */rtl/RDP_CombineAlpha.vhd}
set core_add     {cores/n64/pll.vhd cores/n64/pll2.vhd cores/n64/pll_cfg_small.vhd cores/n64/cpu_mul.vhd cores/n64/Shiftreg.vhd cores/n64/sdram.vhd \
                  cores/n64/RDP_CombineAlpha.vhd cores/n64/cpu_addr_fwd.vhd}
# uses pRDP of the core (VHDL 2008)
set core_vhdl2008 {cores/n64/RDP_CombineAlpha.vhd}
set core_xdc     {cores/n64/core.xdc}
set core_vhdl_std 2008
# 80 % and full clocks: synthesis of mister timing driven with retiming (the
# out-of-context run has no constraints otherwise), more effort in placement and phys_opt,
# phys_opt after routing as well (scripts/mister_project.tcl mister_runs)
set core_ooc_timing 1
set core_synth_options {-global_retiming on}
set core_impl_props {
  STEPS.PLACE_DESIGN.ARGS.DIRECTIVE                 ExtraTimingOpt
  STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE              AggressiveExplore
  STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED       true
  STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE   AggressiveExplore
}
set core_master_mhz 50.0
set core_defines {MISTER_FB=1 MISTER_DOWNSCALE_NN=1 MISTER_DISABLE_ALSA=1 MISTER_ZYNQ_COREMEM=1 MISTER_ZYNQ_NO_DOWNSCALE=1
                  MISTER_SMALL_VBUF=1 MISTER_DISABLE_ADAPTIVE=1
                  MISTER_DISABLE_YC=1 MISTER_ZYNQ_SIMPLE_AUDIO=1 MISTER_ZYNQ_NO_DIRECT_VIDEO=1}
set core_generics {
  G_FREE_CLK         1
  G_DDRAM            1
  G_COREMEM          1
  G_DIRECT_VIDEO     0
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
# block RAM tiles of emu (synth_core_ooc.tcl --profile): 48 RAMB36 + 51 RAMB18 in the full build
# zybo-z7-20_n64_hdmi; the OOC run without video_mixer had 41 + 50 (66 tiles)
set core_expect_bram 73.5
