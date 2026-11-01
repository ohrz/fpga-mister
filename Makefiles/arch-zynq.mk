#-----------------------------------------------------------------------------
# File       : arch-zynq.mk
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-24
#-----------------------------------------------------------------------------
# Description:
# Defaults of the board profiles with PLATFORM_ARCH := zynq, included by
# Makefiles/common.mk after firmware/targets/<platform>/platform.mk. Every value
# is a ?= default: a board profile that sets the variable wins.
#-----------------------------------------------------------------------------
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------

KERNEL_ARCH				?= arm
KERNEL_CROSS_COMPILE	?= arm-linux-gnueabihf-
KERNEL_DEBARCH			?= armhf
KERNEL_XILINX_DEFCONFIG	?= xilinx_zynq_defconfig
UBOOT_ENV				?= CROSS_COMPILE=arm-linux-gnueabihf- ARCH=arm
# U-Boot of the Zynq-7000 boards has bootz only (no booti)
TFTP_BOOTCMD			?= bootz
BOOT_KERNEL_FILES		?= Image:Image_kernel zImage:zImage_kernel zImage:zImage
# FSBL of the boot bitstream with xsct when files/fsbl/fsbl.elf is missing (needs hw/<BOOT_TOPLEVEL>.xsa
# of make xsa-export); the workspace is firmware/build/<platform>/<version>/fsbl, BOOT_FSBL_UART the console
BOOT_FSBL_UART			?= ps7_uart_0
ifndef BOOT_FSBL_CMDS
define BOOT_FSBL_CMDS
	xsct $(CURDIR)/firmware/common/scripts/build-zynq-fsbl.tcl $(CURDIR)/firmware/build/$(PLATFORM)/$(VIVADO_VER)/hw/$(BOOT_TOPLEVEL).xsa $(CURDIR)/firmware/build/$(PLATFORM)/$(VIVADO_VER)/fsbl $(BOOT_FSBL_UART)
	mkdir -p firmware/targets/$(PLATFORM)/files/fsbl
	cp firmware/build/$(PLATFORM)/$(VIVADO_VER)/fsbl/zynq_fsbl/Debug/zynq_fsbl.elf firmware/targets/$(PLATFORM)/files/fsbl/fsbl.elf
endef
endif
ROOTFS_ARCH				?= armhf
# Main_MiSTer (FLOW=mister): armhf cross compiler of the Vitis installation (glibc 2.39 like Ubuntu 24.04)
MISTER_CROSS_COMPILE	?= arm-linux-gnueabihf-

# every architecture: derived from the kernel settings of the profile
BOOT_KERNEL_DTB			?= $(KERNEL_DTB)
UBOOT_DEVICE_TREE		?= $(KERNEL_XILINX_DEVICE_TREE)
VIVADO_XSA_EXPORT_ARGS	?=
VIVADO_SETUP_CHECKOUTS ?=

# Makefile ends here
