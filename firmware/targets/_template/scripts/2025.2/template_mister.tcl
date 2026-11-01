#-----------------------------------------------------------------------------
# Title      : <board> MiSTer design of one core (<board>_<core>[_hdmi])
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : <date>
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   TEMPLATE (firmware/targets/_template): copy to
#   firmware/targets/<board>/scripts/<ver>/<board>_mister.tcl, replace every
#   "<board>" and resolve every TODO.  Made from zybo-z7-20_mister.tcl; what the
#   board must provide to mister_zynq is the board contract, doc/PORTING.md §7.1.
#   Parts marked CONTRACT are the same on every board and stay as they are.
#
#   Generator of every MiSTer design of the board: FLOW=vivado passes
#   -tclargs <board> <core> [dvi|hdmi] for CORE=<core> VIDEO_TX=dvi|hdmi or
#   TOPLEVEL=<board>_<core>[_hdmi]; the core comes from its profile
#   firmware/common/mister/cores/<core>/core.tcl (mister_project.tcl).
#-----------------------------------------------------------------------------

# core and video output: variables of a sourcing script, else -tclargs <platform> <core> [dvi|hdmi]
if {![info exists core_id] && [llength $argv] >= 2} { set core_id [lindex $argv 1] }
if {![info exists video_tx] && [llength $argv] >= 3} { set video_tx [lindex $argv 2] }
if {![info exists core_id]} { error "<board>_mister.tcl: no core (-tclargs <platform> <core> \[dvi|hdmi\])" }
if {![info exists video_tx]} { set video_tx dvi }
if {$video_tx ni {dvi hdmi}} { error "<board>_mister.tcl: video_tx must be dvi or hdmi, not $video_tx" }
set proj_name  <board>_$core_id[expr {$video_tx eq "hdmi" ? "_hdmi" : ""}]
set script_dir [file normalize [file dirname [info script]]]
set target_dir [file normalize [file join $script_dir .. ..]]
set root_dir   [file normalize [file join $target_dir .. .. ..]]
set dgl_repo   [file join $root_dir _Checkouts vivado-library]
if { ![file isdirectory [file join $dgl_repo ip rgb2dvi]] } {
  error "Digilent vivado-library not found: $dgl_repo (PLATFORM=<board> FLOW=vivado make setup)"
}
set hdmi_tx_src [file join $root_dir firmware common ip hdmi-tx src]
if { $video_tx eq "hdmi" && ![file isfile [file join $hdmi_tx_src hdmi_out.vhd]] } {
  error "hdmi-tx not found: $hdmi_tx_src"
}

# TODO part and board files of the board
create_project $proj_name ./$proj_name -part <part> -force
set_property board_part_repo_paths [list [file join $target_dir board_files]] [current_project]
set_property board_part <vendor>:<board>:part0:<rev> [current_project]
set_property target_language VHDL [current_project]
set_property ip_repo_paths [list $dgl_repo] [current_project]
update_ip_catalog

# core sources and constraints, then the board constraints (after the core's generated clocks)
source [file join $root_dir firmware common mister scripts mister_project.tcl]
set core [mister_core_add $root_dir $core_id]
add_files -fileset constrs_1 -norecurse [file join $target_dir constraints <board>_mister.xdc]
if {$video_tx eq "hdmi"} {
  add_files -norecurse [glob [file join $hdmi_tx_src *.vhd]]
}
update_compile_order -fileset sources_1

create_bd_design design_1

#---- PS: board preset, FCLK0 100 MHz only, GP0, HP0/HP1 (HP2, HP3) (64 bit), I2C0 on EMIO (codec)
# CONTRACT: FCLK0 100 MHz, M_AXI_GP0, S_AXI_HP0 + S_AXI_HP1 64 bit (AXI3, mister_zynq masters),
#           S_AXI_HP2 64 bit for profiles with G_DDRAM 1, S_AXI_HP3 64 bit with G_COREMEM 1
# TODO ZynqMP (zynq_ultra_ps_e): pl_clk0, M_AXI_HPM0_LPD or _FPD for GP0, S_AXI_HP0_FPD/HP1_FPD
#      (AXI4, 128 bit by default: set 64 bit or add a width converter), address map below differs
# TODO codec control: I2C on EMIO only when the codec needs it
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
  -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps
