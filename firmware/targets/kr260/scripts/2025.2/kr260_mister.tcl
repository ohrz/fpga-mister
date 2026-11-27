#-----------------------------------------------------------------------------
# Title      : KR260 MiSTer design of one core (kr260_<core>)
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-26
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   Vivado project of MiSTer (framework sys_top.v and a core) on the KR260
#   (Kria K26 SOM, Zynq UltraScale+ XCK26). Same structure as zcu106_mister.tcl:
#   the PL is the module reference mister_zynq (firmware/common/mister/hdl)
#   around sys_top_zynq, the core comes from its profile
#   (firmware/common/mister/cores/<core>/core.tcl), this script holds the board
#   part. The core comes as Tcl argument (FLOW=vivado passes it for CORE=<core>
#   or TOPLEVEL=kr260_<core>) or as the variable core_id of a sourcing script.
#
#     M_AXI_HPM0_FPD (128) -> SmartConnect -> mister/s_axi   hps_bus_axi at 0xA000_0000
#     mister/m_axi_sdram   (AXI3 64, master clock) -> SmartConnect -> S_AXI_HP0_FPD (128)
#     mister/m_axi_vbuf    (AXI3 64, 100 MHz)      -> SmartConnect -> S_AXI_HP1_FPD (128)
#     mister/m_axi_ddram   (G_DDRAM 1, ddram_clk)  -> SmartConnect -> S_AXI_HP2_FPD (128)
#     mister/m_axi_coremem (G_COREMEM 1)           -> SmartConnect -> S_AXI_HP3_FPD (128)
#     These are the default ports. LAB_HP_MAP_kr260 of the lab can give a master another port
#     (hp0..hp3, hpc0, hpc1). The SmartConnect of a master has the name sc_<port>.
#     mister/vid_* -> dp_live (kr260_dp_live) -> live video input of the PS DisplayPort
#     mister/i2s_* -> dp_audio (kr260_dp_audio, i2s_rx of hdmi-tx) -> live audio input of the PS DisplayPort
#
#   The KR260 has no HDMI output. The video goes into the live video input of
#   the DisplayPort of the PS (DPSUB, one lane). Linux sets the link and the
#   mode (1280x720@60). The live input then replaces the frame buffer of the
#   DPDMA (doc/ARCHITECTURE.md §4, firmware/targets/kr260/README.md). The PL
#   gives the pixel clock (dp_video_in_clk) and the timing (hsync, vsync, de).
#   Sound: the KR260 has no codec. kr260_dp_audio puts the I2S of mister_zynq
#   into the live audio input of the DisplayPort (dp_s_axis_audio_*, clock
#   clk_audio = 512 x 48 kHz). The driver ignores the live audio input, so
#   kr260_dp_live.py sets the audio registers (firmware/targets/kr260/README.md).
#   Its counters go to board_status bits 31:9, CTRL bits 7:3 select test modes.
#
#   PS-PL widths: every port at 128 bit, as on the ZCU106 (reset value of the
#   AFI registers). Check the AFI registers under the Kria boot firmware on the
#   board before the first load.
#
#   Clocks, frame variant (a core without MMCMs of its own: menu, MSX, SNES):
#   clk_25 (carrier oscillator) -> clk_base: 100 MHz (clk_100: AXI-Lite,
#   HP1, sysmem clock of sys_top) and 25 MHz (input of clk_pix); clk_core (MMCM
#   from 100 MHz as on the Zybo and the ZCU106, same dividers): 24.576 MHz
#   audio, master clock of the profile, 50 MHz, master without BUFG; clk_pix
#   (MMCM from 25 MHz, M 37.125, D 1, O 12.5) = 74.25 MHz for clk_hdmi and
#   dp_video_in_clk. No PS clock and no PS reset are used.
#   The XCK26 has four MMCMs in one column (clock regions X1Y0..X1Y3). clk_25
#   (pin C3, bank 66) is in X1Y3, so clk_base is MMCM_X0Y3. A BUFGCE of an MMCM
#   can drive an MMCM only in the clock region above or below it (rule_bufg_mmcm),
#   and only X1Y2 is next to X1Y3. kr260_mister.xdc puts clk_core there (direct
#   route) and clk_pix in X1Y1 with CLOCK_DEDICATED_ROUTE BACKBONE on its 25 MHz
#   input: the pixel clock is asynchronous to the other clocks. The 50 MHz of
#   clk_core is no source for clk_pix: its VCO follows the master clock of the
#   profile (50.405 MHz for menu).
#
#   Clocks, compact variant (a profile with core_swap_low_mmcm: PSX, N64). The
#   core has two MMCMs (pll, pll2_us), so the frame gets only two: no clk_base.
#   clk_25 goes directly to clk_pix (MMCM_X0Y3, No_buffer) and through the BUFG
#   of clk_core (Global_buffer) to clk_core (MMCM_X0Y2). clk_core: D 1, M 36,
#   VCO 900 MHz, CLKOUT0 / 36.625 = 24.573 MHz audio (-107 ppm), / 18 = 50 MHz
#   master clock and clk_50, / 9 = 100 MHz clk_100. The master clock must be
#   50 MHz and free running (G_FREE_CLK 1). clk_master_gate is clk_master. The
#   core MMCMs are MMCM_X0Y1 and MMCM_X0Y0 (kr260_mmcm_compact.xdc).
#   Both variants: the oscillator runs before the configuration, so the MMCMs
#   from the pin have no reset. clk_base (frame) and clk_core (compact) have
#   the safe clock startup (BUFGCE outputs enabled after lock).
#
#   Address map (M_AXI_HPM0_FPD): 0xA000_0000 hps_bus_axi (4 KB); the HP ports
#   see DDR_LOW (0x0000_0000-0x7FFF_FFFF) with the physical addresses of the
#   Zybo (doc/ARCHITECTURE.md §2).
#
#   Usage (from firmware/build/kr260/<ver>/hw, PLATFORM=kr260 FLOW=vivado
#   CORE=<core> make create; checkouts from make setup):
#     vivado -mode batch -source kr260_mister.tcl -tclargs <platform> <core>
#-----------------------------------------------------------------------------

