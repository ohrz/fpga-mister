#-----------------------------------------------------------------------------
# Title      : ZCU106 MiSTer design of one core (zcu106_<core>)
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-07
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   Vivado project of MiSTer (framework sys_top.v and a core) on the ZCU106
#   (Zynq UltraScale+ XCZU7EV).  Same structure as zybo-z7-20_mister.tcl: the PL
#   is the module reference mister_zynq (firmware/common/mister/hdl) around
#   sys_top_zynq, the core comes from its profile
#   (firmware/common/mister/cores/<core>/core.tcl), this script holds the board
#   part.  The core comes as Tcl argument (FLOW=vivado passes it for CORE=<core>
#   or TOPLEVEL=zcu106_<core>) or as the variable core_id of a sourcing script.
#
#     M_AXI_HPM0_FPD (128) -> SmartConnect -> mister/s_axi   hps_bus_axi at 0xA000_0000
#     mister/m_axi_sdram   (AXI3 64, master clock) -> SmartConnect -> S_AXI_HP0_FPD (128)
#     mister/m_axi_vbuf    (AXI3 64, 100 MHz)      -> SmartConnect -> S_AXI_HP1_FPD (128)
#     mister/m_axi_ddram   (G_DDRAM 1, ddram_clk)  -> SmartConnect -> S_AXI_HP2_FPD (128)
#     mister/m_axi_coremem (G_COREMEM 1)           -> SmartConnect -> S_AXI_HP3_FPD (128)
#     mister/vid_*, i2s_* -> hdmi (zcu106_hdmi): TMDS over GTH quad 223, sound in data islands
#
#   PS-PL widths: every port at 128 bit, the reset value of the AFI registers
#   (afi_fs 0xA00, RDCTRL/WRCTRL 0x3B0, read on the board 2026-11-07): the
#   designs are loaded at runtime by the fpga_manager under any FSBL, also the
#   one of the board's original SD card, without writing PS registers.
#
#   Clocks: CLK_125 (board oscillator) -> clk_base: 100 MHz (clk_100: AXI-Lite,
#   HP1, sysmem clock of sys_top, I2C) and 25 MHz (free-running clock of the
#   transceiver); clk_core (MMCM from 100 MHz as on the Zybo, same dividers):
#   24.576 MHz audio, master clock of the profile, 50 MHz, master without BUFG;
#   clk_hdmi = clk_pix of zcu106_hdmi (Si5324 148.5 MHz / 2 = 74.25 MHz, fixed
#   1280x720@60).  No PS clock and no PS reset are used (pl_clk0 and pl_resetn0
#   depend on the FSBL and on Linux).
#
#   Address map (M_AXI_HPM0_FPD): 0xA000_0000 hps_bus_axi (4 KB); the HP ports
#   see DDR_LOW (0x0000_0000-0x7FFF_FFFF) with the physical addresses of the
#   Zybo (doc/ARCHITECTURE.md §2).
#
#   Usage (from firmware/build/zcu106/<ver>/hw, PLATFORM=zcu106 FLOW=vivado
#   CORE=<core> make create; checkouts from make setup):
#     vivado -mode batch -source zcu106_mister.tcl -tclargs <platform> <core>
#-----------------------------------------------------------------------------

if {![info exists core_id] && [llength $argv] >= 2} { set core_id [lindex $argv 1] }
if {![info exists core_id]} { error "zcu106_mister.tcl: no core (-tclargs <platform> <core>)" }
set proj_name  zcu106_$core_id
set script_dir [file normalize [file dirname [info script]]]
set target_dir [file normalize [file join $script_dir .. ..]]
set root_dir   [file normalize [file join $target_dir .. .. ..]]
set hdmi_tx_src [file join $root_dir firmware common ip hdmi-tx src]
if {![file isfile [file join $hdmi_tx_src hdmi_tx.vhd]]} {
  error "hdmi-tx not found: $hdmi_tx_src"
}

create_project $proj_name ./$proj_name -part xczu7ev-ffvc1156-2-e -force
set_property board_part_repo_paths [list [file join $target_dir board_files]] [current_project]
set_property board_part xilinx.com:zcu106:part0:2.6 [current_project]
set_property target_language VHDL [current_project]