set_property -dict [list CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} CONFIG.PCW_EN_CLK1_PORT {0} \
  CONFIG.PCW_EN_CLK2_PORT {0} CONFIG.PCW_EN_CLK3_PORT {0} CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_USE_S_AXI_HP0 {1} CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
  CONFIG.PCW_USE_S_AXI_HP1 {1} CONFIG.PCW_S_AXI_HP1_DATA_WIDTH {64} \
  CONFIG.PCW_I2C0_PERIPHERAL_ENABLE {1} CONFIG.PCW_I2C0_I2C0_IO {EMIO}] $ps
# DDRAM_* of the core (profile G_DDRAM 1) on a third HP port, clocked by the core's DDRAM_CLK
set ddram [mister_ddram $core]
if {$ddram} {
  set_property -dict [list CONFIG.PCW_USE_S_AXI_HP2 {1} CONFIG.PCW_S_AXI_HP2_DATA_WIDTH {64}] $ps
}
# memory port of a replaced SDRAM controller (profile G_COREMEM 1) on a fourth HP port, its clock
set coremem [mister_coremem $core]
if {$coremem} {
  set_property -dict [list CONFIG.PCW_USE_S_AXI_HP3 {1} CONFIG.PCW_S_AXI_HP3_DATA_WIDTH {64}] $ps
}
set clk0 [get_bd_pins processing_system7_0/FCLK_CLK0]
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 ac_iic
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/IIC_0] [get_bd_intf_ports ac_iic]

#---- clocks and resets
# CONTRACT: clk_core from FCLK0: clk_out1 24.576 MHz (audio), clk_out2 master clock of the profile,
# clk_out3 50 MHz, clk_out4 the master clock again WITHOUT BUFG (No_buffer, same divide and phase,
# checked at the end): input of the BUFGCE core_buf in mister_zynq; clk_hdmi 74.25 / 371.25 MHz
set master_mhz [format %.3f [dict get $core master_mhz]]
set cc [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_core]
set_property -dict [list CONFIG.PRIMITIVE {MMCM} CONFIG.PRIM_IN_FREQ {100.000} CONFIG.PRIM_SOURCE {No_buffer} \
  CONFIG.NUM_OUT_CLKS {4} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {24.576} \
  CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ $master_mhz \
  CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {50.000} \
  CONFIG.CLKOUT4_USED {true} CONFIG.CLKOUT4_REQUESTED_OUT_FREQ $master_mhz CONFIG.CLKOUT4_DRIVES {No_buffer} \
  CONFIG.USE_RESET {true} CONFIG.RESET_TYPE {ACTIVE_LOW} CONFIG.USE_LOCKED {true}] $cc
set ch [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_hdmi]
set_property -dict [list CONFIG.PRIMITIVE {MMCM} CONFIG.PRIM_IN_FREQ {100.000} CONFIG.PRIM_SOURCE {No_buffer} \
  CONFIG.NUM_OUT_CLKS {2} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {74.250} \
  CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {371.250} \
  CONFIG.USE_RESET {true} CONFIG.RESET_TYPE {ACTIVE_LOW} CONFIG.USE_LOCKED {true}] $ch
foreach w {clk_core clk_hdmi} {
  connect_bd_net $clk0 [get_bd_pins $w/clk_in1]
  connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins $w/resetn]
}
set clk_audio  [get_bd_pins clk_core/clk_out1]
set clk_master [get_bd_pins clk_core/clk_out2]
set clk_50     [get_bd_pins clk_core/clk_out3]
# the master clock once more without BUFG: input of the BUFGCE core_buf in mister_zynq (a BUFG
# cascade from clk_out2 would leave the core profiles one cascade stage less, Place 30-120)
set clk_master_gate [get_bd_pins clk_core/clk_out4]

