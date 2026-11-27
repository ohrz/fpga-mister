#-----------------------------------------------------------------------------
# Title      : KR260 MiSTer designs: MMCM sites of the frame clocks
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-27
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   kr260_mister.tcl adds it for a core without MMCMs of its own (menu, MSX,
#   SNES): clk_base, clk_core and clk_pix use 3 of the 4 MMCMs of the XCK26.
#   The clocking wizard clk_base makes the clock constraint of clk_25.
#-----------------------------------------------------------------------------

#---- MMCM sites: four MMCMs in one column; clk_base must be in the clock region of pin C3 (X1Y3),
#     clk_core next to it (dedicated cascade route, rule_bufg_mmcm), clk_pix two regions lower
#     through the clock backbone (asynchronous pixel clock, kr260_mister.tcl)
set_property LOC MMCM_X0Y3 [get_cells design_1_i/clk_base/inst/mmcme4_adv_inst]
set_property LOC MMCM_X0Y2 [get_cells design_1_i/clk_core/inst/mmcme4_adv_inst]
set_property LOC MMCM_X0Y1 [get_cells design_1_i/clk_pix/inst/mmcme4_adv_inst]
set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets design_1_i/clk_base/inst/clk_out2]