# core sources and constraints, then the board constraints (after the core's generated clocks)
source [file join $root_dir firmware common mister scripts mister_project.tcl]
set core [mister_core_add $root_dir $core_id]
if {[mister_direct_video $core]} {
  error "zcu106_mister.tcl: profile $core_id uses direct video (G_DIRECT_VIDEO); the ZCU106 output is fixed 720p (ascal)"
}
add_files -fileset constrs_1 -norecurse [file join $target_dir constraints zcu106_mister.xdc]
# placement of the gated master clock and the core clocks behind it: only where they exist
if {![mister_free_clk $core]} {
  add_files -fileset constrs_1 -norecurse [file join $target_dir constraints zcu106_core_buf.xdc]
}
# more constraints of this board unit, if the lab names them (LAB_EXTRA_XDC_<board>, lab.mk)
mister_extra_xdc
# HDMI: symbol generator of hdmi-tx (without its 7-series serializer hdmi_out) and the board block
foreach f [glob [file join $hdmi_tx_src *.vhd]] {
  if {[file tail $f] ne "hdmi_out.vhd"} { add_files -norecurse $f }
}
add_files -norecurse [glob [file join $target_dir hdl *.vhd]]

# transceiver of the HDMI output: three channels of quad 223 (X0Y0..X0Y2 = HDMI_TX0..2), CPLL from
# the Si5324 (148.5 MHz), 0.7425 Gb/s, raw 20 bit; the wizard does not offer TX only, RX stays idle
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name zcu106_gth_tx
set_property -dict [list CONFIG.GT_DIRECTION BOTH CONFIG.CHANNEL_ENABLE {X0Y2 X0Y1 X0Y0} \
  CONFIG.TX_MASTER_CHANNEL X0Y0 CONFIG.RX_MASTER_CHANNEL X0Y0 \
  CONFIG.TX_LINE_RATE 0.7425 CONFIG.TX_PLL_TYPE CPLL CONFIG.TX_REFCLK_FREQUENCY 148.5 \
  CONFIG.TX_DATA_ENCODING RAW CONFIG.TX_USER_DATA_WIDTH 20 CONFIG.TX_INT_DATA_WIDTH 20 CONFIG.TX_BUFFER_MODE 1 \
  CONFIG.TX_OUTCLK_SOURCE TXOUTCLKPMA \
  CONFIG.RX_LINE_RATE 0.7425 CONFIG.RX_PLL_TYPE CPLL CONFIG.RX_REFCLK_FREQUENCY 148.5 \
  CONFIG.RX_DATA_DECODING RAW CONFIG.RX_USER_DATA_WIDTH 20 CONFIG.RX_INT_DATA_WIDTH 20 \
  CONFIG.FREERUN_FREQUENCY 25 CONFIG.LOCATE_TX_USER_CLOCKING CORE CONFIG.LOCATE_RX_USER_CLOCKING CORE \
  CONFIG.LOCATE_RESET_CONTROLLER CORE CONFIG.LOCATE_COMMON CORE \
  CONFIG.ENABLE_OPTIONAL_PORTS {txpolarity_in}] [get_ips zcu106_gth_tx]
generate_target all [get_ips zcu106_gth_tx]
update_compile_order -fileset sources_1

create_bd_design design_1

#---- PS: board preset; HPM0_FPD and HP0..HP3 at 128 bit (reset value of the AFI registers)
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
set ddram [mister_ddram $core]
set coremem [mister_coremem $core]
set_property -dict [list CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__MAXIGP0__DATA_WIDTH {128} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
  CONFIG.PSU__USE__S_AXI_GP3 {1} CONFIG.PSU__SAXIGP3__DATA_WIDTH {128} \
  CONFIG.PSU__USE__S_AXI_GP4 [expr {$ddram ? 1 : 0}] CONFIG.PSU__SAXIGP4__DATA_WIDTH {128} \
  CONFIG.PSU__USE__S_AXI_GP5 [expr {$coremem ? 1 : 0}] CONFIG.PSU__SAXIGP5__DATA_WIDTH {128} \
  CONFIG.PSU__FPGA_PL1_ENABLE {0} CONFIG.PSU__FPGA_PL2_ENABLE {0} CONFIG.PSU__FPGA_PL3_ENABLE {0}] $ps

