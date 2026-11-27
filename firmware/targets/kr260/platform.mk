#-----------------------------------------------------------------------------
# File       : platform.mk
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-26
# Platform   : KR260 (Kria K26 SOM, Zynq UltraScale+ XCK26)
#-----------------------------------------------------------------------------
# Description:
# Board profile of kr260, included by Makefiles/common.mk for every flow.
# DRAFT: no design of this board was built yet (firmware/targets/kr260/README.md).
# The MiSTer designs (scripts/2025.2/kr260_mister.tcl) are loaded at runtime by
# Main_MiSTer through the fpga_manager. The video goes into the live input of
# the PS DisplayPort (fixed 720p), so there is no VIDEO_TX choice. U-Boot comes
# from the QSPI flash of the Kria boot firmware and stays as it is: never write
# the QSPI. Proposal as on the ZCU106: kernel and DTB through TFTP, the RootFS
# through NFS, U-Boot commands without saveenv.
#-----------------------------------------------------------------------------

PLATFORM_FLOWS			:= vivado kernel boot mister
# zynq | zynqmp: bootgen architecture (.bit.bin)
PLATFORM_ARCH			:= zynqmp
# checkouts of FLOW=vivado make setup: MiSTer sources
VIVADO_SETUP_CHECKOUTS	:= Template_MiSTer MSX_MiSTer Menu_MiSTer SNES_MiSTer PSX_MiSTer N64_MiSTer

# kernel (FLOW=kernel): linux-xlnx with the K26 SOM and KR260 carrier DTB of the kernel tree.
# dts/zynqmp-sck-kr-g-revB.dtso replaces the carrier overlay of the tree: it adds the reserved
# PL DDR 0x1FF0_0000 of the MiSTer part (the kernel build merges it into KERNEL_DTB).
# TODO(kr260): the dpsub node of the live video input (port@0, clock dp_live_video_in_clk)
KERNEL_XILINX_DEVICE_TREE := zynqmp-sc-revB
KERNEL_DTB				:= zynqmp-smk-k26-revA-sck-kr-g-revB.dtb
KERNEL_DTS_FILES		:= dts/zynqmp-sck-kr-g-revB.dtso
KERNEL_PATCHES			:=

# boot (FLOW=boot): network boot only; the boot firmware and U-Boot stay those of the QSPI flash,
# copy builds a BOOT.bin from the prebuilt firmware as for the other ZynqMP boards
BOOT_FIRMWARE			:= soc-prebuilt
BOOT_SOC_PREBUILT_PATH	:= kr260-kria
BOOT_SOC_DTB_LEGACY		:= system-zynqmp-sck-kr-g-revB.dtb
BOOT_SOC_DTB_SDT		:= fit-dtb.blob
BOOT_SYSTEM_DTB			:=
BOOT_SYSTEM_DTB_SRC		:=
BOOT_SOC_DTB			= soc-prebuild_$(SOC_PREBUILT_DTB)
BOOT_KERNEL_DTB_PLAIN	:=
BOOT_DEFAULT_TOPLEVEL	:= kr260_menu
BOOT_BIN_NOTE			:= The KR260 starts from the boot firmware in its QSPI flash. This BOOT.bin is not used.
BOOT_NET				:= 1
BOARD_IP				?= $(LAB_BOARD_IP_kr260)
TFTP_KERNEL				:= Image_kernel
TFTP_DTB				:= kernel-zynqmp-smk-k26-revA-sck-kr-g-revB.dtb
TFTP_CONSOLE			:= ttyPS1
TFTP_ARGS				:= systemd.unit=multi-user.target cma=256M uio_pdrv_genirq.of_id=generic-uio net.ifnames=0
# NFS root: the armhf RootFS of the Zybo, made the KR260's by nfs-rootfs.sh (arm64 kernel modules,
# host name, /media/fat of FLOW=mister package, no codec setup of the Zybo)
NFS_ROOT_SRC			:= firmware/build/zybo-z7-20/ubuntu24.04-console-rootfs
NFS_ROOT_SETUP			= firmware/common/mister/scripts/nfs-rootfs.sh --modules firmware/build/kr260/$(VIVADO_VER)/kernel	\
						  --disable ssm2603.service firmware/build/kr260/mister/rootfs mister-kr260

# mister (FLOW=mister): Main_MiSTer is the armhf program of the Zybo (the arm64 kernel runs it through
# CONFIG_COMPAT, patch 0002 finds the register base); cores as <design>:<core>[:<folder>]
MISTER_CORES			:= kr260_menu:menu kr260_msx:MSX kr260_snes:SNES:_Console	\
						   kr260_psx:PSX:_Console kr260_n64:N64:_Console
# board files of the rootfs: fixed slow fan speed (kr260-fan.service), DP live inputs after Main
# (kr260-dp-live.service with /usr/local/bin/kr260_dp_live.py)
MISTER_ROOTFS_FILES		:= files/mister-rootfs
MISTER_ROOTFS_TOOLS		:= sw/kr260_dp_live.py