# one reset for the PL (FCLK0 domain); mister_zynq synchronizes it into the master clock
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_axi
connect_bd_net $clk0 [get_bd_pins rst_axi/slowest_sync_clk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins rst_axi/ext_reset_in]
connect_bd_net [get_bd_pins clk_core/locked] [get_bd_pins rst_axi/dcm_locked]
set rst0 [get_bd_pins rst_axi/peripheral_aresetn]

#---- MiSTer: mister_zynq with the core
set mz [create_bd_cell -type module -reference mister_zynq mister]
set_property -dict [mister_bd_config $core] $mz
connect_bd_net $clk0       [get_bd_pins mister/clk_100]
connect_bd_net $rst0       [get_bd_pins mister/aresetn]
connect_bd_net $clk_50     [get_bd_pins mister/clk_50]
connect_bd_net $clk_master [get_bd_pins mister/clk_master]
connect_bd_net $clk_master_gate [get_bd_pins mister/clk_master_gate]
connect_bd_net $clk_audio  [get_bd_pins mister/clk_audio]
connect_bd_net [get_bd_pins clk_hdmi/clk_out1] [get_bd_pins mister/clk_hdmi]
# clocks of the HDMI transmitter: clk_hdmi (ascal, fixed 720p60), or with direct video (profile
# G_DIRECT_VIDEO 1, no ascal) the core's video clock and its 5x from video_pll in mister_zynq;
# clk_hdmi then has no load inside mister_zynq
set dv [mister_direct_video $core]
if {$dv} {
  set tx_pix [get_bd_pins mister/vid_clk]; set tx_ser [get_bd_pins mister/vid_clk_ser]
  set tx_locked [get_bd_pins mister/vid_locked]
} else {
  set tx_pix [get_bd_pins clk_hdmi/clk_out1]; set tx_ser [get_bd_pins clk_hdmi/clk_out2]
  set tx_locked [get_bd_pins clk_hdmi/locked]
}

# AXI-Lite: GP0 -> hps_bus_axi
set axil [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axil]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $axil
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins axil/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axil/M00_AXI] [get_bd_intf_pins mister/s_axi]
connect_bd_net $clk0 [get_bd_pins axil/aclk] [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK]
connect_bd_net $rst0 [get_bd_pins axil/aresetn]

# memory: SDRAM image on HP0 (master clock), frame buffer on HP1 (FCLK0), DDRAM_* on HP2 (ddram_clk),
# COREMEM on HP3 (coremem_clk); AXI3, 64 bit, direct
connect_bd_intf_net [get_bd_intf_pins mister/m_axi_sdram] [get_bd_intf_pins processing_system7_0/S_AXI_HP0]
connect_bd_net $clk_master [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK]
connect_bd_intf_net [get_bd_intf_pins mister/m_axi_vbuf] [get_bd_intf_pins processing_system7_0/S_AXI_HP1]
connect_bd_net $clk0 [get_bd_pins processing_system7_0/S_AXI_HP1_ACLK]
if {$ddram} {
  connect_bd_intf_net [get_bd_intf_pins mister/m_axi_ddram] [get_bd_intf_pins processing_system7_0/S_AXI_HP2]
  connect_bd_net [get_bd_pins mister/ddram_clk] [get_bd_pins processing_system7_0/S_AXI_HP2_ACLK]
}
if {$coremem} {
  connect_bd_intf_net [get_bd_intf_pins mister/m_axi_coremem] [get_bd_intf_pins processing_system7_0/S_AXI_HP3]
  connect_bd_net [get_bd_pins mister/coremem_clk] [get_bd_pins processing_system7_0/S_AXI_HP3_ACLK]
}