if {![info exists core_id] && [llength $argv] >= 2} { set core_id [lindex $argv 1] }
if {![info exists core_id]} { error "kr260_mister.tcl: no core (-tclargs <platform> <core>)" }
set proj_name  kr260_$core_id
set script_dir [file normalize [file dirname [info script]]]
set target_dir [file normalize [file join $script_dir .. ..]]
set root_dir   [file normalize [file join $target_dir .. .. ..]]

create_project $proj_name ./$proj_name -part xck26-sfvc784-2LV-c -force
set_property board_part_repo_paths [list [file join $target_dir board_files]] [current_project]
set_property board_part xilinx.com:kr260_som:part0:1.0 [current_project]
set_property board_connections {som240_2_connector xilinx.com:kr260_carrier:som240_2_connector:1.0 som240_1_connector xilinx.com:kr260_carrier:som240_1_connector:1.0} [current_project]
set_property target_language VHDL [current_project]

# core sources and constraints, then the board constraints (after the core's generated clocks)
source [file join $root_dir firmware common mister scripts mister_project.tcl]
# the XCK26 has 4 MMCMs: a profile with MMCMs of its own replaces files (core_swap_low_mmcm)
set core [mister_core_add $root_dir $core_id {low_mmcm 1}]
if {[mister_direct_video $core]} {
  error "kr260_mister.tcl: profile $core_id uses direct video (G_DIRECT_VIDEO); the KR260 output is fixed 720p (ascal)"
}
# clock variant: compact (no clk_base) if the profile replaced files for few MMCMs, else frame
set compact [dict get $core low_mmcm]
set master_mhz [format %.3f [dict get $core master_mhz]]
if {$compact && (![mister_free_clk $core] || $master_mhz != 50.0)} {
  error "kr260_mister.tcl: the compact clocks need G_FREE_CLK 1 and a 50 MHz master clock ($core_id: $master_mhz MHz)"
}
add_files -fileset constrs_1 -norecurse [file join $target_dir constraints kr260_mister.xdc]
add_files -fileset constrs_1 -norecurse [file join $target_dir constraints \
  [expr {$compact ? "kr260_mmcm_compact.xdc" : "kr260_mmcm_frame.xdc"}]]
