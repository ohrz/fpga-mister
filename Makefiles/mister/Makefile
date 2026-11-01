#-----------------------------------------------------------------------------
# File       : Makefile
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-28
#-----------------------------------------------------------------------------
# Description:
# FLOW=mister: Main_MiSTer for the board (Zynq backend from the patches in
# firmware/common/mister/patches/Main_MiSTer, cross compiler of the Vitis
# installation) and the MiSTer files of the rootfs: /media/fat (MiSTer, MiSTer.ini,
# the cores of the board as .rbf) and the systemd units that start Main_MiSTer.
#-----------------------------------------------------------------------------
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# Board profile, supported platforms, Vivado version (Makefiles/common.mk)
#-----------------------------------------------------------------------------
include $(dir $(lastword $(MAKEFILE_LIST)))../common.mk
include firmware/common/checkouts.mk

# board profile (platform.mk): MISTER_CORES <design>:<core>[:<folder>] (hw/bins/<design>.bit.bin of
# FLOW=vivado make build becomes /media/fat/<folder>/<core>.rbf, folder default _Computer, the core
# menu /media/fat/menu.rbf), MISTER_ROOTFS_FILES (optional
# directory of the board, copied to / of the rootfs, e.g. the codec setup); arch-<arch>.mk:
# MISTER_CROSS_COMPILE (prefix of the armhf cross compiler, on the PATH of settings64.sh)
MISTER_OUT		:= firmware/build/$(PLATFORM)/mister
MISTER_SRC		:= $(MISTER_OUT)/Main_MiSTer
MISTER_STAGE	:= $(MISTER_OUT)/rootfs
MISTER_TGZ		:= firmware/build/$(PLATFORM)/mister-rootfs.tgz
MISTER_BINS		:= firmware/build/$(PLATFORM)/$(VIVADO_VER)/hw/bins
MISTER_FILES	:= firmware/common/mister/files
# game images for the start media of the cores (not in Git, see .gitignore); empty for a release
MISTER_ROMS		?= roms

.PHONY: help setup build package clean

help::
	@echo 'FLOW=mister: Main_MiSTer for the board and the MiSTer files of the rootfs'
	@echo ''
	@echo '  PLATFORM=<platform> FLOW=mister make <action>'
	@echo '    setup      clone Main_MiSTer to _Checkouts (pin of firmware/common/checkouts.txt)'
	@echo '    build      patched copy in $(MISTER_OUT)/Main_MiSTer, make ZYNQ=1 -> $(MISTER_OUT)/MiSTer'
	@echo '    package    $(MISTER_STAGE)/media/fat (MiSTer, MiSTer.ini with video_mode=0, <folder>/<core>.rbf'
	@echo '               and menu.rbf of MISTER_CORES, games/<core>), the FAT partition of FLOW=rootfs make image;'
	@echo '               $(MISTER_TGZ): the systemd units, unpacked at / of the rootfs by FLOW=rootfs make build'
	@echo '    clean      remove $(MISTER_OUT)'
	@echo ''
	@echo '  MISTER_CORES=$(MISTER_CORES)   <design>:<core>[:<folder>], bitstreams from FLOW=vivado make build'
	@echo '  MISTER_ROMS=$(MISTER_ROMS)   game images for the start media (MSX: *.rom into games/MSX/boot.vhd), MISTER_ROMS= for none'
	@echo '  MISTER_CROSS_COMPILE=$(MISTER_CROSS_COMPILE)'
	@echo '  platforms: $(SUPPORTED_PLATFORMS)'

setup:
	$(CHECKOUT_SH) Main_MiSTer

#-----------------------------------------------------------------------------
# Main_MiSTer: copy of the pinned checkout with the patches of the port, cross build
#-----------------------------------------------------------------------------
build:
	@$(ECHO) "Build Main_MiSTer for $(PLATFORM)"
	$(CHECKOUT_SH) --check Main_MiSTer
	firmware/common/mister/scripts/prepare_sources.py Main_MiSTer $(call checkout_dir,Main_MiSTer) $(MISTER_SRC)
	$(MAKE) -C $(MISTER_SRC) ZYNQ=1 BASE=$(patsubst %-,%,$(MISTER_CROSS_COMPILE))
	@grep -aq "No MiSTer design in the PL" $(MISTER_SRC)/bin/MiSTer || \
		{ echo "ERROR: $(MISTER_SRC)/bin/MiSTer lacks the Zynq backend (patches not applied?)"; exit 1; }
	cp $(MISTER_SRC)/bin/MiSTer $(MISTER_OUT)/MiSTer
	@file $(MISTER_OUT)/MiSTer