#---- clocks: board oscillator 125 MHz -> 100 / 25 MHz -> clk_core as on the Zybo
#     clk_base with safe clock startup (BUFGCE outputs enabled after lock): clk_100 drives HPM0
#     and HP1 through SmartConnects and restarts at every configuration of the PL; runt pulses
#     before the lock must not reach the AFI. clk_core cannot have it: its CLKOUT4
#     (clk_master_gate) must stay unbuffered for core_clock_stall (the wizard then allows BUFGCE
#     only); its input clk_100 now starts clean
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 clk_125
set_property CONFIG.FREQ_HZ 125000000 [get_bd_intf_ports clk_125]
set cb [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_base]
set_property -dict [list CONFIG.PRIMITIVE {MMCM} CONFIG.PRIM_IN_FREQ {125.000} \
  CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} CONFIG.NUM_OUT_CLKS {2} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {25.000} \
  CONFIG.USE_RESET {false} CONFIG.USE_LOCKED {true} CONFIG.USE_SAFE_CLOCK_STARTUP {true}] $cb
connect_bd_intf_net [get_bd_intf_ports clk_125] [get_bd_intf_pins clk_base/CLK_IN1_D]
set clk0     [get_bd_pins clk_base/clk_out1]
set clk_free [get_bd_pins clk_base/clk_out2]

set master_mhz [format %.3f [dict get $core master_mhz]]
set cc [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_core]
set_property -dict [list CONFIG.PRIMITIVE {MMCM} CONFIG.PRIM_IN_FREQ {100.000} CONFIG.PRIM_SOURCE {No_buffer} \
  CONFIG.NUM_OUT_CLKS {4} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {24.576} \
  CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ $master_mhz \
  CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {50.000} \
  CONFIG.CLKOUT4_USED {true} CONFIG.CLKOUT4_REQUESTED_OUT_FREQ $master_mhz CONFIG.CLKOUT4_DRIVES {No_buffer} \
  CONFIG.USE_RESET {true} CONFIG.RESET_TYPE {ACTIVE_LOW} CONFIG.USE_LOCKED {true}] $cc
connect_bd_net $clk0 [get_bd_pins clk_core/clk_in1]
connect_bd_net [get_bd_pins clk_base/locked] [get_bd_pins clk_core/resetn]
set clk_audio  [get_bd_pins clk_core/clk_out1]
set clk_master [get_bd_pins clk_core/clk_out2]
set clk_50     [get_bd_pins clk_core/clk_out3]
set clk_master_gate [get_bd_pins clk_core/clk_out4]

# one reset for the PL (100 MHz domain) after configuration and lock; no PS reset
set one [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 one]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $one
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_axi
connect_bd_net $clk0 [get_bd_pins rst_axi/slowest_sync_clk]
connect_bd_net [get_bd_pins one/dout] [get_bd_pins rst_axi/ext_reset_in]
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

#---- HDMI output (zcu106_hdmi): pixel clock from the Si5324 reference
set hd [create_bd_cell -type module -reference zcu106_hdmi hdmi]
connect_bd_net $clk0 [get_bd_pins hdmi/clk_100]
connect_bd_net $clk_free [get_bd_pins hdmi/clk_free]
connect_bd_net [get_bd_pins rst_axi/peripheral_reset] [get_bd_pins hdmi/rst_100]
# HDMI init state readable by Main_MiSTer's register window (aux word 17, 0xA000_0054)
connect_bd_net [get_bd_pins hdmi/dbg] [get_bd_pins mister/board_status]
connect_bd_net [get_bd_pins hdmi/clk_pix] [get_bd_pins mister/clk_hdmi]
foreach p {vid_data vid_de vid_hs vid_vs i2s_bclk i2s_lrclk i2s_data} {
  connect_bd_net [get_bd_pins mister/$p] [get_bd_pins hdmi/$p]
}
foreach {port pin dir w} {hdmi_refclk_p gt_refclk_p I 1 hdmi_refclk_n gt_refclk_n I 1 \
    hdmi_rx_p gt_rx_p I 3 hdmi_rx_n gt_rx_n I 3 hdmi_tx_p gt_tx_p O 3 hdmi_tx_n gt_tx_n O 3 \
    hdmi_tx_clk_p tx_lvds_p O 1 hdmi_tx_clk_n tx_lvds_n O 1 hdmi_ctl_scl ctl_scl IO 1 hdmi_ctl_sda ctl_sda IO 1 \
    hdmi_si5324_rst_n si5324_rst_n O 1 hdmi_si5324_lol si5324_lol I 1 hdmi_tx_en tx_en O 1} {
  if {$w == 1} { create_bd_port -dir $dir $port } else { create_bd_port -dir $dir -from [expr {$w - 1}] -to 0 $port }
  connect_bd_net [get_bd_pins hdmi/$pin] [get_bd_ports $port]
}

