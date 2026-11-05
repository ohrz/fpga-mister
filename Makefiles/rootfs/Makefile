#-----------------------------------------------------------------------------
# File       : Makefile
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2023-12-20
#-----------------------------------------------------------------------------
# Description:
# FLOW=rootfs: the minimal Ubuntu 24.04 console rootfs of a MiSTer board
# (debootstrap + chroot, sudo) and the SD card image of the release: FAT32
# partition with the boot files and /media/fat, ext4 partition with the rootfs.
#-----------------------------------------------------------------------------
# Copyright (c) 2021-2026 by OHRZ
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# Board profile, supported platforms, Vivado version (Makefiles/common.mk)
#-----------------------------------------------------------------------------
include $(dir $(lastword $(MAKEFILE_LIST)))../common.mk

.PHONY: help build clean package image write flash

# kernel packages of the last kernel build (FLOW=kernel make build)
KERNEL_OUT		:= firmware/build/$(PLATFORM)/$(VIVADO_VER)/kernel
# build directory and rootfs (debootstrap architecture ROOTFS_ARCH and the FAT partition
# ROOTFS_BOOT_DEV from the profile); the build asks no questions
STAGE			:= firmware/build/$(PLATFORM)
ROOTFS_DIR		:= $(STAGE)/ubuntu24.04-console-rootfs
ROOTFS_TGZ		:= $(STAGE)/ubuntu24.04-console-rootfs.tgz
# password of root and fpga (the default of the release image)
ROOTFS_PASSWORD	?= mister
export ROOTFS_PASSWORD
# DNS server when DHCP gives none (NFS root, no DHCP), empty: none
ROOTFS_FALLBACK_DNS ?= $(LAB_FALLBACK_DNS)
ROOTFS_HOSTNAME	?= mister-$(PLATFORM)

# SD card image: boot files of FLOW=boot make copy, /media/fat of FLOW=mister make package
SDIMAGE_BOOT	:= firmware/build/$(PLATFORM)/$(VIVADO_VER)/boot
# what the card boots: BOOT.bin (FSBL, bitstream, U-Boot), boot.scr, uEnv.txt, kernel, board DTB
SDIMAGE_BOOT_FILES := $(addprefix $(SDIMAGE_BOOT)/,BOOT.bin boot.scr uEnv.txt	\
				   $(if $(filter zynq,$(PLATFORM_ARCH)),zImage,Image) $(KERNEL_DTB))
SDIMAGE_FAT		:= firmware/build/$(PLATFORM)/mister/rootfs/media/fat
SDIMAGE_FAT_MB	?= 4096
SDIMAGE_VERSION	?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
SDIMAGE			:= $(STAGE)/fpga-mister-$(PLATFORM)-$(SDIMAGE_VERSION).img

help::
	@echo 'FLOW=rootfs: minimal Ubuntu 24.04 console rootfs (debootstrap, sudo) and the SD card image'
	@echo ''
	@echo '  PLATFORM=<platform> FLOW=rootfs make <action>'
	@echo '    build      debootstrap + chroot without questions: systemd, SSH, DHCP, the kernel packages of'
	@echo '               FLOW=kernel make build and the systemd units of FLOW=mister make package'
	@echo '    image      $(STAGE)/fpga-mister-$(PLATFORM)-<version>.img(.xz): FAT32 (boot files of FLOW=boot'
	@echo '               make copy + /media/fat of FLOW=mister make package) and ext4 (rootfs)'
	@echo '    write      SDCARD=/dev/sdX: write the image to the card (erases the whole card)'
	@echo '    flash      write the image to the card of a board running from TFTP/NFS (FLOW=boot make tftpboot,'
	@echo '               ssh root@BOARD_IP), check it and reboot; SSH_KEYS=<file> goes to /media/fat/linux/authorized_keys'
	@echo '    package    $(ROOTFS_TGZ) (NFS root, hand-made card)'
	@echo '    clean      remove the rootfs directory (sudo)'
	@echo ''
	@echo '  ROOTFS_PASSWORD=<pw>   root and fpga (default mister)'
	@echo '  ROOTFS_HOSTNAME        (default $(ROOTFS_HOSTNAME))'
	@echo '  ROOTFS_FALLBACK_DNS    DNS without DHCP, e.g. NFS root (default $(ROOTFS_FALLBACK_DNS))'
	@echo '  SDIMAGE_FAT_MB         size of the FAT32 partition (default $(SDIMAGE_FAT_MB))'
	@echo '  BOARD_IP, SSH_KEYS     flash: the board (default $(BOARD_IP)), root keys of the new card (default $(SSH_KEYS))'
	@echo '  platforms: $(SUPPORTED_PLATFORMS)'

#-----------------------------------------------------------------------------
# rootfs build (sudo)
#-----------------------------------------------------------------------------
build:
	@$(ECHO) "Build RootFS"
	@test -f $(KERNEL_OUT)/kernel.release || { echo "ERROR: $(KERNEL_OUT) missing, run FLOW=kernel make build first"; exit 1; }
	@test ! -e $(ROOTFS_DIR) || { echo "ERROR: $(ROOTFS_DIR) exists, remove it first: PLATFORM=$(PLATFORM) FLOW=rootfs make clean"; exit 1; }
	mkdir -p $(STAGE)
	cp firmware/common/scripts/create-ubuntu-rootfs.sh firmware/common/scripts/build-ubuntu24.04-console-rootfs.sh $(STAGE)/

