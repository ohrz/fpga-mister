#-----------------------------------------------------------------------------
# Title      : SNES core constraints (SNES_MiSTer on mister_zynq)
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-30
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   CLK_VIDEO is every 2nd pulse of the gated master clock (BUFGCE core_buf of
#   mister_zynq), clk_sys every 2nd pulse of CLK_VIDEO (cores/snes/pll.vhd):
#   rising edge 1 and falling edge 2 of the source, next rising edge at edge 5;
#   clk_sys_mid the other CLK_VIDEO pulses (the falling edge of clk_sys on the
#   DE10, patch 0002).
#   Read before the board constraints, so their clock groups include them
#   (-include_generated_clocks).
#-----------------------------------------------------------------------------

create_generated_clock -name snes_clk_video -source [get_pins -hier -filter {NAME =~ *core_buf/O}] \
  -edges {1 2 5} [get_pins -hier -filter {NAME =~ */emu/pll/video_buf/O}]
create_generated_clock -name snes_clk_sys -source [get_pins -hier -filter {NAME =~ */emu/pll/video_buf/O}] \
  -edges {1 2 5} [get_pins -hier -filter {NAME =~ */emu/pll/sys_buf/O}]
# clk_sys_mid: refclk pulse 3 of 4 (master edges 5 and 6), where the DE10 clk_sys falls
create_generated_clock -name snes_clk_sys_mid -source [get_pins -hier -filter {NAME =~ *core_buf/O}] \
  -edges {5 6 13} [get_pins -hier -filter {NAME =~ */emu/pll/mid_buf/O}]

#---- SNES.sdc: paths between the core and the SDRAM controller (clk_sys <-> clk_mem).
#     Quartus: set_max_delay 20 core -> sdram, 23 sdram -> core, at a clk_mem period of
#     11.640 ns; scaled to the master period 11.111 ns: 19.0 and 21.9 ns (2 clk_mem periods
#     22.2 ns).  Register names as Vivado names them (_reg; SDRAM_DQ is sdram_dq_r, rules.py).
set snes_core [get_cells -hier -filter {IS_SEQUENTIAL && (NAME =~ */emu/hps_io/* || NAME =~ */emu/main/* || \
  NAME =~ */emu/bsram/* || NAME =~ */emu/rom_mask_reg* || NAME =~ */emu/rom_type_reg*)}]
set snes_sdram_in [get_cells -hier -filter {IS_SEQUENTIAL && (NAME =~ */emu/sdram/addr_reg* || \
  NAME =~ */emu/sdram/din_reg* || NAME =~ */emu/sdram/rfs* || NAME =~ */emu/sdram/write_reg* || \
  NAME =~ */emu/sdram/read_reg* || NAME =~ */emu/sdram/word_reg* || NAME =~ */emu/sdram/old_* || \
  NAME =~ */emu/sdram/is_sni_reg* || NAME =~ */emu/sdram/st_num_reg* || NAME =~ */emu/sdram/state_reg[1]* || \
  NAME =~ */emu/sdram/SDRAM_nCAS_reg* || NAME =~ */emu/sdram/SDRAM_nRAS_reg* || NAME =~ */emu/sdram/SDRAM_nWE_reg* || \
  NAME =~ */emu/sdram/sdram_dq_r_reg* || NAME =~ */emu/sdram/SDRAM_A_reg* || NAME =~ */emu/sdram/SDRAM_BA_reg*)}]
set_max_delay 19.0 -from $snes_core -to $snes_sdram_in
set_max_delay 21.9 -from [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ */emu/sdram/*}] \
  -to [get_cells -hier -filter {IS_SEQUENTIAL && (NAME =~ */emu/main/* || NAME =~ */emu/bsram/* || NAME =~ */emu/vram*/*)}]
set_false_path -from [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ */emu/sdram_download_*}] \
  -to [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ */emu/main/*}]
set_false_path -from [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ */emu/en216p_reg*}]
