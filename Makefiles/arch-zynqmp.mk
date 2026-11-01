#-----------------------------------------------------------------------------
# File       : arch-zynqmp.mk
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-24
#-----------------------------------------------------------------------------
# Description:
# Defaults of the board profiles with PLATFORM_ARCH := zynqmp, included by
# Makefiles/common.mk after firmware/targets/<platform>/platform.mk. Every value
# is a ?= default: a board profile that sets the variable wins.
#-----------------------------------------------------------------------------
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------

KERNEL_ARCH				?= arm64
KERNEL_CROSS_COMPILE	?= aarch64-linux-gnu-
KERNEL_DEBARCH			?= arm64
# 2025.2 merged the ZynqMP defconfig into xilinx_defconfig
KERNEL_XILINX_DEFCONFIG	?= $(if $(filter 2025.2,$(VIVADO_VER)),xilinx_defconfig,xilinx_zynqmp_defconfig)
UBOOT_ENV				?= CROSS_COMPILE=aarch64-linux-gnu- ARCH=aarch64
TFTP_BOOTCMD			?= booti
BOOT_KERNEL_FILES		?= Image:Image_kernel Image:Image
ROOTFS_ARCH				?= arm64

# every architecture: derived from the kernel settings of the profile
BOOT_KERNEL_DTB			?= $(KERNEL_DTB)
UBOOT_DEVICE_TREE		?= $(KERNEL_XILINX_DEVICE_TREE)
VIVADO_XSA_EXPORT_ARGS	?=
VIVADO_SETUP_CHECKOUTS ?=

# Makefile ends here
