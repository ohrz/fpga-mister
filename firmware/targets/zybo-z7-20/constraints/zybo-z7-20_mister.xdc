#-----------------------------------------------------------------------------
# Title      : Zybo Z7-20 MiSTer designs (zybo-z7-20_<core>): pins and clock groups
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-28
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   Pins from Zybo-Z7-Master.xdc.  Clock groups as MiSTer's sys_top.sdc (every
#   PLL and the HPS clock exclusive): the framework synchronizes between them
#   itself.  The group of the stage C master clock includes the gated core clock
#   (BUFGCE in mister_zynq, same clock) and the core's generated clocks (core
#   constraints, read before this file).
#-----------------------------------------------------------------------------

#---- HDMI TX (rgb2dvi, TMDS)
set_property -dict { PACKAGE_PIN H17 IOSTANDARD TMDS_33 } [get_ports hdmi_out_clk_n]
set_property -dict { PACKAGE_PIN H16 IOSTANDARD TMDS_33 } [get_ports hdmi_out_clk_p]
set_property -dict { PACKAGE_PIN D20 IOSTANDARD TMDS_33 } [get_ports {hdmi_out_data_n[0]}]
set_property -dict { PACKAGE_PIN D19 IOSTANDARD TMDS_33 } [get_ports {hdmi_out_data_p[0]}]
set_property -dict { PACKAGE_PIN B20 IOSTANDARD TMDS_33 } [get_ports {hdmi_out_data_n[1]}]
set_property -dict { PACKAGE_PIN C20 IOSTANDARD TMDS_33 } [get_ports {hdmi_out_data_p[1]}]
set_property -dict { PACKAGE_PIN A20 IOSTANDARD TMDS_33 } [get_ports {hdmi_out_data_n[2]}]
set_property -dict { PACKAGE_PIN B19 IOSTANDARD TMDS_33 } [get_ports {hdmi_out_data_p[2]}]

#---- audio codec SSM2603 (I2S playback, configuration over PS I2C0 / EMIO)
set_property -dict { PACKAGE_PIN R17 IOSTANDARD LVCMOS33 } [get_ports ac_mclk]
set_property -dict { PACKAGE_PIN R19 IOSTANDARD LVCMOS33 } [get_ports ac_bclk]
set_property -dict { PACKAGE_PIN T19 IOSTANDARD LVCMOS33 } [get_ports ac_pblrc]
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports ac_pbdat]
set_property -dict { PACKAGE_PIN P18 IOSTANDARD LVCMOS33 } [get_ports ac_muten]
set_property -dict { PACKAGE_PIN N18 IOSTANDARD LVCMOS33 } [get_ports ac_iic_scl_io]
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports ac_iic_sda_io]

#---- LEDs (0 user, 1 disk, 2 power, 3 stage C error) and buttons (0 OSD, 1 user)
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports {btn[0]}]
set_property -dict { PACKAGE_PIN P16 IOSTANDARD LVCMOS33 } [get_ports {btn[1]}]

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
