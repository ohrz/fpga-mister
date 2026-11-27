#-----------------------------------------------------------------------------
# Title      : KR260 MiSTer designs: MMCM sites of the compact clocks
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-27
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   kr260_mister.tcl adds it for a core with two MMCMs of its own (PSX, N64,
#   core_swap_low_mmcm of the profile). There is no clk_base. The XCK26 has
#   four MMCMs in one column (MMCM_X0Y0 to MMCM_X0Y3):
#     MMCM_X0Y3  clk_pix 74.25 MHz, CLKIN1 directly from pin C3 (clock
#                region X1Y3, dedicated route)
#     MMCM_X0Y2  clk_core, CLKIN1 from pin C3 through the BUFG of the wizard
#                (Global_buffer). The BUFG must be in X1Y3, the region of the
#                pin (rule_gclkio_bufg), and a BUFG with an I/O driver can
#                drive an MMCM in another region only with BACKBONE
#                (rule_bufg_mmcm_1load, Place 30-716 without it)
#     MMCM_X0Y1  pll of the core, refclk = clk_master (BUFGCE of clk_core in
#                X1Y2, the adjacent clock region)
#     MMCM_X0Y0  pll2 of the core (pll2_us.vhd, NTSC and PAL), the same
#                refclk through the clock backbone (BACKBONE on the refclk net:
#                core_ultrascale_us.xdc of the profile)
#   The two wizards have no input buffer of their own (No_buffer,
#   Global_buffer), so synthesis puts one IBUF on clk_25 and no wizard makes
#   a clock constraint for it: create_clock is here. kr260_mister.tcl sets
#   PROCESSING_ORDER EARLY for this file: the core XDC names the clocks of the
#   core MMCMs, so the primary clock must exist before it.
#-----------------------------------------------------------------------------

create_clock -period 40.000 -name clk_25 [get_ports clk_25]

set_property LOC MMCM_X0Y3 [get_cells design_1_i/clk_pix/inst/mmcme4_adv_inst]
set_property LOC MMCM_X0Y2 [get_cells design_1_i/clk_core/inst/mmcme4_adv_inst]
set_property LOC MMCM_X0Y1 [get_cells -hier -filter {NAME =~ design_1_i/mister/*pll/mmcm && REF_NAME =~ MMCME*}]
set_property LOC MMCM_X0Y0 [get_cells -hier -filter {NAME =~ design_1_i/mister/*pll2/mmcm && REF_NAME =~ MMCME*}]
set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets -of_objects [get_pins design_1_i/clk_core/inst/mmcme4_adv_inst/CLKIN1]]