# compact: the create_clock of clk_25 must come before the core XDC, which names the clocks of the core MMCMs
# (Constraints 18-851 and no clocks at all without it). In the frame variant the XDC of clk_base has it.
if {$compact} {
  set_property PROCESSING_ORDER EARLY [get_files kr260_mmcm_compact.xdc]
}
# cores with BUFGCEs behind the gated master clock: clock region of core_buf (kr260_core_buf.xdc).
# Menu and MSX meet the timing without it and keep their checked placement.
set core_buf_cores {snes}
if {$core_id in $core_buf_cores} {
  add_files -fileset constrs_1 -norecurse [file join $target_dir constraints kr260_core_buf.xdc]
}
# more constraints of this board unit, if the lab names them (LAB_EXTRA_XDC_<board>, lab.mk)
mister_extra_xdc
add_files -norecurse [glob [file join $target_dir hdl *.vhd]]
# I2S receiver of hdmi-tx (firmware/common/ip/hdmi-tx) for kr260_dp_audio
set i2s_rx [file join $root_dir firmware common ip hdmi-tx src i2s_rx.vhd]
if {![file isfile $i2s_rx]} {
  error "i2s_rx of hdmi-tx not found: $i2s_rx"
}
add_files -norecurse $i2s_rx
update_compile_order -fileset sources_1

create_bd_design design_1

#---- PS: board preset; HPM0_FPD and HP0..HP3 at 128 bit; live video input of the DisplayPort
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
set ddram [mister_ddram $core]
set coremem [mister_coremem $core]
# PS port of each memory master: HP0 to HP3 by default, LAB_HP_MAP_kr260 of the lab can change it
set hp_masters [list m_axi_sdram m_axi_vbuf]
if {$ddram}   { lappend hp_masters m_axi_ddram }
if {$coremem} { lappend hp_masters m_axi_coremem }
set hpn [mister_hp_map {m_axi_sdram hp0 m_axi_vbuf hp1 m_axi_ddram hp2 m_axi_coremem hp3} $hp_masters]
set gp_used {}
foreach m $hp_masters { lappend gp_used [dict get [mister_ps_port [dict get $hpn $m]] gp] }
# S_AXI_GP0/1 = HPC0/1, S_AXI_GP2..5 = HP0..3, each at 128 bit
set hp_cfg {}
foreach g {0 1 2 3 4 5} {
  lappend hp_cfg CONFIG.PSU__USE__S_AXI_GP$g [expr {$g in $gp_used ? 1 : 0}] CONFIG.PSU__SAXIGP${g}__DATA_WIDTH {128}
}
set_property -dict [concat [list CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__MAXIGP0__DATA_WIDTH {128} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} CONFIG.PSU__USE__M_AXI_GP2 {0}] $hp_cfg [list \
  CONFIG.PSU__USE__VIDEO {1} CONFIG.PSU__USE__AUDIO {1} \
  CONFIG.PSU__TTC0__PERIPHERAL__ENABLE {1} CONFIG.PSU__TTC0__WAVEOUT__ENABLE {1} CONFIG.PSU__TTC0__WAVEOUT__IO {EMIO} \
  CONFIG.PSU__FPGA_PL1_ENABLE {0} CONFIG.PSU__FPGA_PL2_ENABLE {0} CONFIG.PSU__FPGA_PL3_ENABLE {0}]] $ps

