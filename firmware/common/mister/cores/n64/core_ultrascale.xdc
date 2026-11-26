#-----------------------------------------------------------------------------
# Title      : N64 core profile: clock placement rules of UltraScale(+) devices
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-07
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   core_xdc_ultrascale of core.tcl: mister_project.tcl adds it only on an
#   UltraScale(+) part, for the implementation (ZCU106, 2026-11-07: the placer
#   stopped with Place 30-718 and 30-674 without it).  7 series needs neither.
#   - The core's MMCMs (pll/mmcm, pll2/mmcm, pll2/ntsc) take refclk from a
#     global buffer of the board's clock MMCM: an MMCM -> BUFGCE -> MMCM
#     cascade must stay in one CMT column (BACKBONE) instead of in adjacent
#     CMTs, which three MMCMs on one refclk cannot.
#   - buf_vid (BUFGCTRL, NTSC/PAL switch of pll2.vhd) has two MMCM sources;
#     each CMT reaches only the global buffers of its own clock region, so the
#     PAL clock comes to buf_vid over general routing (clk_vid only clocks
#     the video side, asynchronous to the core, cores/n64/core.xdc).
#-----------------------------------------------------------------------------

set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets -of_objects [get_pins -of_objects \
  [get_cells -hier -filter {NAME =~ *pll/mmcm && REF_NAME =~ MMCME*}] -filter {REF_PIN_NAME == CLKIN1}]]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_pins -of_objects \
  [get_cells -hier -filter {NAME =~ *pll2/mmcm && REF_NAME =~ MMCME*}] -filter {REF_PIN_NAME == CLKOUT0}]]
