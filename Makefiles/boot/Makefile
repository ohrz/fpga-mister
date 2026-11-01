#-----------------------------------------------------------------------------
# File       : Makefile
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2023-12-20
#-----------------------------------------------------------------------------
# Description:
# FLOW=boot: boot.scr, BOOT.bin, kernel, DTBs and uEnv.txt in firmware/build/<platform>/<version>/boot,
# TFTP/NFS network boot (needs u-boot-tools, bootgen from Vivado).
#-----------------------------------------------------------------------------
# Copyright (c) 2021-2026 by OHRZ
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# Board profile, supported platforms, Vivado version (Makefiles/common.mk)
#-----------------------------------------------------------------------------
include $(dir $(lastword $(MAKEFILE_LIST)))../common.mk

#-----------------------------------------------------------------------------
# Board profile (platform.mk): PLATFORM_ARCH (bootgen zynq|zynqmp), BOOT_FIRMWARE
# (soc-prebuilt: FSBL, PMUFW, ATF, U-Boot from soc-prebuilt-firmware; files:
# FSBL from files/fsbl, U-Boot from FLOW=uboot), BOOT_SOC_PREBUILT_PATH,
# BOOT_KERNEL_DTB (+ _PLAIN), BOOT_BIF, BOOT_DEFAULT_TOPLEVEL, BOOT_KERNEL_FILES,
# BOOT_FSBL_CMDS, BOARD_IP, TFTP_*
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# soc-prebuilt-firmware (FSBL, PMUFW, ATF, U-Boot and DTB of the ZynqMP boards)
#   checkout of branch xlnx_rel_v$(VIVADO_VER); from 2025.2 on the release
#   uses the SDT file names (fsbl.elf, arm-trusted-firmware.elf, ...)
#-----------------------------------------------------------------------------
include firmware/common/checkouts.mk
SOC_PREBUILT_DIR	:= $(call checkout_dir,soc-prebuilt-firmware)
SOC_PREBUILT_BRANCH	:= $(call checkout_branch,soc-prebuilt-firmware)

ifeq ($(filter $(VIVADO_VER),2023.1 2023.2 2024.1 2024.2 2025.1),$(VIVADO_VER))
	SOC_PREBUILT_FSBL	:= zynqmp_fsbl.elf
	SOC_PREBUILT_ATF	:= bl31.elf
else
	SOC_PREBUILT_FSBL	:= fsbl.elf
	SOC_PREBUILT_ATF	:= arm-trusted-firmware.elf
endif

# only the boards with soc-prebuilt firmware depend on the checkout
SOC_PREBUILT_DEP	:= $(if $(filter soc-prebuilt,$(BOOT_FIRMWARE)),soc-prebuilt-check)

#-----------------------------------------------------------------------------
# Names of the profile under the names the rules use
#   PLATFORM_DEFAULT_TOPLEVEL: bitstream in BOOT.bin when TOPLEVEL is not set
#-----------------------------------------------------------------------------
PLATFORM_KERNEL_GENERATED_DTB	:= $(BOOT_KERNEL_DTB)
# BIF and boot.cmd come from firmware/common/files by PLATFORM_ARCH (zynq, zynqmp); a board file
# files/<BOOT_BIF> or files/boot.cmd.default overrides them
BIF_SRC							:= $(if $(BOOT_BIF),firmware/targets/$(PLATFORM)/files/$(BOOT_BIF),firmware/common/files/boot-bin_$(PLATFORM_ARCH).bif)
PLATFORM_BIF_FILE				:= $(notdir $(BIF_SRC))
BOOT_CMD_SRC					:= $(firstword $(wildcard firmware/targets/$(PLATFORM)/files/boot.cmd.default) firmware/common/files/boot.cmd)
# kernel image name of the architecture (zImage/bootz on Zynq-7000, Image/booti on ZynqMP)
BOOT_KERNEL_IMAGE				:= $(if $(filter zynq,$(PLATFORM_ARCH)),zImage,Image)
PLATFORM_SOC_PREBUILD_PATH		:= $(BOOT_SOC_PREBUILT_PATH)
PLATFORM_DEFAULT_TOPLEVEL		:= $(BOOT_DEFAULT_TOPLEVEL)

# all outputs of this flow (boot.scr, BOOT.bin, kernel, DTBs, uEnv.txt) go here
BOOT_DIR		:= firmware/build/$(PLATFORM)/$(VIVADO_VER)/boot

