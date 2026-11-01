#-----------------------------------------------------------------------------
# Title      : MSX core profile (MSX_MiSTer)
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-28
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   What a Zynq design needs to know about the MSX core (doc/ARCHITECTURE.md §3.6),
#   read by mister_core_add (scripts/mister_project.tcl):
#     core_name      checkout in _Checkouts/ (firmware/common/checkouts.txt)
#     core_exclude   files of its .qip lists that the port does not use
#     core_add       replacement files, relative to firmware/common/mister
#     core_xdc       core constraints, relative to firmware/common/mister
#     core_generics  generics of mister_zynq (SDRAM geometry, BRAM region, cache, pacer)
#     core_master_mhz  master clock of stage C (the core's CLK_50M input)
#     core_defines   Verilog macros of the core's .qsf and of the port
#
#   SDRAM (emsx_top.vhd, §3.5): bank always 0, flat address bank & row & col
#   (2/13/9 bits), read data at CL + 0.  VRAM is col(8:6) = 111 with col(5:2) the
#   VRAM page and col(1:0) VdpAdr(14:13): pages 0/1 (vram_slot_ids "00010000")
#   go to BRAM, the rest of the image through the cache to DDR:
#     G_B0_MASK  0x1F8    col(8:3)
#     G_B0_MATCH 0x1C0    col(8:6) = 111, col(5:3) = 000
#     G_B0_SEL   0x3FFE07 row(21:9) and col(2:0) -> 16 bits, 64 K words = 128 KB
#   The controller puts CpuAdr(13:1) on the row and CpuAdr(22:14) on the column:
#     G_CACHE_COL_HIGH 1  cache and DDR word = bank & col & row = CpuAdr(22:1), so a
#                         cache line holds 32 neighbouring CPU bytes (DDR byte = CpuAdr xor 1)
#   MISTER_ZYNQ_NO_DOWNSCALE: ascal without the downscaler; the MSX picture (at most about
#   600 x 242, 484 lines interlaced) is never larger than 1280 x 720.
#   Pacer 21/22 of 90 MHz: clk_mem 85.9 MHz, clk_sys (every 4th pulse) 21.48 MHz,
#   the rates of the original PLL (outclk_0 85.909 MHz, outclk_1 21.477 MHz).
#   G_PACE_BUCKET 1024: a run of cache misses stalls the core for more than the 64 edges of
#   the default bucket; 1024 edges are caught up at 90 MHz within about 12 us.
#-----------------------------------------------------------------------------

set core_name    MSX_MiSTer
# VM2413: OPLL not instantiated by MSX.sv; rtl/pll*: Quartus PLL (cores/msx/pll.vhd)
set core_exclude {*/VM2413/* */rtl/pll*}
set core_add     {cores/msx/pll.vhd cores/msx/scc_rom_hide.vhd}
set core_xdc     {cores/msx/core.xdc}
set core_master_mhz 90.0
set core_defines {MISTER_ZYNQ_NO_DOWNSCALE=1}
set core_generics {
  G_SD_BANK_BITS     2
  G_SD_ROW_BITS      13
  G_SD_COL_BITS      9
  G_SD_RD_ADJ        0
  G_B0_MASK          504
  G_B0_MATCH         448
  G_B0_SEL           4193799
  G_B0_BITS          16
  G_CACHE_COL_HIGH   1
  G_CACHE_LINE_LOG2  2
  G_CACHE_INDEX_BITS 9
  G_PACE_NUM         21
  G_PACE_DEN         22
  G_PACE_BUCKET      1024
}
set core_expect_bram 12.5