#---- HDMI output with the serial clock of clk_hdmi: rgb2dvi (kGenerateSerialClk false)
#     or hdmi_out; the ports hdmi_out_* are the same (constraints)
# TODO TMDS pins straight at the FPGA (7-series TMDS_33): keep this block; a transmitter chip
#      (ADV7511, ...): vid_* (R & B & G) + i2s_* parallel to its pins instead, no rgb2dvi/hdmi_out;
#      UltraScale+ has no TMDS_33 (firmware/common/ip/hdmi-tx: 7-series only, open)
if {$video_tx eq "dvi"} {
  set tx [create_bd_cell -type ip -vlnv digilentinc.com:ip:rgb2dvi:1.4 hdmi_tx_dvi]
  set_property -dict [list CONFIG.kGenerateSerialClk {false} CONFIG.kRstActiveHigh {false}] $tx
  connect_bd_net $tx_pix [get_bd_pins hdmi_tx_dvi/PixelClk]
  connect_bd_net $tx_ser [get_bd_pins hdmi_tx_dvi/SerialClk]
  connect_bd_net $tx_locked [get_bd_pins hdmi_tx_dvi/aRst_n]
  foreach {a b} {vid_data vid_pData vid_de vid_pVDE vid_hs vid_pHSync vid_vs vid_pVSync} {
    connect_bd_net [get_bd_pins mister/$a] [get_bd_pins hdmi_tx_dvi/$b]
  }
  create_bd_intf_port -mode Master -vlnv digilentinc.com:interface:tmds_rtl:1.0 hdmi_out
  connect_bd_intf_net [get_bd_intf_pins hdmi_tx_dvi/TMDS] [get_bd_intf_ports hdmi_out]
} else {
  set tx [create_bd_cell -type module -reference hdmi_out hdmi_tx_hdmi]
  # direct video is no CEA mode: AVI InfoFrame without a video code
  if {$dv} { set_property CONFIG.G_VIC 0 $tx }
  connect_bd_net $tx_pix [get_bd_pins hdmi_tx_hdmi/clk_pix]
  connect_bd_net $tx_ser [get_bd_pins hdmi_tx_hdmi/clk_ser]
  connect_bd_net $tx_locked [get_bd_pins hdmi_tx_hdmi/locked]
  foreach p {vid_data vid_de vid_hs vid_vs i2s_bclk i2s_lrclk i2s_data} {
    connect_bd_net [get_bd_pins mister/$p] [get_bd_pins hdmi_tx_hdmi/$p]
  }
  foreach {port pin w} {hdmi_out_clk_p tx_clk_p 1 hdmi_out_clk_n tx_clk_n 1 hdmi_out_data_p tx_data_p 3 hdmi_out_data_n tx_data_n 3} {
    if {$w == 1} { create_bd_port -dir O $port } else { create_bd_port -dir O -from [expr {$w - 1}] -to 0 $port }
    connect_bd_net [get_bd_pins hdmi_tx_hdmi/$pin] [get_bd_ports $port]
  }
}

#---- audio: I2S to the codec (with hdmi also to hdmi_out), mute off (ac_muten active low)
# TODO the codec of the board (pins, mute, MCLK); its register setup is a rootfs file (platform.mk MISTER_ROOTFS_FILES)
foreach {port pin} {ac_mclk i2s_mclk ac_bclk i2s_bclk ac_pblrc i2s_lrclk ac_pbdat i2s_data} {
  create_bd_port -dir O $port
  connect_bd_net [get_bd_pins mister/$pin] [get_bd_ports $port]
}
set one [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 one]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $one
create_bd_port -dir O ac_muten
connect_bd_net [get_bd_pins one/dout] [get_bd_ports ac_muten]

#---- board: buttons (0 OSD, 1 user), SW of the DE10-Nano off (SW[3] would select the
#     IO board's buttons), LEDs: DE10-Nano LED 0 user, 2 disk, 4 power, stage C error
# TODO buttons and LEDs of the board (none: tie btn_osd/btn_user to 0, leave led open)
create_bd_port -dir I -from 1 -to 0 btn
foreach {i pin} {0 btn_osd 1 btn_user} {
  set s [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 btn_$i]
  set_property -dict [list CONFIG.DIN_WIDTH {2} CONFIG.DIN_FROM $i CONFIG.DIN_TO $i] $s
  connect_bd_net [get_bd_ports btn] [get_bd_pins btn_$i/Din]
  connect_bd_net [get_bd_pins btn_$i/Dout] [get_bd_pins mister/$pin]
}
set sw0 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 sw_off]
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] $sw0
connect_bd_net [get_bd_pins sw_off/dout] [get_bd_pins mister/sw]

