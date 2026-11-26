#-----------------------------------------------------------------------------
# Title      : ZCU106 MiSTer designs (zcu106_<core>): pins and clock groups
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-07
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   Pins from zcu106_rev1.0_20180210.xdc (UG1244).  The PL runs on the board
#   oscillator CLK_125 (not on pl_clk0: the design must not depend on the FSBL
#   or on Linux keeping a PS clock on).  HDMI output: three GTH lanes of quad
#   223 (placed by the transceiver IP), reference clock from the Si5324,
#   clock lane LVDS into the DP159, sideband and HDMI_CTL I2C on bank 87.
#   Clock groups as the Zybo designs (MiSTer's sys_top.sdc: every PLL and the
#   HPS clock exclusive) plus the transceiver clocks.
#-----------------------------------------------------------------------------

#---- 125 MHz board oscillator (bank 68, VADJ 1.8 V)
set_property PACKAGE_PIN H9 [get_ports clk_125_clk_p]
set_property PACKAGE_PIN G9 [get_ports clk_125_clk_n]
set_property IOSTANDARD LVDS [get_ports {clk_125_clk_p clk_125_clk_n}]
# the 8 ns clock comes from the clocking wizard clk_base (its own XDC, board interface CLK_125)

#---- HDMI output: GTH reference clock (Si5324 -> MGTREFCLK0_223), clock lane, sideband, HDMI_CTL
set_property PACKAGE_PIN AD8 [get_ports hdmi_refclk_p]
set_property PACKAGE_PIN AD7 [get_ports hdmi_refclk_n]
create_clock -name hdmi_refclk -period 6.734 [get_ports hdmi_refclk_p]
set_property PACKAGE_PIN G21 [get_ports hdmi_tx_clk_p]
set_property PACKAGE_PIN F21 [get_ports hdmi_tx_clk_n]
set_property IOSTANDARD LVDS [get_ports {hdmi_tx_clk_p hdmi_tx_clk_n}]
# GTH lanes of quad 223 (the IP's LOC constraints place the channels X0Y0..X0Y2 on these pins)
set_property PACKAGE_PIN AN6 [get_ports {hdmi_tx_p[0]}]
set_property PACKAGE_PIN AM4 [get_ports {hdmi_tx_p[1]}]
set_property PACKAGE_PIN AL6 [get_ports {hdmi_tx_p[2]}]
set_property PACKAGE_PIN AP4 [get_ports {hdmi_rx_p[0]}]
set_property PACKAGE_PIN AN2 [get_ports {hdmi_rx_p[1]}]
set_property PACKAGE_PIN AL2 [get_ports {hdmi_rx_p[2]}]
set_property PACKAGE_PIN N11 [get_ports hdmi_tx_en]
set_property PACKAGE_PIN H8  [get_ports hdmi_si5324_rst_n]
set_property PACKAGE_PIN G8  [get_ports hdmi_si5324_lol]
set_property PACKAGE_PIN N12 [get_ports hdmi_ctl_scl]
set_property PACKAGE_PIN P12 [get_ports hdmi_ctl_sda]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_tx_en hdmi_si5324_rst_n hdmi_si5324_lol hdmi_ctl_scl hdmi_ctl_sda}]
set_property PULLUP true [get_ports {hdmi_ctl_scl hdmi_ctl_sda}]

#---- LEDs (bank 66 1.2 V and LED 3 on bank 64): 0 user, 1 disk, 2 power, 3 stage C error,
#     4..7 HDMI status (I2C done, I2C error, transceiver up, FIFO reader running)
set_property PACKAGE_PIN AL11 [get_ports {led[0]}]
set_property PACKAGE_PIN AL13 [get_ports {led[1]}]
set_property PACKAGE_PIN AK13 [get_ports {led[2]}]
set_property PACKAGE_PIN AE15 [get_ports {led[3]}]
set_property PACKAGE_PIN AM8  [get_ports {led[4]}]
set_property PACKAGE_PIN AM9  [get_ports {led[5]}]
set_property PACKAGE_PIN AM10 [get_ports {led[6]}]
set_property PACKAGE_PIN AM11 [get_ports {led[7]}]
set_property IOSTANDARD LVCMOS12 [get_ports {led[*]}]

#---- buttons: GPIO_SW_C OSD, GPIO_SW_N user (bank 66, active high)
set_property PACKAGE_PIN AL10 [get_ports {btn[0]}]
set_property PACKAGE_PIN AG13 [get_ports {btn[1]}]
set_property IOSTANDARD LVCMOS12 [get_ports {btn[*]}]

# asynchronous board I/O (sys_top debounces the buttons; LEDs and the HDMI sideband have no timing)
set_false_path -from [get_ports {btn[*] hdmi_si5324_lol}]
set_false_path -to [get_ports {led[*] hdmi_tx_en hdmi_si5324_rst_n}]

#---- clock groups (design_1_i/mister: the mister_zynq cell of the block design)
#     clk_hdmi is the pixel clock of the transmitter (BUFG_GT of the Si5324 reference); the
#     transceiver's TXUSRCLK2 is reached only through the dual-clock FIFO of zcu106_hdmi
set_clock_groups -asynchronous \
  -group [get_clocks -include_generated_clocks -of_objects [get_pins {design_1_i/mister/clk_master design_1_i/mister/clk_master_gate}]] \
  -group [get_clocks -of_objects [get_pins design_1_i/mister/clk_100]] \
  -group [get_clocks -of_objects [get_pins design_1_i/mister/clk_50]] \
  -group [get_clocks -of_objects [get_pins design_1_i/mister/clk_hdmi]] \
  -group [get_clocks -of_objects [get_pins design_1_i/mister/clk_audio]] \
  -group [get_clocks -of_objects [get_pins design_1_i/hdmi/clk_free]] \
  -group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ design_1_i/hdmi/*gth*/*TXOUTCLK}]]

#---- Gray pointers of the symbol FIFO (pixel clock <-> TXUSRCLK2): the clock groups cut the paths,
#     set_bus_skew still holds the bits of a pointer within one pixel period of each other
set_bus_skew -from [get_cells -hier -filter {NAME =~ design_1_i/hdmi/*fifo/wr_gray_reg[*]}] \
  -to [get_cells -hier -filter {NAME =~ design_1_i/hdmi/*fifo/wr_gray_r1_reg[*]}] 6.700
set_bus_skew -from [get_cells -hier -filter {NAME =~ design_1_i/hdmi/*fifo/rd_gray_reg[*]}] \
  -to [get_cells -hier -filter {NAME =~ design_1_i/hdmi/*fifo/rd_gray_w1_reg[*]}] 6.700