#---- clocks (header: frame variant and compact variant)
create_bd_port -dir I -type clk -freq_hz 25000000 clk_25
if {!$compact} {
  # frame: carrier oscillator 25 MHz -> 100 / 25 MHz -> clk_core as on the Zybo; clk_pix 74.25 MHz
  #     clk_base with safe clock startup (BUFGCE outputs enabled after lock), as on the ZCU106
  set cb [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_base]
  set_property -dict [list CONFIG.PRIMITIVE {MMCM} CONFIG.PRIM_IN_FREQ {25.000} \
    CONFIG.PRIM_SOURCE {Single_ended_clock_capable_pin} CONFIG.NUM_OUT_CLKS {2} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {25.000} \
    CONFIG.USE_RESET {false} CONFIG.USE_LOCKED {true} CONFIG.USE_SAFE_CLOCK_STARTUP {true}] $cb
  connect_bd_net [get_bd_ports clk_25] [get_bd_pins clk_base/clk_in1]
  set clk0   [get_bd_pins clk_base/clk_out1]
  set clk_25 [get_bd_pins clk_base/clk_out2]

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

  # pixel clock: exact 74.25 MHz from 25 MHz (VCO 928.125 MHz); the wizard must find M 37.125, D 1, O 12.5
  set cp [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_pix]
  set_property -dict [list CONFIG.PRIMITIVE {MMCM} CONFIG.PRIM_IN_FREQ {25.000} CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.NUM_OUT_CLKS {1} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {74.250} \
    CONFIG.USE_RESET {true} CONFIG.RESET_TYPE {ACTIVE_LOW} CONFIG.USE_LOCKED {true}] $cp
  connect_bd_net $clk_25 [get_bd_pins clk_pix/clk_in1]
  connect_bd_net [get_bd_pins clk_base/locked] [get_bd_pins clk_pix/resetn]
  set audio_ns 40.690
  set wiz_report {clk_base 2 25.0 clk_core 4 100.0 clk_pix 1 25.0}
} else {
  # compact: clk_pix from the pin (IBUF of synthesis, dedicated route to MMCM_X0Y3)
  set cp [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_pix]
  set_property -dict [list CONFIG.PRIMITIVE {MMCM} CONFIG.PRIM_IN_FREQ {25.000} CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.NUM_OUT_CLKS {1} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {74.250} \
    CONFIG.USE_RESET {false} CONFIG.USE_LOCKED {true}] $cp
  connect_bd_net [get_bd_ports clk_25] [get_bd_pins clk_pix/clk_in1]
  # clk_core from the pin through its BUFG; M, D and O fixed (only CLKOUT0 divides fractionally)
  set cc [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_core]
  set_property -dict [list CONFIG.PRIMITIVE {MMCM} CONFIG.PRIM_IN_FREQ {25.000} CONFIG.PRIM_SOURCE {Global_buffer} \
    CONFIG.NUM_OUT_CLKS {4} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {24.576} \
    CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {50.000} \
    CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {50.000} \
    CONFIG.CLKOUT4_USED {true} CONFIG.CLKOUT4_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.USE_RESET {false} CONFIG.USE_LOCKED {true} CONFIG.USE_SAFE_CLOCK_STARTUP {true}] $cc
  set_property -dict [list CONFIG.OVERRIDE_MMCM {true} CONFIG.MMCM_DIVCLK_DIVIDE {1} CONFIG.MMCM_CLKFBOUT_MULT_F {36.000} \
    CONFIG.MMCM_CLKOUT0_DIVIDE_F {36.625} CONFIG.MMCM_CLKOUT1_DIVIDE {18} CONFIG.MMCM_CLKOUT2_DIVIDE {18} \
    CONFIG.MMCM_CLKOUT3_DIVIDE {9}] $cc
  connect_bd_net [get_bd_ports clk_25] [get_bd_pins clk_core/clk_in1]
  set clk_audio  [get_bd_pins clk_core/clk_out1]
  set clk_master [get_bd_pins clk_core/clk_out2]
  set clk_50     [get_bd_pins clk_core/clk_out3]
  set clk0       [get_bd_pins clk_core/clk_out4]
  # G_FREE_CLK 1: mister_zynq does not use clk_master_gate
  set clk_master_gate $clk_master
  set audio_ns [format %.3f [expr {1000.0 * 36.625 / 900.0}]]
  set wiz_report {clk_core 4 25.0 clk_pix 1 25.0}
}
set clk_hdmi [get_bd_pins clk_pix/clk_out1]

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
connect_bd_net $clk_hdmi   [get_bd_pins mister/clk_hdmi]

#---- video: mister/vid_* -> kr260_dp_live -> live video input of the DisplayPort (PS)
#     TODO(kr260): G_ORDER of kr260_dp_live after the color bar test on the board
set dl [create_bd_cell -type module -reference kr260_dp_live dp_live]
connect_bd_net $clk_hdmi [get_bd_pins dp_live/clk_pix] [get_bd_pins zynq_ultra_ps_e_0/dp_video_in_clk]
foreach p {vid_data vid_de vid_hs vid_vs} {
  connect_bd_net [get_bd_pins mister/$p] [get_bd_pins dp_live/$p]
}
foreach {pin psp} {dp_pixel dp_live_video_in_pixel1 dp_de dp_live_video_in_de \
    dp_hs dp_live_video_in_hsync dp_vs dp_live_video_in_vsync} {
  connect_bd_net [get_bd_pins dp_live/$pin] [get_bd_pins zynq_ultra_ps_e_0/$psp]
}

#---- sound: mister/i2s_* -> kr260_dp_audio -> live audio input of the DisplayPort (PS), all in clk_audio
set da [create_bd_cell -type module -reference kr260_dp_audio dp_audio]
connect_bd_net $clk_audio [get_bd_pins dp_audio/clk] [get_bd_pins zynq_ultra_ps_e_0/dp_s_axis_audio_clk]
foreach {pin mp} {i2s_bclk i2s_bclk i2s_lrclk i2s_lrclk i2s_data i2s_data ctrl board_ctrl} {
  connect_bd_net [get_bd_pins mister/$mp] [get_bd_pins dp_audio/$pin]
}
foreach {pin psp} {m_tdata dp_s_axis_audio_tdata m_tid dp_s_axis_audio_tid m_tvalid dp_s_axis_audio_tvalid \
    m_tready dp_s_axis_audio_tready} {
  connect_bd_net [get_bd_pins dp_audio/$pin] [get_bd_pins zynq_ultra_ps_e_0/$psp]
}
# the mixed audio output of the DPSUB is not used: it must not stall the mixer
set one1 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 one1]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $one1
connect_bd_net [get_bd_pins one1/dout] [get_bd_pins zynq_ultra_ps_e_0/dp_m_axis_mixed_audio_tready]

