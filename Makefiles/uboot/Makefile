#-----------------------------------------------------------------------------
# File       : Makefile
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2023-12-20
# Last update: 2026-05-03
# Platform   : 
#-----------------------------------------------------------------------------
# Description:
# Install:
# 	sudo apt install u-boot-tools
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
# U-Boot configuration: defconfig + firmware/targets/<platform>/files/uboot.config
# (merge_config.sh), no menuconfig; MENUCONFIG=1 opens it afterwards (changes
# there are not saved in the fragment). Board profile (platform.mk): UBOOT_ENV,
# UBOOT_DEFCONFIG, UBOOT_DEVICE_TREE, UBOOT_DTS_FILES (dts/ files copied into
# arch/arm/dts before the build), UBOOT_PATCHES (applied once by checkout)
#-----------------------------------------------------------------------------
UBOOT_DIR		:= firmware/build/$(PLATFORM)/$(VIVADO_VER)/u-boot-xlnx
UBOOT_FRAGMENT	:= firmware/targets/$(PLATFORM)/files/uboot.config

#-----------------------------------------------------------------------------
# Help
#-----------------------------------------------------------------------------
.PHONY: help

help::
	@echo 'FLOW=uboot: u-boot-xlnx (tag xilinx-v<version>), used for the boot flow on the Zynq-7000 boards'
	@echo ''
	@echo '  PLATFORM=<platform> FLOW=uboot make <action>'
	@echo '    checkout   clone u-boot-xlnx to firmware/build/<platform>/<version>/u-boot-xlnx'
	@echo '    build      defconfig + files/uboot.config, make'
	@echo '    clean      remove the u-boot-xlnx tree'
	@echo ''
	@echo '  MENUCONFIG=1   open menuconfig after the fragment (changes are not saved in it)'
	@echo '  platforms: $(SUPPORTED_PLATFORMS)'

#-----------------------------------------------------------------------------
# Linux U-Boot Checkout
#-----------------------------------------------------------------------------
checkout:
	@$(ECHO) "Checkout Linux U-Boot"

	if [ -d "firmware/build/$(PLATFORM)/$(VIVADO_VER)/u-boot-xlnx" ]; then \
		echo "u-boot-xlnx is already checked out"; 		\
	else												\
		mkdir -p firmware/build/$(PLATFORM)/$(VIVADO_VER) &&	\
		cd firmware/build/$(PLATFORM)/$(VIVADO_VER) &&	\
		git clone -b xilinx-v$(VIVADO_VER) --single-branch --depth 1 https://github.com/Xilinx/u-boot-xlnx.git &&	\
		cd u-boot-xlnx &&								\
		git switch -c xilinx-v$(VIVADO_VER);			\
	fi

ifneq ($(UBOOT_DTS_FILES),)
	cp $(addprefix firmware/targets/$(PLATFORM)/,$(UBOOT_DTS_FILES)) $(UBOOT_DIR)/arch/arm/dts/
endif
ifneq ($(UBOOT_PATCHES),)
	@$(ECHO) "	Board patches (only once, checkout may be run again)"
	@$(call apply_patches_once,$(UBOOT_DIR),$(addprefix $(CURDIR)/firmware/targets/$(PLATFORM)/,$(UBOOT_PATCHES)))
endif

#-----------------------------------------------------------------------------
# Linux U-Boot Build
#-----------------------------------------------------------------------------
build:
	@$(ECHO) "Build Linux U-Boot"
	test -f $(UBOOT_DIR)/Makefile || { echo "ERROR: $(UBOOT_DIR) missing, run FLOW=uboot make checkout"; exit 1; }
ifneq ($(UBOOT_DTS_FILES),)
#	board DTS into the tree (build needs: sudo apt install libgnutls28-dev uuid-dev)
	cp $(addprefix firmware/targets/$(PLATFORM)/,$(UBOOT_DTS_FILES))	$(UBOOT_DIR)/arch/arm/dts/
endif

	@$(ECHO) "(1) make $(UBOOT_DEFCONFIG)"
	$(UBOOT_ENV) make $(UBOOT_DEFCONFIG)									-C $(UBOOT_DIR)

	@$(ECHO) "(2) merge $(UBOOT_FRAGMENT)"
	$(call merge_fragment,$(UBOOT_DIR),$(UBOOT_ENV),$(UBOOT_FRAGMENT))

ifeq ($(MENUCONFIG),1)
	@$(ECHO) "    MENUCONFIG=1: changes are not saved in $(UBOOT_FRAGMENT)"
	$(UBOOT_ENV) make menuconfig												-C $(UBOOT_DIR)
endif

	@$(ECHO) "(3) make"
	$(UBOOT_ENV) DEVICE_TREE="$(UBOOT_DEVICE_TREE)" make -j$(shell nproc)		-C $(UBOOT_DIR)

#-----------------------------------------------------------------------------
# Linux U-Boot Clean
#-----------------------------------------------------------------------------
clean:
	@$(ECHO) "Clean Linux U-Boot"
	rm -rf firmware/build/$(PLATFORM)/$(VIVADO_VER)/u-boot-xlnx
