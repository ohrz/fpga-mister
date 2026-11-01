#-----------------------------------------------------------------------------
# Title      : <CORE> core constraints  -- TEMPLATE
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : <date>
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   One generated clock per derived clock of cores/<core>/pll.vhd: every Nth pulse
#   of the gated master clock (BUFGCE core_buf in mister_zynq) has its rising edges
#   1 and 2N+1 and its falling edge 2 of the master clock.  Read before the board
#   constraints, so their clock groups include it (-include_generated_clocks).
#   The instance path is the core's: emu/<pll instance>/<clk_pulse_div instance>/
#   divide.div_buf (generate label in the name: match *div_buf/O).
#   A mid clock (clk_pulse_div G_MID = M, the falling edge of the DE10 clock at
#   M = N/2) has the edges {2M+1 2M+2 2(M+N)+1}.
#-----------------------------------------------------------------------------

# N = 4 (e.g. clk_sys = clk_mem / 4, MSX): edges {1 2 9}
create_generated_clock -name core_clk_div4 -source [get_pins -hier -filter {NAME =~ *core_buf/O}] \
  -edges {1 2 9} [get_pins -hier -filter {NAME =~ */emu/pll/div4/*div_buf/O}]
# with G_MID => 2: the mid clock, master pulse 2 of 4 (edges 5 and 6)
# create_generated_clock -name core_clk_div4_mid -source [get_pins -hier -filter {NAME =~ *core_buf/O}] \
#   -edges {5 6 13} [get_pins -hier -filter {NAME =~ */emu/pll/div4/*mid_buf/O}]
