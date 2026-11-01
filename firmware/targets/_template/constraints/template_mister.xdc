#-----------------------------------------------------------------------------
# Title      : <board> MiSTer designs (<board>_<core>): pins and clock groups
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : <date>
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   TEMPLATE: copy to firmware/targets/<board>/constraints/<board>_mister.xdc.
#   Pins from the board's master XDC (TODO); the clock groups (CONTRACT) are the
#   same on every board: sys_top.sdc treats every PLL as exclusive, the group of
#   the master clock includes the gated core clock and the core's generated
#   clocks (core.xdc, read before this file).
#-----------------------------------------------------------------------------

#---- TODO pins: HDMI TX (hdmi_out_clk_p/n, hdmi_out_data_p/n[2:0], TMDS_33 on 7-series) or the
#     transmitter chip, audio codec (ac_*), LEDs (led[3:0]), buttons (btn[1:0]); example (Zybo Z7-20):
#     set_property -dict { PACKAGE_PIN H16 IOSTANDARD TMDS_33 } [get_ports hdmi_out_clk_p]

# asynchronous board I/O (sys_top debounces the buttons; LEDs and audio pins have no timing)
set_false_path -from [get_ports {btn[*]}]
set_false_path -to [get_ports {led[*] ac_*}]

#---- clock groups (design_1_i/mister: the mister_zynq cell of the block design)
set_clock_groups -asynchronous \
  -group [get_clocks -include_generated_clocks -of_objects [get_pins {design_1_i/mister/clk_master design_1_i/mister/clk_master_gate}]] \
  -group [get_clocks -of_objects [get_pins design_1_i/mister/clk_100]] \
  -group [get_clocks -of_objects [get_pins design_1_i/mister/clk_50]] \
  -group [get_clocks -of_objects [get_pins design_1_i/mister/clk_hdmi]] \
  -group [get_clocks -of_objects [get_pins design_1_i/mister/clk_audio]]