set leds [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 led_concat]
set_property CONFIG.NUM_PORTS {4} $leds
foreach {i bit} {0 0 1 2 2 4} {
  set s [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 led_$i]
  set_property -dict [list CONFIG.DIN_WIDTH {8} CONFIG.DIN_FROM $bit CONFIG.DIN_TO $bit] $s
  connect_bd_net [get_bd_pins mister/led] [get_bd_pins led_$i/Din]
  connect_bd_net [get_bd_pins led_$i/Dout] [get_bd_pins led_concat/In$i]
}
connect_bd_net [get_bd_pins mister/status_err] [get_bd_pins led_concat/In3]
create_bd_port -dir O -from 3 -to 0 led
connect_bd_net [get_bd_pins led_concat/dout] [get_bd_ports led]

#---- address map
# CONTRACT: hps_bus_axi at 0x4000_0000 (Main_MiSTer patch 0002), HP0/HP1 (HP2, HP3) see the DDR at its physical
# addresses (SDRAM image G_SDRAM_BASE 0x3800_0000, ascal 0x2000_0000, DDRAM_* of the core from
# 0x3000_0000), reserved in the device tree
# TODO ZynqMP: other segment names; M_AXI_HPM0 windows start at 0x8000_0000 (LPD) / 0xA000_0000 (FPD), not
#      0x4000_0000: Main_MiSTer patch 0002 needs the base as an option (open)
assign_bd_address -offset 0x40000000 -range 0x1000 \
  -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
  [get_bd_addr_segs mister/s_axi/reg0] -force
set hps {mister/m_axi_sdram HP0 mister/m_axi_vbuf HP1}
if {$ddram} { lappend hps mister/m_axi_ddram HP2 }
if {$coremem} { lappend hps mister/m_axi_coremem HP3 }
foreach {space hp} $hps {
  assign_bd_address -offset 0x00000000 -range 0x40000000 -target_address_space [get_bd_addr_spaces $space] \
    [get_bd_addr_segs processing_system7_0/S_AXI_$hp/${hp}_DDR_LOWOCM] -force
}

validate_bd_design
save_bd_design
make_wrapper -files [get_files design_1.bd] -top
add_files -norecurse [file normalize ./$proj_name/$proj_name.gen/sources_1/bd/design_1/hdl/design_1_wrapper.vhd]
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1

# report the clocks the wizards made (100 MHz * M / D / O; the core clocks depend on them)
foreach {w n} {clk_core 4 clk_hdmi 2} {
  set c [get_bd_cells $w]
  set vco [expr {100.0 * [get_property CONFIG.MMCM_CLKFBOUT_MULT_F $c] / [get_property CONFIG.MMCM_DIVCLK_DIVIDE $c]}]
  for {set i 0} {$i < $n} {incr i} {
    set o [get_property CONFIG.MMCM_CLKOUT${i}_DIVIDE[expr {$i == 0 ? "_F" : ""}] $c]
    puts [format "INFO: %s clk_out%d %.4f MHz (requested %s)" $w [expr {$i + 1}] [expr {$vco / $o}] \
      [get_property CONFIG.CLKOUT[expr {$i + 1}]_REQUESTED_OUT_FREQ $c]]
  }
}
# clk_out4 (BUFGCE input core_buf) must have the edges of clk_out2 (logic driving its CE)
foreach p {DIVIDE PHASE DUTY_CYCLE} {
  if {[get_property CONFIG.MMCM_CLKOUT1_$p $cc] != [get_property CONFIG.MMCM_CLKOUT3_$p $cc]} {
    error "clk_core: clk_out4 differs from clk_out2 in $p"
  }
}
puts "project ./$proj_name/$proj_name.xpr created"
