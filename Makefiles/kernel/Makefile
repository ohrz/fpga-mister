#-----------------------------------------------------------------------------
# File       : Makefile
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2023-12-20
# Last update: 2024-08-23
# Platform   : 
#-----------------------------------------------------------------------------
# Description:
# Install this software:
# - sudo apt install flex bison libssl-dev debhelper
# 
#-----------------------------------------------------------------------------
# Copyright (c) 2021-2024 by OHRZ
#-----------------------------------------------------------------------------
# Revisions  :
# Date        Version  Author          Description
# 2023-12-20  1.0      Konstantin      Created
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# Board profile, supported platforms, Vivado version (Makefiles/common.mk)
#-----------------------------------------------------------------------------
include $(dir $(lastword $(MAKEFILE_LIST)))../common.mk

#-----------------------------------------------------------------------------
# Board profile (platform.mk): KERNEL_ARCH, KERNEL_CROSS_COMPILE, KERNEL_DEBARCH,
# KERNEL_XILINX_DEFCONFIG, KERNEL_XILINX_DEVICE_TREE, KERNEL_DTB (board DTB
# collected with the Image), KERNEL_DTS_FILES (dts/ files copied into the tree
# before every build), KERNEL_PATCHES (applied once by make patch)
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# Kernel output: Image and the packages of the same build. boot (Image) and
# rootfs (packages) take the kernel only from here, so the booted kernel
# always matches the installed modules and headers.
#-----------------------------------------------------------------------------
KERNEL_DIR		:= firmware/build/$(PLATFORM)/$(VIVADO_VER)/linux-xlnx
KERNEL_OUT		:= firmware/build/$(PLATFORM)/$(VIVADO_VER)/kernel
KERNEL_IMAGES	:= $(if $(filter arm,$(KERNEL_ARCH)),Image zImage,Image)
KERNEL_DTS_DIR	:= $(KERNEL_DIR)/arch/$(KERNEL_ARCH)/boot/dts/xilinx

# options merged on top of the defconfig (no interactive menuconfig);
# MENUCONFIG=1 opens menuconfig afterwards, changes there are not saved
# config fragments: the common one (UIO as module) and, if present, the board's
KERNEL_FRAGMENTS	:= firmware/common/linux/kernel.config $(wildcard firmware/targets/$(PLATFORM)/files/kernel.config)

#-----------------------------------------------------------------------------
# Help
#-----------------------------------------------------------------------------
.PHONY: help

help::
	@echo 'FLOW=kernel: linux-xlnx (tag xilinx-v<version>) as Debian packages'
	@echo ''
	@echo '  PLATFORM=<platform> FLOW=kernel make <action>'
	@echo '    build      checkout, patch, defconfig + common/linux/kernel.config (+ files/kernel.config), bindeb-pkg, collect'
	@echo '    checkout   clone linux-xlnx to firmware/build/<platform>/<version>/linux-xlnx'
	@echo '    patch      platform DTS/patches into the tree'
	@echo '    collect    Image, board DTB + packages of the last build to firmware/build/<platform>/<version>/kernel'
	@echo '    clean      remove the linux-xlnx tree (kernel/ and the packages stay)'
	@echo ''
	@echo '  MENUCONFIG=1   open menuconfig after the fragment (changes are not saved in it)'
	@echo '  platforms: $(SUPPORTED_PLATFORMS)'

#-----------------------------------------------------------------------------
# Linux Kernel build
#-----------------------------------------------------------------------------
build:	\
firmware/build/$(PLATFORM)/$(VIVADO_VER)/linux-xlnx/Makefile	\
firmware/build/$(PLATFORM)/$(VIVADO_VER)/linux-xlnx/.patched

	@$(ECHO) "Build Linux Kernel"

ifneq ($(KERNEL_DTS_FILES),)
#	board DTS files of dts/ into the tree (every build, so edits are picked up)
	cp $(addprefix firmware/targets/$(PLATFORM)/,$(KERNEL_DTS_FILES)) $(KERNEL_DTS_DIR)/