#	kernel packages of the last kernel build, the same build as the kernel on the FAT partition
	rm -rf $(STAGE)/debian
	mkdir -p $(STAGE)/debian
	cp $(KERNEL_OUT)/*.deb $(STAGE)/debian/

#	MiSTer files: $(STAGE)/mister-rootfs.tgz of FLOW=mister make package, unpacked in the chroot
	@test -f $(STAGE)/mister-rootfs.tgz && echo "MiSTer files: $(STAGE)/mister-rootfs.tgz" || echo "MiSTer files: none (FLOW=mister make package)"

#	host name and settings for the build script
	echo "$(ROOTFS_HOSTNAME)" > $(STAGE)/hostname
	printf 'export PLATFORM=%s\nexport ROOTFS_ARCH=%s\nexport ROOTFS_BOOT_DEV=%s\nexport ROOTFS_FALLBACK_DNS=%s\n'	\
		"$(PLATFORM)" "$(ROOTFS_ARCH)" "$(ROOTFS_BOOT_DEV)" "$(ROOTFS_FALLBACK_DNS)" > $(STAGE)/platform.sh

	cd $(STAGE) && ./create-ubuntu-rootfs.sh

#-----------------------------------------------------------------------------
# remove the rootfs directory (root-owned), refused while something is mounted in it
#-----------------------------------------------------------------------------
clean:
	@if findmnt -rno TARGET | grep -q "^$(CURDIR)/$(ROOTFS_DIR)/"; then echo "ERROR: something is mounted below $(ROOTFS_DIR), unmount it first"; exit 1; fi
	sudo rm -rf $(ROOTFS_DIR)

#-----------------------------------------------------------------------------
# rootfs as tgz
#-----------------------------------------------------------------------------
package:
	@$(ECHO) "Package RootFS"
	cp firmware/common/scripts/package-ubuntu-rootfs.sh $(STAGE)/
	cd $(STAGE) && ./package-ubuntu-rootfs.sh

#-----------------------------------------------------------------------------
# SD card image (sudo for the ext4 partition): what the release ships
#-----------------------------------------------------------------------------
image:
	@$(ECHO) "SD card image $(SDIMAGE)"
	firmware/common/scripts/make-sd-image.sh $(SDIMAGE) $(SDIMAGE_FAT) $(ROOTFS_DIR) $(SDIMAGE_FAT_MB) $(SDIMAGE_BOOT_FILES)
	xz -T0 -6 -k -f $(SDIMAGE)
	cd $(dir $(SDIMAGE)) && sha256sum $(notdir $(SDIMAGE)).xz > $(notdir $(SDIMAGE)).xz.sha256
	@ls -l $(SDIMAGE) $(SDIMAGE).xz

#-----------------------------------------------------------------------------
# write the image to a card
#
#   PLATFORM=<p> FLOW=rootfs SDCARD=/dev/sdX make write
#
#   SDCARD is the whole card (/dev/sdX or /dev/mmcblkN); it must be removable (or
#   USB/MMC) and must not be mounted. The whole card is overwritten after a confirmation.
#-----------------------------------------------------------------------------
write:
	@$(ECHO) "Write $(SDIMAGE) to the SD card"
	@set -e;																\
	dev="$(SDCARD)";														\
	if [ -z "$$dev" ]; then echo "ERROR: SDCARD is not set, e.g. SDCARD=/dev/sdX (see lsblk)"; exit 1; fi;	\
	if [ ! -f "$(SDIMAGE)" ]; then echo "ERROR: $(SDIMAGE) not found, run FLOW=rootfs make image first"; exit 1; fi;	\
	if [ ! -b "$$dev" ]; then echo "ERROR: $$dev is not a block device"; exit 1; fi;	\
	rm=$$(lsblk -dno RM "$$dev" | tr -d ' '); tran=$$(lsblk -dno TRAN "$$dev" | tr -d ' ');	\
	case "$$rm/$$tran/$$dev" in 1/*|*/usb/*|*/mmc/*|*/mmcblk*) ;;			\
		*) echo "ERROR: $$dev is neither removable nor USB/MMC (RM=$$rm TRAN=$$tran)"; exit 1 ;; esac;	\
	if lsblk -no MOUNTPOINT "$$dev" | grep -q .; then echo "ERROR: $$dev is mounted, unmount it first"; exit 1; fi;	\
	lsblk -o NAME,SIZE,TRAN,MODEL,FSTYPE,LABEL "$$dev";						\
	printf "Overwrite the whole card %s with the image of $(PLATFORM)? [y/N] " "$$dev"; read answer;	\
	[ "$$answer" = "y" ] || { echo "aborted"; exit 1; };					\
	sudo dd if="$(SDIMAGE)" of="$$dev" bs=4M conv=fsync status=progress;	\
	sync; echo "done, the card can be removed"

#-----------------------------------------------------------------------------
# write the image to the card in the running board (no card change): the board must
# take ssh root@$(BOARD_IP) with a key; SSH_KEYS keeps that login on the new card
#-----------------------------------------------------------------------------
SSH_KEYS		?= $(firstword $(wildcard $(HOME)/.ssh/id_ed25519.pub $(HOME)/.ssh/id_rsa.pub))

flash:
	@$(ECHO) "Write $(SDIMAGE) to the card of $(BOARD_IP)"
	@test -n "$(BOARD_IP)" || { echo "ERROR: BOARD_IP is not set"; exit 1; }
	firmware/common/scripts/flash-sd-over-network.sh $(BOARD_IP) $(SDIMAGE) $(ROOTFS_DIR)/usr/bin/busybox $(SSH_KEYS)

# Makefile ends here