#-----------------------------------------------------------------------------
# Network boot (tftpboot, uEnv.txt templates): board and server addresses of the lab
# (firmware/common/lab.mk, lab.local.mk; BOARD_IP, TFTP_* from the profile)
#-----------------------------------------------------------------------------
TFTP_SERVER_IP	?= $(LAB_TFTP_SERVER_IP)
NET_GATEWAY		?= $(LAB_NET_GATEWAY)
NET_MASK		?= $(LAB_NET_MASK)
NFS_ROOT		?= $(PWD)/firmware/build/$(PLATFORM)/ubuntu24.04-console-rootfs
# directory below /srv/tftp: not just <platform>, other projects may use that one for the same board
TFTP_DIR		?= mister-$(PLATFORM)
# host name of the board, the same as in the rootfs (FLOW=rootfs)
BOARD_HOSTNAME	:= mister-$(PLATFORM)
# BOOT_NETBOOT=0 (SD card image of a release): uEnv.txt boots the SD card at once, no boot
# menu and no TFTP/NFS entry with the addresses of this lab
BOOT_NETBOOT	?= 1

# placeholders in files/uEnv.txt
UENV_SED		:= -e 's|@TFTP_SERVER_IP@|$(TFTP_SERVER_IP)|g' -e 's|@BOARD_IP@|$(BOARD_IP)|g'	\
				   -e 's|@NET_GATEWAY@|$(NET_GATEWAY)|g' -e 's|@NET_MASK@|$(NET_MASK)|g' -e 's|@NFS_ROOT@|$(NFS_ROOT)|g'	\
				   -e 's|@BOARD_HOSTNAME@|$(BOARD_HOSTNAME)|g' -e 's|@TFTP_DIR@|$(TFTP_DIR)|g'
ifeq ($(BOOT_NETBOOT),0)
UENV_SED		:= -e '/^bootmenu_/d' -e 's|^uenvcmd=.*|uenvcmd=run args_sd \&\& run sd_load \&\& run linux_boot_cmd|'	\
				   -e '/^\(serverip\|ipaddr\|netmask\|gatewayip\|nfs_root_file\|set_nfs_args\|tftp_dir\|net_load\|args_net\)=/d'
endif
# Image and packages of the last kernel build (FLOW=kernel make build)
KERNEL_OUT		:= firmware/build/$(PLATFORM)/$(VIVADO_VER)/kernel
BOOT_TOPLEVEL	:= $(if $(TOPLEVEL),$(TOPLEVEL),$(PLATFORM_DEFAULT_TOPLEVEL))

# The boot files are regenerated on each copy (copies, mkimage, bootgen), so a
# new bitstream, U-Boot or boot firmware is never skipped.  The kernel
# (Image_kernel, kernel-*.dtb) is copied again when there is a newer kernel
# build in $(KERNEL_OUT); it comes from the same build as the packages the
# rootfs gets, so kernel and modules always match.
.PHONY: copy clean soc-prebuilt-check					\
	$(BOOT_DIR)/boot.scr $(BOOT_DIR)/BOOT.bin				\
	$(BOOT_DIR)/fsbl $(BOOT_DIR)/uboot $(BOOT_DIR)/firmware $(BOOT_DIR)/pl

#-----------------------------------------------------------------------------
# Help
#-----------------------------------------------------------------------------
.PHONY: help

help::
	@echo 'FLOW=boot: boot files in firmware/build/<platform>/<version>/boot'
	@echo ''
	@echo '  PLATFORM=<platform> [TOPLEVEL=<design>] FLOW=boot make <action>'
	@echo '    copy       boot.scr, BOOT.bin (bitstream of TOPLEVEL or the platform default), kernel, DTBs, uEnv.txt'
	@echo '    clean      remove boot/'
	@echo '    tftpboot   NFS export of the rootfs + boot/ to /srv/tftp/$(TFTP_DIR) (sudo), prints the U-Boot commands'
	@echo ''
	@echo '  BOOT_NETBOOT=0      uEnv.txt boots the SD card at once (no boot menu, no TFTP/NFS entry; release image)'
	@echo '  NFS_CLIENTS=<net>   clients of the rootfs export (default $(NFS_CLIENTS))'
	@echo '  BOARD_IP, TFTP_SERVER_IP, TFTP_DIR, NET_GATEWAY, NET_MASK, NFS_ROOT   network boot (defaults: $(or $(BOARD_IP),<board profile>), $(TFTP_SERVER_IP), $(NET_GATEWAY), $(NET_MASK))'
	@echo '  platforms: $(SUPPORTED_PLATFORMS)'