#-----------------------------------------------------------------------------
# /media/fat (the FAT partition of the SD card image) and the rootfs files (systemd units,
# board files), owned by root in the archive
#-----------------------------------------------------------------------------
package:
	@$(ECHO) "Package the MiSTer files of $(PLATFORM)"
	@test -f $(MISTER_OUT)/MiSTer || { echo "ERROR: $(MISTER_OUT)/MiSTer missing, run FLOW=mister make build first"; exit 1; }
	@set -e; for c in $(MISTER_CORES); do test -f $(MISTER_BINS)/$${c%%:*}.bit.bin ||			\
		{ echo "ERROR: $(MISTER_BINS)/$${c%%:*}.bit.bin missing, run FLOW=vivado TOPLEVEL=$${c%%:*} make create build"; exit 1; }; done
	rm -rf $(MISTER_STAGE)
	mkdir -p $(MISTER_STAGE)/media/fat/config $(MISTER_STAGE)/etc/systemd/system
	cp $(MISTER_OUT)/MiSTer $(MISTER_STAGE)/media/fat/MiSTer

#	MiSTer.ini of Main_MiSTer with the fixed video mode of the PL (720p60, no EDID without ADV7513)
	sed 's/^;video_mode=0/video_mode=0/' $(MISTER_SRC)/MiSTer.ini > $(MISTER_STAGE)/media/fat/MiSTer.ini
	@test "$$(grep -c '^video_mode=0' $(MISTER_STAGE)/media/fat/MiSTer.ini)" = 1 ||			\
		{ echo "ERROR: MiSTer.ini: ;video_mode=0 not found once (upstream change?)"; exit 1; }

#	the cores: byte-swapped .bin of bootgen as .rbf (Main_MiSTer hands it to the fpga_manager);
#	the core menu becomes /media/fat/menu.rbf (Main_MiSTer loads it from there at start),
#	one games/<core> directory each (boot.rom, boot.vhd are mounted from there), filled by the
#	games.sh of the core profile when there is one (MSX: boot.vhd with the ROMs of MISTER_ROMS)
	@set -e; for c in $(MISTER_CORES); do															\
		design=$${c%%:*}; rest=$${c#*:}; core=$${rest%%:*}; folder=_Computer;						\
		[ "$$rest" = "$$core" ] || folder=$${rest#*:};												\
		profile=firmware/common/mister/cores/$$(echo $$core | tr A-Z a-z);							\
		if [ "$$core" = menu ]; then																\
			echo "$(MISTER_BINS)/$$design.bit.bin -> /media/fat/menu.rbf";							\
			cp $(MISTER_BINS)/$$design.bit.bin $(MISTER_STAGE)/media/fat/menu.rbf; continue;		\
		fi;																							\
		echo "$(MISTER_BINS)/$$design.bit.bin -> /media/fat/$$folder/$$core.rbf";					\
		mkdir -p $(MISTER_STAGE)/media/fat/$$folder $(MISTER_STAGE)/media/fat/games/$$core;		\
		cp $(MISTER_BINS)/$$design.bit.bin $(MISTER_STAGE)/media/fat/$$folder/$$core.rbf;			\
		if [ -x $$profile/games.sh ]; then $$profile/games.sh $(MISTER_STAGE)/media/fat/games/$$core $(MISTER_ROMS); fi;	\
	done

	cp $(MISTER_FILES)/rootfs/mister.service $(MISTER_FILES)/rootfs/usr-lib-firmware-mister.mount $(MISTER_STAGE)/etc/systemd/system/
	$(if $(MISTER_ROOTFS_FILES),cp -r firmware/targets/$(PLATFORM)/$(MISTER_ROOTFS_FILES)/. $(MISTER_STAGE)/)

#	every service is enabled (all of them are WantedBy=multi-user.target)
	mkdir -p $(MISTER_STAGE)/etc/systemd/system/multi-user.target.wants
	@set -e; for s in $(MISTER_STAGE)/etc/systemd/system/*.service; do						\
		echo "enable $$(basename $$s)";															\
		ln -sf ../$$(basename $$s) $(MISTER_STAGE)/etc/systemd/system/multi-user.target.wants/;	\
	done

#	the rootfs files without /media/fat (the FAT partition); no ./ entry and no group/other
#	write bits: unpacking at / must not change the modes of / and /etc
	tar -czf $(MISTER_TGZ) --owner=0 --group=0 --mode='u+rwX,go+rX,go-w' -C $(MISTER_STAGE) $$(ls $(MISTER_STAGE) | grep -vx media)
	@$(ECHO) "$(MISTER_STAGE)/media/fat: FAT partition (FLOW=rootfs make image)"
	@$(ECHO) "$(MISTER_TGZ): unpacked at / of the rootfs by FLOW=rootfs make build"

clean:
	rm -rf $(MISTER_OUT) $(MISTER_TGZ)

# Makefile ends here
