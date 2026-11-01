#-----------------------------------------------------------------------------
# Title      : MSX core constraints (MSX_MiSTer on mister_zynq)
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-28
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   clk_sys of the MSX core is every 4th pulse of the gated master clock
#   (cores/msx/pll.vhd): rising edge 1 and falling edge 2 of the master clock at
#   the BUFGCE of mister_zynq, next rising edge at edge 9.  Read before the board
#   constraints, so their clock groups include it (-include_generated_clocks).
#-----------------------------------------------------------------------------

create_generated_clock -name msx_clk_sys -source [get_pins -hier -filter {NAME =~ *core_buf/O}] \
  -edges {1 2 9} [get_pins -hier -filter {NAME =~ */emu/pll/sys_buf/O}]
