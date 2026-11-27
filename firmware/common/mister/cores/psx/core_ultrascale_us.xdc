#-----------------------------------------------------------------------------
# Title      : PSX core profile: clock placement rules with pll2_us.vhd
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-27
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   core_ultrascale.xdc for a board with few MMCMs (core_swap_low_mmcm of
#   core.tcl, cores/psx/pll2_us.vhd): only the first rule of core_ultrascale.xdc.
#   - pll/mmcm and pll2/mmcm take refclk from the global buffer of the board's
#     clock MMCM. BACKBONE on this net lets the two MMCMs sit in clock regions
#     that are not adjacent to the buffer (one CMT column).
#   - buf_vid gets both inputs from the one MMCM of pll2_us.vhd, so both
#     inputs have a dedicated route: no CLOCK_DEDICATED_ROUTE FALSE.
#-----------------------------------------------------------------------------

set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets -of_objects [get_pins -of_objects \
  [get_cells -hier -filter {NAME =~ *pll/mmcm && REF_NAME =~ MMCME*}] -filter {REF_PIN_NAME == CLKIN1}]]
