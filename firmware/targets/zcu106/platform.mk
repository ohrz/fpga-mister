#-----------------------------------------------------------------------------
# File       : platform.mk
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-07
# Platform   : ZCU106 (Zynq UltraScale+ ZU7EV)
#-----------------------------------------------------------------------------
# Description:
# Board profile of zcu106, included by Makefiles/common.mk for every flow.
# The MiSTer designs (scripts/2025.2/zcu106_mister.tcl) are loaded at runtime by
# Main_MiSTer through the fpga_manager. The board boots its own SD card up to
# U-Boot; kernel (FLOW=kernel) and NFS root come over the network (FLOW=boot
# tftpboot), the card is never written. HDMI is the only video output
# (TMDS over GTH, fixed 720p), so there is no VIDEO_TX choice.
#-----------------------------------------------------------------------------

PLATFORM_FLOWS			:= vivado kernel boot mister
# zynq | zynqmp: bootgen architecture (.bit.bin)
PLATFORM_ARCH			:= zynqmp
# checkouts of FLOW=vivado make setup: MiSTer sources (hdmi_tx and i2s_rx are in firmware/common/ip/hdmi-tx)
VIVADO_SETUP_CHECKOUTS	:= Template_MiSTer MSX_MiSTer Menu_MiSTer SNES_MiSTer PSX_MiSTer N64_MiSTer

# kernel (FLOW=kernel): linux-xlnx with the board DTS of the ZCU106 plus the MiSTer nodes
# (reserved PL DDR, cma)
KERNEL_XILINX_DEVICE_TREE := zynqmp-zcu106-revA
KERNEL_DTB				:= zynqmp-zcu106-revA.dtb
KERNEL_DTS_FILES		:= dts/zynqmp-zcu106-revA.dts
KERNEL_PATCHES			:=

# boot (FLOW=boot): network boot only; FSBL, PMU firmware, ATF and U-Boot stay those of the
# board's own SD card (its BOOT.bin is not touched), copy builds a BOOT.bin from the
# prebuilt firmware
BOOT_FIRMWARE			:= soc-prebuilt
BOOT_SOC_PREBUILT_PATH	:= zcu106-zynqmp
BOOT_SOC_DTB_LEGACY		:= system.dtb
BOOT_SOC_DTB_SDT		:= cortexa53-linux.dtb
BOOT_SYSTEM_DTB			:=
BOOT_SYSTEM_DTB_SRC		:=
BOOT_SOC_DTB			:= soc-prebuild_system-zcu106.dtb
BOOT_KERNEL_DTB_PLAIN	:=
BOOT_DEFAULT_TOPLEVEL	:= zcu106_menu
BOOT_BIN_NOTE			:=
BOOT_NET				:= 1
BOARD_IP				?= $(LAB_BOARD_IP_zcu106)
TFTP_KERNEL				:= Image_kernel
TFTP_DTB				:= kernel-zynqmp-zcu106-revA.dtb
TFTP_CONSOLE			:= ttyPS0
TFTP_ARGS				:= systemd.unit=multi-user.target cma=256M uio_pdrv_genirq.of_id=generic-uio net.ifnames=0
# NFS root: the armhf rootfs of the Zybo (FLOW=rootfs there), made the ZCU106's by
# firmware/common/mister/scripts/nfs-rootfs.sh (arm64 kernel modules, host name, /media/fat of
# FLOW=mister package, no codec setup of the Zybo: I2C bus 0 has other chips here)
NFS_ROOT_SRC			:= firmware/build/zybo-z7-20/ubuntu24.04-console-rootfs
NFS_ROOT_SETUP			= firmware/common/mister/scripts/nfs-rootfs.sh --modules firmware/build/zcu106/$(VIVADO_VER)/kernel	\
						  --disable ssm2603.service firmware/build/zcu106/mister/rootfs mister-zcu106

# mister (FLOW=mister): Main_MiSTer is the armhf program of the Zybo (the arm64 kernel runs it through
# CONFIG_COMPAT, patch 0002 finds the register base); cores as <design>:<core>[:<folder>]
MISTER_CORES			:= zcu106_menu:menu zcu106_msx:MSX zcu106_snes:SNES:_Console	\
						   zcu106_psx:PSX:_Console zcu106_n64:N64:_Console
MISTER_ROOTFS_FILES		:=
