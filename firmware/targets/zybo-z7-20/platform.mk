#-----------------------------------------------------------------------------
# File       : platform.mk
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-28
# Platform   : Zybo Z7-20 (Zynq-7020)
#-----------------------------------------------------------------------------
# Description:
# Board profile of zybo-z7-20, included by Makefiles/common.mk for every flow.
# PLATFORM_FLOWS lists the flows that accept this board; the other variables
# are what the flow Makefiles need to know about the board (nothing else is
# board-specific in Makefiles/).
#-----------------------------------------------------------------------------

PLATFORM_FLOWS			:= vivado kernel uboot boot rootfs mister
# video output of the designs in BOOT.bin and the MiSTer package: dvi (rgb2dvi, default) or hdmi
# (zybo-z7-20_<core>_hdmi: HDMI with sound, doc/ARCHITECTURE.md §4.1), e.g. VIDEO_TX=hdmi FLOW=boot make copy;
# FLOW=vivado CORE=<core> takes it for the design name; VIDEO=<x> is short for VIDEO_TX (Makefiles/common.mk)
VIDEO_TX				?= dvi
ifeq ($(filter dvi hdmi,$(VIDEO_TX)),)
$(error VIDEO_TX must be dvi or hdmi, not "$(VIDEO_TX)")
endif
ZYBO_DESIGN_SUFFIX		:= $(if $(filter hdmi,$(VIDEO_TX)),_hdmi,)
# zynq | zynqmp: bootgen architecture (.bit.bin, BOOT.bin);
# Makefiles/arch-<arch>.mk supplies the defaults of the architecture (cross compiler, defconfig, ...)
PLATFORM_ARCH			:= zynq

# vivado (FLOW=vivado): make setup clones the sources of the designs (firmware/common/checkouts.txt):
# Digilent vivado-library (rgb2dvi), MiSTer framework (sys/) and every core with a profile in
# firmware/common/mister/cores (menu, MSX, SNES, PSX, N64); the HDMI transmitter of the _hdmi
# designs is firmware/common/ip/hdmi-tx of this repository
VIVADO_SETUP_CHECKOUTS	:= vivado-library Template_MiSTer MSX_MiSTer Menu_MiSTer SNES_MiSTer PSX_MiSTer N64_MiSTer
# xsa-export (FSBL): fixed XSA, the MiSTer designs are no Vitis platforms (no platform.name)
VIVADO_XSA_EXPORT_ARGS	:= --fixed

# kernel (FLOW=kernel): defconfig + common/linux/kernel.config (+ optional files/kernel.config), bindeb-pkg; KERNEL_DTB is the board
# DTB collected next to the Image, KERNEL_DTS_FILES are copied from dts/ into the kernel tree
# (arch/<arch>/boot/dts/xilinx) before every build, KERNEL_PATCHES applied once by make patch
KERNEL_XILINX_DEVICE_TREE := zynq-zybo-z7
KERNEL_DTB				:= zynq-zybo-z7.dtb
KERNEL_DTS_FILES		:= dts/zynq-zybo-z7.dts
KERNEL_PATCHES			:=

# uboot (FLOW=uboot): built here and used by the boot flow; board DTS into the tree
UBOOT_DEFCONFIG			:= xilinx_zynq_virt_defconfig
UBOOT_DTS_FILES			:= dts/zynq-zybo-z7.dts
UBOOT_PATCHES			:=

# boot (FLOW=boot): FSBL from files/fsbl (built on demand by BOOT_FSBL_CMDS of arch-zynq.mk; the Zybo
# console is UART1), U-Boot from the own build
BOOT_FSBL_UART			:= ps7_uart_1
BOOT_FIRMWARE			:= files
BOOT_SOC_PREBUILT_PATH	:=
# the kernel DTB also as plain zynq-zybo-z7.dtb (the name uEnv.txt boots)
BOOT_KERNEL_DTB_PLAIN	:= 1
BOOT_DEFAULT_TOPLEVEL	:= zybo-z7-20_msx$(ZYBO_DESIGN_SUFFIX)
BOARD_IP				?= $(LAB_BOARD_IP_zybo-z7-20)
TFTP_KERNEL				:= zImage_kernel
TFTP_DTB				:= zynq-zybo-z7.dtb
TFTP_CONSOLE			:= ttyPS0

# rootfs (FLOW=rootfs): the FAT partition of the card, /media/fat on the board
ROOTFS_BOOT_DEV			:= /dev/mmcblk0p1

# mister (FLOW=mister): Main_MiSTer and /media/fat; <design>:<core>[:<folder>], the bitstream
# hw/bins/<design>.bit.bin becomes /media/fat/<folder>/<core>.rbf (default _Computer), the core menu
# /media/fat/menu.rbf
MISTER_CORES			:= zybo-z7-20_menu$(ZYBO_DESIGN_SUFFIX):menu zybo-z7-20_msx$(ZYBO_DESIGN_SUFFIX):MSX	\
						   zybo-z7-20_snes$(ZYBO_DESIGN_SUFFIX):SNES:_Console zybo-z7-20_psx$(ZYBO_DESIGN_SUFFIX):PSX:_Console	\
						   zybo-z7-20_n64$(ZYBO_DESIGN_SUFFIX):N64:_Console
# board files of the rootfs: configuration of the audio codec SSM2603 (ssm2603.service)
MISTER_ROOTFS_FILES		:= files/mister-rootfs
