#-----------------------------------------------------------------------------
# Title      : PSX core constraints (PSX_MiSTer)
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-31
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   The MMCMs/PLL of cores/psx/pll.vhd and pll2.vhd derive their clocks from
#   the clock on CLK_50M (clk_master of the board with G_FREE_CLK 1,
#   create_clock in an OOC run); here only renamed:
#     psx_clk_1x 29.538 ns, psx_clk_2x 14.769 ns, psx_clk_3x 9.846 ns
#     (same VCO, related, exactly 1:2:3)
#     psx_clk_vid 18.621 ns (NTSC, PLLE2 of pll2), psx_clk_vid_pal 18.795 ns
#     (PAL, MMCM of pll2): a BUFGCTRL selects one, so the two and everything
#     generated from them are physically exclusive
#   As generated clocks of clk_master they are in its asynchronous group of the
#   board constraints.  PSX.sdc: clk_vid is a false path to and from clk_1x and
#   clk_2x (gpu_videoout_async synchronizes between clk_vid and clk_2x); here
#   its own group, asynchronous to all three core clocks (clk_3x has no path to
#   clk_vid: OOC report_clock_interaction, cores/psx/STATUS.md).
#   The patterns match with emu as the top (OOC) and inside mister_zynq.
#   Read before the board constraints.
#-----------------------------------------------------------------------------

set psx_pll  [get_cells -hier -filter {NAME =~ *pll/mmcm && REF_NAME =~ MMCME2_*}]
set psx_pll2 [get_cells -hier -filter {NAME =~ *pll2/mmcm && REF_NAME =~ MMCME2_*}]
set psx_pll2_ntsc [get_cells -hier -filter {NAME =~ *pll2/ntsc && REF_NAME =~ PLLE2_*}]
create_generated_clock -name psx_clk_1x [get_pins -of_objects $psx_pll -filter {REF_PIN_NAME == CLKOUT0}]
create_generated_clock -name psx_clk_2x [get_pins -of_objects $psx_pll -filter {REF_PIN_NAME == CLKOUT1}]
create_generated_clock -name psx_clk_3x [get_pins -of_objects $psx_pll -filter {REF_PIN_NAME == CLKOUT2}]
create_generated_clock -name psx_clk_vid     [get_pins -of_objects $psx_pll2_ntsc -filter {REF_PIN_NAME == CLKOUT0}]
create_generated_clock -name psx_clk_vid_pal [get_pins -of_objects $psx_pll2      -filter {REF_PIN_NAME == CLKOUT0}]

set_clock_groups -physically_exclusive -group [get_clocks -include_generated_clocks psx_clk_vid] \
  -group [get_clocks -include_generated_clocks psx_clk_vid_pal]
set_clock_groups -asynchronous -group [get_clocks {psx_clk_vid psx_clk_vid_pal}] \
  -group [get_clocks {psx_clk_1x psx_clk_2x psx_clk_3x}]

# Region select of the video clock (quasi-static, changes once per game):
#   rules.py routes isPal (clk_1x) straight into pll2 (reconfig_to_pll[0]);
#   pll2 synchronizes it with two registers onto its reference clock
#   (pal_s). clk_1x is a generated clock of that reference, so Vivado would
#   time the first stage as a synchronous path.
#   pal_s drives S0/S1 of the BUFGCTRL in pll2, which is asynchronous to both
#   video clocks: the switch is glitch-free (the BUFGCTRL waits for the edges
#   of both inputs), only its clock edge is not determined.
set_false_path -to [get_cells -hier -filter {NAME =~ *pll2/pal_s_reg?0?}]
set_false_path -to [get_pins -hier -filter {NAME =~ *pll2/buf_vid/S*}]