#-----------------------------------------------------------------------------
# Remove the generated boot/ directory
#-----------------------------------------------------------------------------
clean:
	@$(ECHO) "Remove $(BOOT_DIR)"
	rm -rf $(BOOT_DIR)

#-----------------------------------------------------------------------------
# Copy all available kernel images, DTBs and other bootfiles into /boot directory
#-----------------------------------------------------------------------------
copy:														\
$(BOOT_DIR)/boot.scr					\
$(BOOT_DIR)/BOOT.bin					\
$(BOOT_DIR)/Image_kernel

	@$(ECHO) "(8) Copy uEnv.txt"
	sed $(UENV_SED) firmware/targets/$(PLATFORM)/files/uEnv.txt > $(BOOT_DIR)/uEnv.txt

#-----------------------------------------------------------------------------
# create boot.scr
#-----------------------------------------------------------------------------
$(BOOT_DIR)/boot.scr:
	@$(ECHO) "(1) Create boot.scr"
	mkdir -p $(BOOT_DIR)

	sed -e 's|@BOOTCMD@|$(TFTP_BOOTCMD)|g' -e 's|@KERNEL@|$(BOOT_KERNEL_IMAGE)|g' $(BOOT_CMD_SRC) > $(BOOT_DIR)/boot.cmd
	mkimage -c none -A arm -T script -d $(BOOT_DIR)/boot.cmd $(BOOT_DIR)/boot.scr

#-----------------------------------------------------------------------------
# create BOOT.bin
#-----------------------------------------------------------------------------
$(BOOT_DIR)/BOOT.bin:	\
$(BOOT_DIR)/fsbl		\
$(BOOT_DIR)/uboot		\
$(BOOT_DIR)/firmware	\
$(BOOT_DIR)/kernel-$(PLATFORM_KERNEL_GENERATED_DTB)	\
$(BOOT_DIR)/pl

	@test -f $(BOOT_DIR)/pl/$(BOOT_TOPLEVEL).bit || { echo "ERROR: $(BOOT_DIR)/pl/$(BOOT_TOPLEVEL).bit missing, run FLOW=vivado TOPLEVEL=$(BOOT_TOPLEVEL) make build first"; exit 1; }
	@$(ECHO) "  BOOT.bin with bitstream $(BOOT_TOPLEVEL).bit"
	sed -e 's|@TOPLEVEL@|$(BOOT_TOPLEVEL)|g' -e 's|@KERNEL_DTB@|kernel-$(PLATFORM_KERNEL_GENERATED_DTB)|g'	\
		$(BIF_SRC) > $(BOOT_DIR)/$(PLATFORM_BIF_FILE)

	@$(ECHO) "  (6) create BOOT.bin"
	cd $(BOOT_DIR); bootgen -image $(PLATFORM_BIF_FILE) -arch $(PLATFORM_ARCH) -o BOOT.bin -w

#-----------------------------------------------------------------------------
# Copy fsbl
#-----------------------------------------------------------------------------
$(BOOT_DIR)/fsbl:	\
$(SOC_PREBUILT_DEP)				\
$(if $(filter soc-prebuilt,$(BOOT_FIRMWARE)),,firmware/targets/$(PLATFORM)/files/fsbl/fsbl.elf)

	@$(ECHO) "  (2) copy fsbl to boot/fsbl"
	mkdir -p $(BOOT_DIR)/fsbl

ifeq ($(BOOT_FIRMWARE),soc-prebuilt)
	cp $(SOC_PREBUILT_DIR)/$(PLATFORM_SOC_PREBUILD_PATH)/$(SOC_PREBUILT_FSBL)			$(BOOT_DIR)/fsbl/zynqmp_fsbl.elf
else
	cp -r firmware/targets/$(PLATFORM)/files/fsbl													$(BOOT_DIR)
endif

#-----------------------------------------------------------------------------
# Build fsbl if needed (BOOT_FSBL_CMDS of the profile, e.g. xsct on the XSA)
#-----------------------------------------------------------------------------
firmware/targets/$(PLATFORM)/files/fsbl/fsbl.elf:
	$(BOOT_FSBL_CMDS)

