#-----------------------------------------------------------------------------
# Title      : N64 core constraints (N64_MiSTer, full speed)
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-30
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   The MMCMs of cores/n64/pll.vhd and pll2.vhd derive their clocks from the
#   clock on CLK_50M (clk_master of the board with G_FREE_CLK 1, create_clock
#   in an OOC run); here only renamed:
#     n64_clk_1x  16 ns, n64_clk_93 10.667 ns, n64_clk_2x 8 ns (same VCO, related)
#     n64_clk_vid     20.541 ns (NTSC, PLLE2 of pll2), n64_clk_vid_pal 20.139 ns
#     (PAL, MMCM of pll2): a BUFGCTRL selects one, so the two and everything
#     generated from them (video_pll of mister_zynq) are physically exclusive
#   As generated clocks of clk_master they are in its asynchronous group of the
#   board constraints.  N64.sdc: clk_vid is a false path to and from the core
#   PLL clocks (and the frame clocks, already asynchronous): its own group here.
#   The patterns match with emu as the top (OOC) and inside mister_zynq.
#   Read before the board constraints.
#-----------------------------------------------------------------------------

set n64_pll  [get_cells -hier -filter {NAME =~ *pll/mmcm && REF_NAME =~ MMCME2_*}]
set n64_pll2 [get_cells -hier -filter {NAME =~ *pll2/mmcm && REF_NAME =~ MMCME2_*}]
set n64_pll2_ntsc [get_cells -hier -filter {NAME =~ *pll2/ntsc && REF_NAME =~ PLLE2_*}]
create_generated_clock -name n64_clk_1x  [get_pins -of_objects $n64_pll  -filter {REF_PIN_NAME == CLKOUT0}]
create_generated_clock -name n64_clk_93  [get_pins -of_objects $n64_pll  -filter {REF_PIN_NAME == CLKOUT1}]
create_generated_clock -name n64_clk_2x  [get_pins -of_objects $n64_pll  -filter {REF_PIN_NAME == CLKOUT2}]
create_generated_clock -name n64_clk_vid     [get_pins -of_objects $n64_pll2_ntsc -filter {REF_PIN_NAME == CLKOUT0}]
create_generated_clock -name n64_clk_vid_pal [get_pins -of_objects $n64_pll2      -filter {REF_PIN_NAME == CLKOUT0}]

set_clock_groups -physically_exclusive -group [get_clocks -include_generated_clocks n64_clk_vid] \
  -group [get_clocks -include_generated_clocks n64_clk_vid_pal]
set_clock_groups -asynchronous -group [get_clocks {n64_clk_vid n64_clk_vid_pal}] \
  -group [get_clocks {n64_clk_1x n64_clk_93 n64_clk_2x}]

# Region select of the video clock (quasi-static, changes once per ROM):
#   N64.sv cfg_block synchronizes status[80:79] (clk_1x, hps_io) with two
#   registers onto CLK_50M (regiond, regiond2); clk_1x is a generated clock of
#   that master, so Vivado times the first stage at 4 ns.
#   pll_cfg_small's register drives S0/S1 of the BUFGCTRL in pll2, which is
#   asynchronous to both video clocks: the switch is glitch-free (the BUFGCTRL
#   waits for the edges of both inputs), only its clock edge is not determined.
set_false_path -to [get_cells -hier -filter {NAME =~ *cfg_block.regiond_reg*}]
set_property ASYNC_REG TRUE [get_cells -hier -filter {NAME =~ *cfg_block.regiond_reg* || NAME =~ *cfg_block.regiond2_reg*}]
set_false_path -to [get_pins -hier -filter {NAME =~ *pll2/buf_vid/S*}]
