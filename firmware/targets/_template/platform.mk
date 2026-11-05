#-----------------------------------------------------------------------------
# File       : platform.mk
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : <date>
# Platform   : <board> (<device>)
#-----------------------------------------------------------------------------
# Description:
# TEMPLATE (firmware/targets/_template, no board: Makefiles/common.mk and
# selfcheck.sh skip firmware/targets/_*): copy to firmware/targets/<board>/ and
# replace every <...>.  Made from the zybo-z7-20 profile; what the board must
# provide to Main_MiSTer and the cores is the board contract, doc/PORTING.md §7.1.
# Board profile of <board>, included by Makefiles/common.mk for every flow.
# PLATFORM_FLOWS lists the flows that accept this board; the other variables
# are what the flow Makefiles need to know about the board (nothing else is
# board-specific in Makefiles/).
#-----------------------------------------------------------------------------

PLATFORM_FLOWS			:= vivado kernel uboot boot rootfs mister
# video output of the designs in BOOT.bin and the MiSTer package: dvi (rgb2dvi, default) or hdmi
# (<board>_<core>_hdmi: HDMI with sound, doc/ARCHITECTURE.md §4.1), e.g. VIDEO_TX=hdmi FLOW=boot make copy;
# FLOW=vivado CORE=<core> takes it for the design name; VIDEO=<x> is short for VIDEO_TX (Makefiles/common.mk)
VIDEO_TX				?= dvi
ifeq ($(filter dvi hdmi,$(VIDEO_TX)),)
$(error VIDEO_TX must be dvi or hdmi, not "$(VIDEO_TX)")
endif
BOARD_DESIGN_SUFFIX		:= $(if $(filter hdmi,$(VIDEO_TX)),_hdmi,)
# zynq | zynqmp: bootgen architecture (.bit.bin, BOOT.bin);
# Makefiles/arch-<arch>.mk supplies the defaults of the architecture (cross compiler, defconfig, ...)
PLATFORM_ARCH			:= <zynq|zynqmp>

# vivado (FLOW=vivado): make setup clones the sources of the designs (firmware/common/checkouts.txt):
# Digilent vivado-library (rgb2dvi), MiSTer framework (sys/) and the cores the board builds
# (TODO: the profiles in firmware/common/mister/cores that fit the board); the HDMI transmitter
# of the _hdmi designs is firmware/common/ip/hdmi-tx of this repository
VIVADO_SETUP_CHECKOUTS	:= vivado-library Template_MiSTer MSX_MiSTer Menu_MiSTer SNES_MiSTer
# xsa-export (FSBL): fixed XSA, the MiSTer designs are no Vitis platforms (no platform.name)
VIVADO_XSA_EXPORT_ARGS	:= --fixed

# kernel (FLOW=kernel): defconfig + common/linux/kernel.config (+ optional files/kernel.config), bindeb-pkg; KERNEL_DTB is the board
# DTB collected next to the Image, KERNEL_DTS_FILES are copied from dts/ into the kernel tree
# (arch/<arch>/boot/dts/xilinx) before every build, KERNEL_PATCHES applied once by make patch
KERNEL_XILINX_DEVICE_TREE := <dts name>
KERNEL_DTB				:= <dts name>.dtb
KERNEL_DTS_FILES		:= dts/<dts name>.dts
KERNEL_PATCHES			:=

# uboot (FLOW=uboot): built here and used by the boot flow; board DTS into the tree
UBOOT_DEFCONFIG			:= <xilinx_zynq_virt_defconfig|xilinx_zynqmp_virt_defconfig>
UBOOT_DTS_FILES			:= dts/<dts name>.dts
UBOOT_PATCHES			:=

# boot (FLOW=boot): FSBL from files/fsbl (built on demand by BOOT_FSBL_CMDS of arch-<arch>.mk), U-Boot
# from the own build; ZynqMP also needs PMU firmware and TF-A (open)
BOOT_FSBL_UART			:= <console UART of the FSBL, e.g. ps7_uart_1>
BOOT_FIRMWARE			:= files
BOOT_SOC_PREBUILT_PATH	:=
# the kernel DTB also under its plain name (the name uEnv.txt boots)
BOOT_KERNEL_DTB_PLAIN	:= 1
BOOT_DEFAULT_TOPLEVEL	:= <board>_msx$(BOARD_DESIGN_SUFFIX)
BOARD_IP				?= $(LAB_BOARD_IP_<board>)
TFTP_KERNEL				:= <zImage_kernel (zynq) | Image (zynqmp, open)>
TFTP_DTB				:= <dts name>.dtb
TFTP_CONSOLE			:= <ttyPS0>
TFTP_ARGS				:= <kernel arguments of an NFS boot besides console, root and ip, as in uEnv.txt>

# rootfs (FLOW=rootfs): the FAT partition of the card, /media/fat on the board
ROOTFS_BOOT_DEV			:= /dev/mmcblk0p1

# mister (FLOW=mister): Main_MiSTer and /media/fat; <design>:<core>[:<folder>], the bitstream
# hw/bins/<design>.bit.bin becomes /media/fat/<folder>/<core>.rbf (default _Computer), the core menu
# /media/fat/menu.rbf
MISTER_CORES			:= <board>_menu$(BOARD_DESIGN_SUFFIX):menu <board>_msx$(BOARD_DESIGN_SUFFIX):MSX
# board files of the rootfs: configuration of the audio codec (Zybo: SSM2603, ssm2603.service)
MISTER_ROOTFS_FILES		:= files/mister-rootfs