#-----------------------------------------------------------------------------
# Copy prebuild uboot
#-----------------------------------------------------------------------------
$(BOOT_DIR)/uboot:	\
$(SOC_PREBUILT_DEP)
	@$(ECHO) "  (3) copy uboot to boot/uboot"
	mkdir -p $(BOOT_DIR)/uboot

ifeq ($(BOOT_FIRMWARE),soc-prebuilt)
	cp $(SOC_PREBUILT_DIR)/$(PLATFORM_SOC_PREBUILD_PATH)/u-boot.elf						$(BOOT_DIR)/uboot
else
	cp firmware/build/$(PLATFORM)/$(VIVADO_VER)/u-boot-xlnx/u-boot.elf								$(BOOT_DIR)/uboot
endif

#-----------------------------------------------------------------------------
# Copy prebuild boot firmware
#-----------------------------------------------------------------------------
$(BOOT_DIR)/firmware:	\
$(SOC_PREBUILT_DEP)
	@$(ECHO) "  (4) copy firmware to boot/"
	mkdir -p $(BOOT_DIR)/firmware

ifeq ($(BOOT_FIRMWARE),soc-prebuilt)
	cp $(SOC_PREBUILT_DIR)/$(PLATFORM_SOC_PREBUILD_PATH)/$(SOC_PREBUILT_ATF)			$(BOOT_DIR)/firmware/bl31.elf
	cp $(SOC_PREBUILT_DIR)/$(PLATFORM_SOC_PREBUILD_PATH)/pmufw.elf						$(BOOT_DIR)/firmware
endif

#-----------------------------------------------------------------------------
# Copy the kernel's board DTB (collected by FLOW=kernel make build/collect
# together with the Image, so it comes from the same build)
#-----------------------------------------------------------------------------
$(BOOT_DIR)/kernel-$(PLATFORM_KERNEL_GENERATED_DTB):	\
$(wildcard $(KERNEL_OUT)/kernel.release)
	@$(ECHO) "    Copy the kernel DTB from $(KERNEL_OUT)"
	@test -f $(KERNEL_OUT)/$(PLATFORM_KERNEL_GENERATED_DTB) || { echo "ERROR: $(KERNEL_OUT)/$(PLATFORM_KERNEL_GENERATED_DTB) missing, run FLOW=kernel make collect (or build)"; exit 1; }
	cp $(KERNEL_OUT)/$(PLATFORM_KERNEL_GENERATED_DTB)	$(BOOT_DIR)/kernel-$(PLATFORM_KERNEL_GENERATED_DTB)
ifneq ($(BOOT_KERNEL_DTB_PLAIN),)
#	also under its plain name (the one uEnv.txt boots on the Zybo)
	cp $(KERNEL_OUT)/$(PLATFORM_KERNEL_GENERATED_DTB)	$(BOOT_DIR)/$(PLATFORM_KERNEL_GENERATED_DTB)
endif

#-----------------------------------------------------------------------------
# The bitstream of the boot design (input of bootgen for BOOT.bin)
#-----------------------------------------------------------------------------
$(BOOT_DIR)/pl:
	@$(ECHO) "  (5) copy the bitstream of $(BOOT_TOPLEVEL) to boot/pl (BOOT.bin)"
	@test -f firmware/build/$(PLATFORM)/$(VIVADO_VER)/hw/bins/$(BOOT_TOPLEVEL).bit || { echo "ERROR: firmware/build/$(PLATFORM)/$(VIVADO_VER)/hw/bins/$(BOOT_TOPLEVEL).bit missing, run FLOW=vivado TOPLEVEL=$(BOOT_TOPLEVEL) make build first"; exit 1; }
	rm -rf $(BOOT_DIR)/pl
	mkdir -p $(BOOT_DIR)/pl
	cp firmware/build/$(PLATFORM)/$(VIVADO_VER)/hw/bins/$(BOOT_TOPLEVEL).bit						$(BOOT_DIR)/pl

#-----------------------------------------------------------------------------
# Copy Linux kernel images
#-----------------------------------------------------------------------------
$(BOOT_DIR)/Image_kernel:	\
$(wildcard $(KERNEL_OUT)/kernel.release)
	@$(ECHO) "(7) Copy kernel image from $(KERNEL_OUT)"
	@test -f $(KERNEL_OUT)/kernel.release || { echo "ERROR: $(KERNEL_OUT) missing, run FLOW=kernel make build (or make collect)"; exit 1; }
	mkdir -p $(BOOT_DIR)