#---- AXI-Lite: HPM0_FPD -> hps_bus_axi
set axil [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axil]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $axil
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] [get_bd_intf_pins axil/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axil/M00_AXI] [get_bd_intf_pins mister/s_axi]
connect_bd_net $clk0 [get_bd_pins axil/aclk] [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk]
connect_bd_net $rst0 [get_bd_pins axil/aresetn]

#---- memory ports: AXI3 64 bit of mister_zynq -> SmartConnect (width and protocol) -> HP at 128 bit
#     HP2/HP3 run on clocks of the core's MMCM, which start long after rst0 ended: their SmartConnects
#     get the reset of mister_zynq on that clock (32 running cycles, axi_reset_sync)
set hps [list m_axi_sdram 0 $clk_master $rst0 m_axi_vbuf 1 $clk0 $rst0]
if {$ddram}   { lappend hps m_axi_ddram 2 [get_bd_pins mister/ddram_clk] [get_bd_pins mister/ddram_aresetn] }
if {$coremem} { lappend hps m_axi_coremem 3 [get_bd_pins mister/coremem_clk] [get_bd_pins mister/coremem_aresetn] }
foreach {m n clk rst} $hps {
  set sc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_hp$n]
  set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc
  connect_bd_intf_net [get_bd_intf_pins mister/$m] [get_bd_intf_pins sc_hp$n/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins sc_hp$n/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP${n}_FPD]
  connect_bd_net $clk [get_bd_pins sc_hp$n/aclk] [get_bd_pins zynq_ultra_ps_e_0/saxihp${n}_fpd_aclk]
  connect_bd_net $rst [get_bd_pins sc_hp$n/aresetn]
}

#---- board: buttons (0 OSD, 1 user), SW of the DE10-Nano off; LEDs: DE10-Nano LED 0 user,
#     2 disk, 4 power, stage C error, HDMI status (I2C done, I2C error, GT up, FIFO running)
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
set_property CONFIG.NUM_PORTS {8} $leds
foreach {i src bit w} {0 mister/led 0 8 1 mister/led 2 8 2 mister/led 4 8 4 hdmi/status 0 6 5 hdmi/status 1 6 6 hdmi/status 2 6 7 hdmi/status 4 6} {
  set s [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 led_$i]
  set_property -dict [list CONFIG.DIN_WIDTH $w CONFIG.DIN_FROM $bit CONFIG.DIN_TO $bit] $s
  connect_bd_net [get_bd_pins $src] [get_bd_pins led_$i/Din]
  connect_bd_net [get_bd_pins led_$i/Dout] [get_bd_pins led_concat/In$i]
}
connect_bd_net [get_bd_pins mister/status_err] [get_bd_pins led_concat/In3]
create_bd_port -dir O -from 7 -to 0 led
connect_bd_net [get_bd_pins led_concat/dout] [get_bd_ports led]

#---- address map
assign_bd_address -offset 0xA0000000 -range 0x1000 \
  -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
  [get_bd_addr_segs mister/s_axi/reg0] -force
foreach {m n clk rst} $hps {
  assign_bd_address -offset 0x00000000 -range 0x80000000 -target_address_space [get_bd_addr_spaces mister/$m] \
    [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP[expr {$n + 2}]/HP${n}_DDR_LOW] -force
}

validate_bd_design
save_bd_design
make_wrapper -files [get_files design_1.bd] -top
add_files -norecurse [file normalize ./$proj_name/$proj_name.gen/sources_1/bd/design_1/hdl/design_1_wrapper.vhd]
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1
# run settings of the core profile (out-of-context synthesis with clocks, options, impl_1)
mister_runs $core design_1.bd [file normalize ./$proj_name] [list clk_100 10.000 clk_50 20.000 \
  clk_master [format %.3f [expr {1000.0 / $master_mhz}]] clk_master_gate [format %.3f [expr {1000.0 / $master_mhz}]] \
  clk_hdmi 13.468 clk_audio 40.690]

# report the clocks the wizards made (input * M / D / O; the core clocks depend on them)
foreach {w n fin} {clk_base 2 125.0 clk_core 4 100.0} {
  set c [get_bd_cells $w]
  set vco [expr {$fin * [get_property CONFIG.MMCM_CLKFBOUT_MULT_F $c] / [get_property CONFIG.MMCM_DIVCLK_DIVIDE $c]}]
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