#---- AXI-Lite: HPM0_FPD -> hps_bus_axi
set axil [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axil]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $axil
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] [get_bd_intf_pins axil/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axil/M00_AXI] [get_bd_intf_pins mister/s_axi]
connect_bd_net $clk0 [get_bd_pins axil/aclk] [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk]
connect_bd_net $rst0 [get_bd_pins axil/aresetn]

#---- memory ports: AXI3 64 bit of mister_zynq -> SmartConnect (width and protocol) -> HP at 128 bit
#     HP2/HP3 get the reset of mister_zynq on their clock, as on the ZCU106
set hps [list m_axi_sdram [dict get $hpn m_axi_sdram] $clk_master $rst0 m_axi_vbuf [dict get $hpn m_axi_vbuf] $clk0 $rst0]
if {$ddram}   { lappend hps m_axi_ddram [dict get $hpn m_axi_ddram] [get_bd_pins mister/ddram_clk] [get_bd_pins mister/ddram_aresetn] }
if {$coremem} { lappend hps m_axi_coremem [dict get $hpn m_axi_coremem] [get_bd_pins mister/coremem_clk] [get_bd_pins mister/coremem_aresetn] }
foreach {m p clk rst} $hps {
  set pp [mister_ps_port $p]
  set sc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_$p]
  set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc
  connect_bd_intf_net [get_bd_intf_pins mister/$m] [get_bd_intf_pins sc_$p/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins sc_$p/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/[dict get $pp intf]]
  connect_bd_net $clk [get_bd_pins sc_$p/aclk] [get_bd_pins zynq_ultra_ps_e_0/[dict get $pp clk]]
  connect_bd_net $rst [get_bd_pins sc_$p/aresetn]
}

#---- board: no PL buttons and no PL LEDs on the carrier. OSD with the keyboard (F12), SW of the
#     DE10-Nano off. The LEDs of the DE10-Nano and the stage C error go to board_status (aux word 17,
#     0xA000_0054): bits 7:0 LED, bit 8 status_err, bits 31:9 the counters of kr260_dp_audio
#     (31:16 frames sent, 15:9 frames dropped).
#     LED bit 6 (led_locked of pll_hdmi_adj) reads as 0: it was the only sink of pll_hdmi_adj, whose
#     clock goes through a LUT (TIMING-14). Without the sink, synthesis removes pll_hdmi_adj, as on
#     the ZCU106. The KR260 has no HDMI PLL that pll_hdmi_adj could tune.
set btn0 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 btn_off]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $btn0
connect_bd_net [get_bd_pins btn_off/dout] [get_bd_pins mister/btn_osd] [get_bd_pins mister/btn_user]
set sw0 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 sw_off]
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] $sw0
connect_bd_net [get_bd_pins sw_off/dout] [get_bd_pins mister/sw]

set zero1 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 zero1]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $zero1
foreach {name from to} {led_lo 5 0 led_7 7 7} {
  set sl [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 $name]
  set_property -dict [list CONFIG.DIN_WIDTH {8} CONFIG.DIN_FROM $from CONFIG.DIN_TO $to] $sl
  connect_bd_net [get_bd_pins mister/led] [get_bd_pins $name/Din]
}
set bs [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 board_status]
set_property -dict [list CONFIG.NUM_PORTS {5} CONFIG.IN0_WIDTH {6} CONFIG.IN1_WIDTH {1} CONFIG.IN2_WIDTH {1} \
  CONFIG.IN3_WIDTH {1} CONFIG.IN4_WIDTH {23}] $bs
connect_bd_net [get_bd_pins led_lo/Dout] [get_bd_pins board_status/In0]
connect_bd_net [get_bd_pins zero1/dout] [get_bd_pins board_status/In1]
connect_bd_net [get_bd_pins led_7/Dout] [get_bd_pins board_status/In2]
connect_bd_net [get_bd_pins mister/status_err] [get_bd_pins board_status/In3]
connect_bd_net [get_bd_pins dp_audio/status] [get_bd_pins board_status/In4]
connect_bd_net [get_bd_pins board_status/dout] [get_bd_pins mister/board_status]

