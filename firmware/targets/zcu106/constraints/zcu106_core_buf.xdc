#-----------------------------------------------------------------------------
# Title      : ZCU106 MiSTer designs: placement of the gated core clocks
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-07
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   Only for cores without G_FREE_CLK (zcu106_mister.tcl adds it then, see
#   mister_free_clk): with G_FREE_CLK 1 mister_zynq has no stage C, the cells
#   below do not exist and the empty set_property would stop make build
#   (constraints without objects).
#   The gated master clock core_buf (mister_zynq) and the BUFGCEs some cores
#   cascade behind it (cores/<core>/pll.vhd, e.g. SNES video_buf -> sys_buf)
#   go into the clock region of the MMCM clk_core (X2Y4, where the placer puts
#   core_buf anyway).  Left alone the placer put the SNES cascade in X2Y0,
#   1.7 ns of clock routing between core_buf and video_buf: 2.5 ns skew between
#   the master clock and snes_clk_sys, hold -0.377 ns on 365 endpoints
#   (2026-11-07).
#-----------------------------------------------------------------------------

set_property CLOCK_REGION X2Y4 [get_cells -hier -filter {REF_NAME =~ BUFGCE* && (NAME =~ design_1_i/mister/*core_buf || NAME =~ design_1_i/mister/*/sys/emu/*)}]