endif

	@$(ECHO) "(0a) common kernel patches (firmware/common/linux/patches), each applied once"
	@$(call apply_patches_once,$(KERNEL_DIR),$(sort $(wildcard $(CURDIR)/firmware/common/linux/patches/*.patch)))

	@$(ECHO) "(0) Set version to 0"
	cd firmware/build/$(PLATFORM)/$(VIVADO_VER)/linux-xlnx;									\
	echo "0" > .version

	@$(ECHO) "(1) make defconfig"
	CROSS_COMPILE=$(KERNEL_CROSS_COMPILE) ARCH=$(KERNEL_ARCH) make $(KERNEL_XILINX_DEFCONFIG) 	-C firmware/build/$(PLATFORM)/$(VIVADO_VER)/linux-xlnx

	@$(ECHO) "(2) merge $(KERNEL_FRAGMENTS)"
	$(call merge_fragment,$(KERNEL_DIR),CROSS_COMPILE=$(KERNEL_CROSS_COMPILE) ARCH=$(KERNEL_ARCH),$(KERNEL_FRAGMENTS))

ifeq ($(MENUCONFIG),1)
	@$(ECHO) "    MENUCONFIG=1: changes are not saved in $(KERNEL_FRAGMENTS)"
	CROSS_COMPILE=$(KERNEL_CROSS_COMPILE) ARCH=$(KERNEL_ARCH) make menuconfig					-C $(KERNEL_DIR)
endif

	@$(ECHO) "(3) make bindeb-pkg"

	CROSS_COMPILE=$(KERNEL_CROSS_COMPILE) ARCH=$(KERNEL_ARCH) DEVICE_TREE=$(KERNEL_XILINX_DEVICE_TREE) KBUILD_DEBARCH=$(KERNEL_DEBARCH) KBUILD_DEB_FLAGS="-d" DPKG_FLAGS="-d"	make -j$(shell nproc) bindeb-pkg  	-C firmware/build/$(PLATFORM)/$(VIVADO_VER)/linux-xlnx

	@$(ECHO) "(4) collect Image and packages"
	$(MAKE) -f Makefiles/kernel/Makefile collect

#-----------------------------------------------------------------------------
# Collect Image, the board DTB and the packages of the same build in $(KERNEL_OUT)
#   packages of this build = the .deb files newer than the Image (bindeb-pkg
#   writes them after the Image); the linux-image package must carry the
#   modules of the Image's kernel release. boot and rootfs take the kernel
#   (Image, DTB, packages) only from here.
#-----------------------------------------------------------------------------
.PHONY: collect

collect:
	@set -e;																\
	img=$(KERNEL_DIR)/arch/$(KERNEL_ARCH)/boot/Image;						\
	rel=$$(cat $(KERNEL_DIR)/include/config/kernel.release);				\
	dtb=$(KERNEL_DIR)/arch/$(KERNEL_ARCH)/boot/dts/xilinx/$(KERNEL_DTB);		\
	[ -f $$dtb ] || { echo "ERROR: $$dtb missing (DTB not built?)"; exit 1; };	\
	debs=$$(find firmware/build/$(PLATFORM)/$(VIVADO_VER) -maxdepth 1 -name '*.deb' -newer $$img);	\
	pkg=$$(ls -t firmware/build/$(PLATFORM)/$(VIVADO_VER)/linux-image-$${rel}_*.deb 2>/dev/null | head -1);	\
	if [ -z "$$pkg" ] || ! echo "$$debs" | grep -qF "$$pkg"; then				\
		echo "ERROR: no linux-image package for $$rel built after $$img";		\
		echo "       (Image rebuilt without bindeb-pkg?), run FLOW=kernel make build";	\
		exit 1;																\
	fi;																		\
	dpkg-deb -c $$pkg | grep "/lib/modules/$$rel/" > /dev/null ||						\
		{ echo "ERROR: $$pkg has no modules for $$rel"; exit 1; };			\
	rm -rf $(KERNEL_OUT);													\
	mkdir -p $(KERNEL_OUT);													\
	cp $$debs $(KERNEL_OUT)/;												\
	for f in $(KERNEL_IMAGES); do cp $(KERNEL_DIR)/arch/$(KERNEL_ARCH)/boot/$$f $(KERNEL_OUT)/; done;	\
	cp $$dtb $(KERNEL_OUT)/;												\
	echo "$$rel" > $(KERNEL_OUT)/kernel.release;							\
	echo "Kernel $$rel in $(KERNEL_OUT):"; ls $(KERNEL_OUT)

#-----------------------------------------------------------------------------
# FLOW=kernel make checkout|patch
#-----------------------------------------------------------------------------
.PHONY: checkout patch

checkout: firmware/build/$(PLATFORM)/$(VIVADO_VER)/linux-xlnx/Makefile

patch: firmware/build/$(PLATFORM)/$(VIVADO_VER)/linux-xlnx/.patched

#-----------------------------------------------------------------------------
# Linux Kernel checkout
#-----------------------------------------------------------------------------
firmware/build/$(PLATFORM)/$(VIVADO_VER)/linux-xlnx/Makefile:
	@$(ECHO) "Checkout Linux Kernel"

	if [ -d "firmware/build/$(PLATFORM)/$(VIVADO_VER)/linux-xlnx" ]; then \
		echo "linux-xlnx is already checked out"; \
	else \
		mkdir -p firmware/build/$(PLATFORM)/$(VIVADO_VER);								\
		cd firmware/build/$(PLATFORM)/$(VIVADO_VER);									\
		git clone -b xilinx-v$(VIVADO_VER) --single-branch --depth 1 https://github.com/Xilinx/linux-xlnx.git;		\
		cd linux-xlnx;													\
		git switch -c xilinx-v$(VIVADO_VER);										\
	fi

#-----------------------------------------------------------------------------
# Linux Kernel patch
#-----------------------------------------------------------------------------
firmware/build/$(PLATFORM)/$(VIVADO_VER)/linux-xlnx/.patched:	\
firmware/build/$(PLATFORM)/$(VIVADO_VER)/linux-xlnx/Makefile
	@$(ECHO) "Patch Linux Kernel"
ifneq ($(KERNEL_DTS_FILES),)
	@$(ECHO) "	Copy DTS to linux kernel"
	cp $(addprefix firmware/targets/$(PLATFORM)/,$(KERNEL_DTS_FILES)) $(KERNEL_DTS_DIR)/
endif
ifneq ($(KERNEL_PATCHES),)
	@$(ECHO) "	Board patches (only once, the tree may already carry them)"
	@$(call apply_patches_once,$(KERNEL_DIR),$(addprefix $(CURDIR)/firmware/targets/$(PLATFORM)/,$(KERNEL_PATCHES)))
endif

	@$(ECHO) "(3) Marking as patched"
	cd firmware/build/$(PLATFORM)/$(VIVADO_VER)/linux-xlnx;									\
	touch .patched
	
#-----------------------------------------------------------------------------
# Linux Kernel clean: the source tree only; the collected kernel/ (Image, DTB,
# packages) and the .deb files next to the tree stay
#-----------------------------------------------------------------------------
.PHONY: clean

clean:
	@$(ECHO) "Clean Linux Kernel"
	rm -rf firmware/build/$(PLATFORM)/$(VIVADO_VER)/linux-xlnx

# Makefile ends here
