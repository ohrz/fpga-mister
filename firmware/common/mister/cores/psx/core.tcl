#-----------------------------------------------------------------------------
# Title      : PSX core profile (PSX_MiSTer)
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-31
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   What a Zynq design needs to know about the PlayStation core (doc/PORTING.md
#   §5.1 "PSX auf dem Zybo"), read by mister_core_add (scripts/mister_project.tcl);
#   fields as in cores/n64.  A stage D core like N64:
#   G_FREE_CLK 1: CLK_50M is clk_master itself (core_master_mhz 50, a
#   free-running BUFG output, no stage C); the MMCM of pll.vhd and the PLLE2 +
#   MMCM of pll2.vhd sit on it, their clocks are generated clocks of
#   clk_master.  The G_SD_*, G_B0_*, G_CACHE_* and G_PACE_* generics have no
#   effect then (defaults).
#   G_DDRAM 1: DDRAM_* on HP2, DDRAM_CLK = clk_2x.  DDR plan of the core
#   (rtl/psx_mister.vhd: DDRAM_ADDR(28:25) = 0011, byte address 0x3000_0000 +
#   ddr3_ADDR(27:0) of rtl/psx_top.vhd): VRAM 1 MB at 0x3000_0000 and its frame
#   copies up to 0x307F_FFFF (rtl/gpu.vhd vram_ADDR(27:20) 0x00, 0x04-0x07),
#   memory cards 0x3010_0000 and 0x3020_0000, SPU RAM 0x3030_0000 (512 KB);
#   savestates 0x3E00_0000 (4 slots of 4 MB, Softmap_SaveState_ADDR) and rewind
#   0x3800_0000 (Softmap_Rewind_ADDR) are off in this profile.  Bursts up to 128
#   beats (VRAM, memory cards): avl_axi_bridge splits them (AXI3 <= 16).
#   G_COREMEM 1: stage D, rtl/sdram.sv replaced by cores/psx/sdram.vhd, its
#   Avalon master as emu port COREMEM_* (rules.py) -> sys_top_zynq
#   ZYNQ_coremem_* (MISTER_ZYNQ_COREMEM) -> HP3 at G_SDRAM_BASE 0x3800_0000
#   (default).  The core's SDRAM space (byte addresses of ch1-ch3, PSX.sv):
#   main RAM 2 MB from 0 (8 MB option off), BIOS at 0x80_0000 (512 KB per
#   region, up to 0x9F_FFFF), EXE download at 0x100_0000 (up to 0x17F_FFFF),
#   so 0x3800_0000-0x397F_FFFF: clear of the DDRAM areas above, of the ascal
#   buffers (0x2000_0000) and of Main's savestate area (0x3E00_0000; its
#   CONF_STR entry is removed, rules.py); only the rewind area (off) overlaps.
#   Picture through ascal (G_DIRECT_VIDEO 0): fixed 1280 x 720 at 60 Hz on
#   clk_hdmi, frame buffer on HP1; MISTER_FB from PSX.qsf (FB_* stay: the
#   480p hack and the debug DDR frame buffer that would use them are off).
#   ascal slimmed down as N64: MISTER_ZYNQ_NO_DOWNSCALE (the PSX picture is at
#   most 640 x 576 (interlaced)), MISTER_SMALL_VBUF, MISTER_DISABLE_ADAPTIVE,
#   MISTER_DISABLE_YC (no analogue output).  MISTER_ZYNQ_SIMPLE_AUDIO: the
#   core audio straight to I2S instead of audio_out (1.6k LUT);
#   MISTER_ZYNQ_NO_DIRECT_VIDEO: no VGA OSD and direct video path (1k LUT).
#
#   Clocks (rtl/pll/pll_0002.v, rtl/pll2/pll2_0002.v): clk_1x 33.8688,
#   clk_2x 67.7376, clk_3x 101.6064 MHz (1:2:3, phase-locked: clk2xIndex),
#   clk_vid 53.693175 MHz (NTSC; PAL 53.203425 and fast forward 85 MHz by
#   reconfiguration over pll_cfg).  cores/psx/pll.vhd: one MMCM, VCO 812.5 MHz,
#   /24 /12 /8 = 33.854/67.708/101.563 MHz (-432 ppm); cores/psx/pll2.vhd: NTSC
#   53.704 MHz (PLLE2, +196 ppm) and PAL 53.205 MHz (MMCM, +32 ppm) behind a
#   BUFGCTRL, isPal of PSX.sv selects PAL (rules.py; pll_cfg.vhd only takes the writes); fast
#   forward off (rules.py).  MMCMs on the xc7z020: frame 2 + pll + pll2 PAL = 4
#   of 4.
#   Macros (PSX.qsf): MISTER_FB, MISTER_DOWNSCALE_NN, MISTER_DISABLE_ALSA;
#   MISTER_ZYNQ_* and the ascal macros above.  VHDL-2008 (VHDL_INPUT_VERSION).
#   Replaced: rtl/pll* (pll.v, pll2.v) by pll.vhd, pll2.vhd; sys/pll_cfg by
#   pll_cfg.vhd; rtl/sdram.sv (SDRAM pins) by sdram.vhd (Avalon master,
#   stage D); rtl/savestates.vhd by savestates.vhd (only the reset sequence:
#   savestates off); dpram*/RamMLAB through the generic hdl/intel/altsyncram
#   and altdpram.  OSD options tied to constants: rules.py.
#-----------------------------------------------------------------------------

set core_name    PSX_MiSTer
set core_exclude {*/rtl/pll* */rtl/sdram.sv */rtl/savestates.vhd}
set core_add     {cores/psx/pll.vhd cores/psx/pll2.vhd cores/psx/pll_cfg.vhd cores/psx/sdram.vhd cores/psx/savestates.vhd}
set core_xdc     {cores/psx/core.xdc}
set core_vhdl_std 2008
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
# block RAM tiles of emu (synth_core_ooc.tcl --profile): 80 RAMB36 + 35 RAMB18 in the OOC
# synthesis with savestates.vhd (with rtl/savestates.vhd 98.5)
set core_expect_bram 97.5
