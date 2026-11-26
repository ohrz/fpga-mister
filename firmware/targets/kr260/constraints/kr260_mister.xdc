#-----------------------------------------------------------------------------
# Title      : KR260 MiSTer designs (kr260_<core>): pins and clock groups
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-26
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   Pins of the K26 SOM on the KR260 carrier. The PL runs on the 25 MHz carrier
#   oscillator (SOM pin C3, LVCMOS18), not on pl_clk0: the design must
#   not depend on the boot firmware or on Linux keeping a PS clock on. The
#   video goes into the live input of the PS DisplayPort (no PL pins). The
#   carrier fan enable (SOM pin A12, active low) stays low: the fan runs at
#   full speed. Clock groups as on the ZCU106 (MiSTer's sys_top.sdc: every PLL
#   and the HPS clock exclusive). Draft: not built yet.
#-----------------------------------------------------------------------------

#---- 25 MHz carrier oscillator (the clocking wizard clk_base makes its own clock constraint)
set_property PACKAGE_PIN C3 [get_ports clk_25]
set_property IOSTANDARD LVCMOS18 [get_ports clk_25]

#---- carrier fan enable, active low: 0 = full speed (no PWM from the PS TTC in these designs)
set_property PACKAGE_PIN A12 [get_ports fan_en_b]
set_property IOSTANDARD LVCMOS33 [get_ports fan_en_b]
set_false_path -to [get_ports fan_en_b]

#---- clock groups (design_1_i/mister: the mister_zynq cell of the block design)
#     clk_hdmi is the pixel clock of clk_pix (25 MHz -> 74.25 MHz). It is also dp_video_in_clk of
#     the PS: the DisplayPort samples the live input on it.
set_clock_groups -asynchronous \
  -group [get_clocks -include_generated_clocks -of_objects [get_pins {design_1_i/mister/clk_master design_1_i/mister/clk_master_gate}]] \
  -group [get_clocks -of_objects [get_pins design_1_i/mister/clk_100]] \
  -group [get_clocks -of_objects [get_pins design_1_i/mister/clk_50]] \
  -group [get_clocks -of_objects [get_pins design_1_i/mister/clk_hdmi]] \
  -group [get_clocks -of_objects [get_pins design_1_i/mister/clk_audio]]
