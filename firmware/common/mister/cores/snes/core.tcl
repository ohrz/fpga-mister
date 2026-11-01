#-----------------------------------------------------------------------------
# Title      : SNES core profile (SNES_MiSTer)
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-30
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   What a Zynq design needs to know about the SNES core (doc/PORTING.md §5.1),
#   read by mister_core_add (scripts/mister_project.tcl); fields as in cores/msx.
#   Profile decisions (rules.py): no SPC7110, backup RAM 128 KB.
#
#   SDRAM (rtl/sdram.sv): CL 2 (CAS_LATENCY, line 63), burst 1, SDRAM_CLK = inverted
#   clk (altddio_out datain_h 0 / datain_l 1), read data latched at edge CL + 1
#   (READ registered from state[0], rbuf from state[3].RD) -> G_SD_RD_ADJ 0.
#   Address: row a[13:1], column a[22:14], bank {port, a[23]} (port 0 ROM, cartridge
#   RAM areas and SNI; port 1 WRAM) -> flat bank & row & col 2/13/9 bits as on MSX,
#   column = high address bits -> G_CACHE_COL_HIGH 1 (a cache line holds neighbouring
#   bytes).  No BRAM region (G_B0_BITS 0): WRAM 128 KB would need 32 RAMB36, the BRAM
#   is used up by the core (PORTING §5.1); every access goes through the cache.
#   G_CACHE_SPLIT 1: bank MSB = port is the top cache index bit, ROM and WRAM get 8 KB
#   each.  Without it they replaced each other: 99 % of the misses hit the line the
#   last fetch had replaced, 94-99 % replaced from the other port (perf.py).
#   Clocks (rtl/pll/pll_0002.v): clk_mem 85.909, CLK_VIDEO 42.955, clk_sys 21.477 MHz
#   = 4:2:1 -> master 90 MHz, pacer 21/22, dividers 2 and 4 (cores/snes/pll.vhd).
#   G_PACE_BUCKET 1024 as on MSX (runs of cache misses).
#   PAL: clk_sys 21.28137 MHz, clk_mem 85.125 MHz = 227/240 of the master (-6 ppm):
#   pll_cfg.vhd decodes the region write of SNES.sv, emu port ZYNQ_PACE_ALT (rules.py,
#   MISTER_ZYNQ_PACE_ALT) selects G_PACE_NUM_ALT / G_PACE_DEN_ALT.
#   Macros: MISTER_SMALL_VBUF (SNES.qsf), MISTER_ZYNQ_NO_DOWNSCALE (picture at most
#   512 x 478, below 1280 x 720).
#   Replaced Intel parts: rtl/pll* (pll.vhd), sys/pll_cfg (pll_cfg.vhd, PAL as above),
#   rtl/chip/MSU1/msu_fifo.v (dcfifo, msu_fifo.vhd).
#-----------------------------------------------------------------------------

set core_name    SNES_MiSTer
set core_exclude {*/rtl/pll* */rtl/chip/MSU1/msu_fifo.v}
set core_add     {cores/snes/pll.vhd cores/snes/pll_cfg.vhd cores/snes/msu_fifo.vhd}
set core_xdc     {cores/snes/core.xdc}
set core_master_mhz 90.0
set core_defines {MISTER_SMALL_VBUF=1 MISTER_ZYNQ_NO_DOWNSCALE=1 MISTER_ZYNQ_PACE_ALT=1}
set core_generics {
  G_SD_BANK_BITS     2
  G_SD_ROW_BITS      13
  G_SD_COL_BITS      9
  G_SD_RD_ADJ        0
  G_B0_BITS          0
  G_CACHE_COL_HIGH   1
  G_CACHE_LINE_LOG2  2
  G_CACHE_INDEX_BITS 9
  G_CACHE_SPLIT      1
  G_PACE_NUM         21
  G_PACE_DEN         22
  G_PACE_BUCKET      1024
  G_PACE_NUM_ALT     227
  G_PACE_DEN_ALT     240
}
set core_expect_bram 97.5
