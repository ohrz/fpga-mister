#-----------------------------------------------------------------------------
# Title      : KR260 MiSTer designs: placement of the gated core clocks
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-27
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   The rule of zcu106_core_buf.xdc for the KR260. kr260_mister.tcl adds it
#   only for the cores in core_buf_cores (snes): these cores cascade BUFGCEs
#   behind the gated master clock. The designs of menu and MSX keep their
#   checked placement without it. With G_FREE_CLK 1 the cells do not exist,
#   and the empty set_property would stop make build.
#   The gated master clock core_buf (mister_zynq) and the BUFGCEs of the core
#   (cores/snes/pll.vhd: video_buf -> sys_buf) go into the clock region of
#   the MMCM clk_core (MMCM_X0Y2, clock region X1Y2). On the ZCU106 the placer
#   put the SNES cascade far from core_buf without this rule: hold -0.377 ns.
#-----------------------------------------------------------------------------

set_property CLOCK_REGION X1Y2 [get_cells -hier -filter {REF_NAME =~ BUFGCE* && (NAME =~ design_1_i/mister/*core_buf || NAME =~ design_1_i/mister/*/sys/emu/*)}]
