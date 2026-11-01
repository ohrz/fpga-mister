#-----------------------------------------------------------------------------
# Title      : Menu core profile (Menu_MiSTer)
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-28
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   The menu core (menu.rbf, loaded by Main_MiSTer at start and between cores),
#   read by mister_core_add (scripts/mister_project.tcl); variables as in
#   cores/msx/core.tcl.
#
#   SDRAM (rtl/sdram.sv): 16 bit, CL 2, BL 1, byte address 27 bits with
#   row = addr(13:1), bank = addr(24:23), col = addr(25) & addr(22:14),
#   nCS = addr(26); read data latched one clk edge after the CL edge
#   (SDRAM_CLK = inverted clk, as MSX): G_SD_RD_ADJ 0.  The core only writes a
#   few words to detect the module size (cfg -> status_menumask, Main reads it):
#   2/13/9 bits answer as a 32 MB module.  No BRAM region (G_B0_BITS 0).
#   Clocks: clk_sys and CLK_VIDEO are both 100 MHz in the original, here the
#   master clock (cores/menu/pll.vhd) at 85 MHz with the pacer at 1/1: pixel
#   clock clk/8 = 10.6 MHz instead of 12.5 MHz, the menu picture runs at about
#   51 Hz instead of 60 Hz (the scaler outputs 720p60 anyway).  85, not 90 MHz
#   as MSX: the ascal input (downscaler line buffer, clocked by CLK_VIDEO)
#   missed 90 MHz by 0.14 ns in the menu design.
#   MENU_CORE=1 (VERILOG_MACRO of menu.qsf): OSD header line in sys/osd.v and
#   ascal N_BURST 2048, which prepare_sources.py lowers to 1024 for the 8-bit
#   burstcount of the AXI bridge.
#   MISTER_ZYNQ_NO_DOWNSCALE: ascal without the downscaler, the menu picture
#   (640 x 480 or 576) is never larger than 1280 x 720.
#   Background noise: rtl/lfsr.v is a free-running lcell ring (combinational
#   loop); cores/menu/lfsr.vhd is a clocked LFSR with the same taps on CLK_VIDEO.
#   Not ported: DDRAM (rtl/ddram.sv, console_out.sv) is tied off in mister_zynq,
#   so the Linux console / framebuffer mode of the menu shows nothing yet.
#-----------------------------------------------------------------------------

set core_name    Menu_MiSTer
# rtl/pll*: Quartus PLL (cores/menu/pll.vhd); rtl/lfsr.v: lcell ring (cores/menu/lfsr.vhd)
set core_exclude {*/rtl/pll* */rtl/lfsr.v}
set core_add     {cores/menu/pll.vhd cores/menu/lfsr.vhd}
set core_xdc     {}
set core_defines {MENU_CORE=1 MISTER_ZYNQ_NO_DOWNSCALE=1}
set core_master_mhz 85.0
set core_generics {
  G_SD_BANK_BITS     2
  G_SD_ROW_BITS      13
  G_SD_COL_BITS      9
  G_SD_RD_ADJ        0
  G_B0_BITS          0
  G_CACHE_LINE_LOG2  2
  G_CACHE_INDEX_BITS 9
  G_PACE_NUM         1
  G_PACE_DEN         1
}