#---- carrier fan: PWM of PS TTC0 channel 2 (EMIO) directly to FAN_EN (low-active, low = full speed).
#     The pwm-fan node of the kernel DTB (zynqmp-sm-k26-revA.dts: &ttc0 2 40000, PWM_POLARITY_INVERTED)
#     already inverts, so the duty of pwm-fan is the fan speed. pwm-fan starts at full speed.
create_bd_port -dir O fan_en_b
set fs [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 fan_ttc2]
set_property -dict [list CONFIG.DIN_WIDTH {3} CONFIG.DIN_FROM {2} CONFIG.DIN_TO {2}] $fs
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/emio_ttc0_wave_o] [get_bd_pins fan_ttc2/Din]
connect_bd_net [get_bd_pins fan_ttc2/Dout] [get_bd_ports fan_en_b]

#---- address map
assign_bd_address -offset 0xA0000000 -range 0x1000 \
  -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
  [get_bd_addr_segs mister/s_axi/reg0] -force
foreach {m p clk rst} $hps {
  assign_bd_address -offset 0x00000000 -range 0x80000000 -target_address_space [get_bd_addr_spaces mister/$m] \
    [get_bd_addr_segs zynq_ultra_ps_e_0/[dict get [mister_ps_port $p] seg]] -force
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
  clk_hdmi 13.468 clk_audio $audio_ns]

# report the clocks the wizards made (input * M / D / O; the core clocks depend on them)
foreach {w n fin} $wiz_report {
  set c [get_bd_cells $w]
  set vco [expr {$fin * [get_property CONFIG.MMCM_CLKFBOUT_MULT_F $c] / [get_property CONFIG.MMCM_DIVCLK_DIVIDE $c]}]
  for {set i 0} {$i < $n} {incr i} {
    set o [get_property CONFIG.MMCM_CLKOUT${i}_DIVIDE[expr {$i == 0 ? "_F" : ""}] $c]
    puts [format "INFO: %s clk_out%d %.4f MHz (requested %s)" $w [expr {$i + 1}] [expr {$vco / $o}] \
      [get_property CONFIG.CLKOUT[expr {$i + 1}]_REQUESTED_OUT_FREQ $c]]
  }
}
if {!$compact} {
  # clk_out4 (BUFGCE input core_buf) must have the edges of clk_out2 (logic driving its CE)
  foreach p {DIVIDE PHASE DUTY_CYCLE} {
    if {[get_property CONFIG.MMCM_CLKOUT1_$p $cc] != [get_property CONFIG.MMCM_CLKOUT3_$p $cc]} {
      error "clk_core: clk_out4 differs from clk_out2 in $p"
    }
  }
} else {
  # compact: the values of the header (the wizard must keep M, D and O of OVERRIDE_MMCM)
  set vco [expr {25.0 * [get_property CONFIG.MMCM_CLKFBOUT_MULT_F $cc] / [get_property CONFIG.MMCM_DIVCLK_DIVIDE $cc]}]
  foreach {i want tol} {0 24.576 0.000110 1 50.0 0.0 2 50.0 0.0 3 100.0 0.0} {
    set o [get_property CONFIG.MMCM_CLKOUT${i}_DIVIDE[expr {$i == 0 ? "_F" : ""}] $cc]
    set f [expr {$vco / $o}]
    if {abs($f / $want - 1.0) > $tol + 1e-9} {
      error "clk_core: clk_out[expr {$i + 1}] [format %.5f $f] MHz instead of $want MHz"
    }
  }
}
# the DisplayPort mode of Linux is 74.25 MHz: a different pixel clock gives a different refresh rate
set vco [expr {25.0 * [get_property CONFIG.MMCM_CLKFBOUT_MULT_F $cp] / [get_property CONFIG.MMCM_DIVCLK_DIVIDE $cp]}]
set fpix [expr {$vco / [get_property CONFIG.MMCM_CLKOUT0_DIVIDE_F $cp]}]
if {abs($fpix - 74.25) > 0.0001} { error "clk_pix: [format %.5f $fpix] MHz instead of 74.25 MHz" }
# routes of a checked build of this board unit, if the lab names one (LAB_INC_DCP_<design>, LAB_PRE_PLACE_TCL_<board>,
# lab.mk)
mister_lab_incremental
mister_lab_pre_place
puts "project ./$proj_name/$proj_name.xpr created"