#	BOOT_KERNEL_FILES of the profile: <file in kernel/>:<name in boot/>
	@for f in $(BOOT_KERNEL_FILES); do echo "cp $(KERNEL_OUT)/$${f%%:*} $(BOOT_DIR)/$${f#*:}"; cp $(KERNEL_OUT)/$${f%%:*} $(BOOT_DIR)/$${f#*:} || exit 1; done
	@$(ECHO) "    kernel $$(cat $(KERNEL_OUT)/kernel.release): install $(KERNEL_OUT)/*.deb on the board (or rebuild the rootfs)"

#-----------------------------------------------------------------------------
# TFTP Boot
#    # install tftp
#    sudo apt install tftpd-hpa
#    # install nfs
#    sudo apt install nfs-kernel-server
#-----------------------------------------------------------------------------
tftpboot: \
setup-nfs \
tftp-copybootfiles

	@$(ECHO) "  (3) TFTP setup done"
	@$(ECHO) "  To boot from tftp do this from uboot:"
	@$(ECHO) "  "
	@$(ECHO) "  setenv ipaddr $(BOARD_IP)     # ip of $(PLATFORM)"
	@$(ECHO) "  setenv serverip $(TFTP_SERVER_IP)   # ip of tftp server"
	@$(ECHO) "  ping $(TFTP_SERVER_IP)              # test ethernet"
	@$(ECHO) "  "
	@$(ECHO) "  tftpboot 0x00200000 $(TFTP_DIR)/$(TFTP_KERNEL)     # Load the Kernel into RAM"
	@$(ECHO) "  "
	@$(ECHO) "  tftpboot 0x00100000 $(TFTP_DIR)/$(TFTP_DTB)  # 2. Load the Device Tree into RAM"
	@$(ECHO) "  "
	@$(ECHO) "  setenv netroot $(NFS_ROOT)"
#	bootargs with quotes; ip=<client-ip>:<server-ip>:<gw-ip>:<netmask>:<hostname>:<device>:<autoconf>
	@$(ECHO) '  setenv bootargs "console=$(TFTP_CONSOLE),115200 cma=256M uio_pdrv_genirq.of_id=generic-uio root=/dev/nfs rw nfsroot=$${serverip}:$${netroot},v3,tcp ip=$${ipaddr}:$${serverip}:$(NET_GATEWAY):$(NET_MASK):$(BOARD_HOSTNAME):eth0:off"'
	@$(ECHO) "  $(TFTP_BOOTCMD) 0x00200000 - 0x00100000	# boot (no saveenv: the environment on the card stays as it is)"
	@$(ECHO) "  "
	@$(ECHO) "  Or choose \"TFTP/NFS Boot\" in the boot menu of uEnv.txt."

# NFS clients allowed to mount the rootfs (rw, no_root_squash)
NFS_CLIENTS ?= $(LAB_NFS_CLIENTS)

setup-nfs:
	@echo "	    (1) Adding RootFS to /etc/exports.d/fpga-mister-$(PLATFORM).exports"
    # own file per platform, /etc/exports stays untouched
	sudo mkdir -p /etc/exports.d
	echo "$(NFS_ROOT) $(NFS_CLIENTS)(rw,sync,no_root_squash,no_subtree_check)" | sudo tee /etc/exports.d/fpga-mister-$(PLATFORM).exports
	sudo exportfs -arv

tftp-copybootfiles:
	@echo "	    (2) Copy boot/ files to /srv/tftp/$(TFTP_DIR)/"
    # one directory per board and repo: the boards share file names (zImage, Image, BOOT.bin, uEnv.txt);
    # readable for tftpd, not world-writable
	sudo mkdir -p /srv/tftp/$(TFTP_DIR)
	sudo cp -r $(BOOT_DIR)/* 	/srv/tftp/$(TFTP_DIR)/
	sudo chmod -R a+rX /srv/tftp/$(TFTP_DIR)

#-----------------------------------------------------------------------------
# soc-prebuilt-firmware: release branch of the Vivado version (firmware/common/checkouts.txt),
# cloned by checkout.sh; the checkout must be that branch at origin's tip
#-----------------------------------------------------------------------------
$(SOC_PREBUILT_DIR)/:
	VIVADO_VER=$(VIVADO_VER) $(CHECKOUT_SH) soc-prebuilt-firmware

soc-prebuilt-check: $(SOC_PREBUILT_DIR)/
	@VIVADO_VER=$(VIVADO_VER) $(CHECKOUT_SH) --check soc-prebuilt-firmware

#	Makefile ends here