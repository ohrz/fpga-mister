#-----------------------------------------------------------------------------
# File       : Makefile
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-28
#-----------------------------------------------------------------------------
# Description:
# Dispatcher: PLATFORM=<platform> FLOW=<flow> [TOPLEVEL=<design>] make <action> forwards
# <action> to Makefiles/<flow>/Makefile; without FLOW: help, test (self-check), status, lab.
#-----------------------------------------------------------------------------
# Copyright (c) 2021-2026 by OHRZ
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# Vivado version (Makefiles/common.mk)
#-----------------------------------------------------------------------------
include Makefiles/common.mk


#-----------------------------------------------------------------------------
# Help
#-----------------------------------------------------------------------------
.PHONY: help

help::
ifneq ($(FLOW),)
	@$(MAKE) -s -f Makefiles/$(FLOW)/Makefile help
else
	@echo 'Usage: PLATFORM=<platform> FLOW=<flow> [TOPLEVEL=<design>] make <action>'
	@echo '       FLOW=<flow> make help     actions and variables of one flow'
	@echo ''
	@echo '  vivado     create build xsa-export launch setup clean'
	@echo '  kernel     build checkout patch collect clean'
	@echo '  uboot      checkout build clean'
	@echo '  boot       copy clean tftpboot'
	@echo '  rootfs     build image write flash package clean (rootfs, SD card image)'
	@echo '  mister     setup build package clean (Main_MiSTer, /media/fat)'
	@echo ''
	@echo '  Without FLOW: test (hardware-free self-check: scripts, make -n of every flow x board x action, VHDL testbenches),'
	@echo '                status (matrix core x board x stage from the STATUS.md files; status-update writes it into README.md)'
	@echo '                hwtest CORE=<core> [COMMIT=<c>] (core with its game on the board: load and speed, picture and sound on the HDMI monitor; firmware/common/mister/cores/<core>/hwtest.cfg)'
	@echo '                build-matrix [BOARDS=..] [CORES=..] [UPDATE=1] [REPORT_ONLY=1] [DRY_RUN=1] (build every board x core design, timing rows for STATUS.md)'
	@echo '                lab (addresses and hosts of the lab: firmware/common/lab.mk, overrides in lab.local.mk)'
	@echo '  Vivado version from XILINX_VIVADO (source <Xilinx>/<version>/Vivado/settings64.sh).'
endif

#-----------------------------------------------------------------------------
# Dispatch: a flow action goes to Makefiles/$(FLOW)/Makefile
#
#   vivado     create build xsa-export launch setup clean
#   kernel     build checkout patch collect clean
#   uboot      checkout build clean
#   boot       copy clean tftpboot
#   rootfs     build image write flash package clean
#   mister     setup build package clean
#-----------------------------------------------------------------------------
FLOWS			:= $(patsubst Makefiles/%/Makefile,%,$(wildcard Makefiles/*/Makefile))
FLOW_ACTIONS	:= create build xsa-export launch setup checkout patch collect	\
				   copy clean tftpboot package write image flash

.PHONY: $(FLOW_ACTIONS) test lab status status-update hwtest build-matrix

# status: what works where (firmware/common/mister/cores/*/STATUS.md, firmware/targets/*/STATUS.md)
status:
	@python3 firmware/common/mister/scripts/status.py

status-update:
	@python3 firmware/common/mister/scripts/status.py --update README.md

# hwtest: load CORE with its game on the board and check picture, sound and speed
# (firmware/common/mister/cores/$(CORE)/hwtest.cfg); COMMIT= the bitstream was built from
hwtest:
	@test -n "$(CORE)" || { echo "CORE must be set (a directory with hwtest.cfg in firmware/common/mister/cores)"; exit 1; }
	python3 firmware/common/mister/tools/hwtest.py $(CORE) --platform $(or $(PLATFORM),zybo-z7-20) \
		--board $(LAB_BOARD_IP_$(or $(PLATFORM),zybo-z7-20)) $(if $(COMMIT),--commit $(COMMIT))

# build-matrix: build every board x core design (nightly) and evaluate timing and utilization
# (firmware/common/mister/scripts/build_matrix.py; BOARDS=, CORES= restrict it, UPDATE=1 writes the
# timing rows into cores/<core>/STATUS.md, REPORT_ONLY=1 reads the reports that are there, DRY_RUN=1)
build-matrix:
	python3 firmware/common/mister/scripts/build_matrix.py --video $(or $(VIDEO),hdmi) --mem $(or $(MEM),24G) \
		$(foreach b,$(BOARDS),--board $(b)) $(foreach c,$(CORES),--core $(c)) $(if $(UPDATE),--update) \
		$(if $(REPORT_ONLY),--report-only) $(if $(DRY_RUN),--dry-run) $(if $(COMMIT),--commit $(COMMIT))

# lab: the addresses and hosts the flows use (firmware/common/lab.mk, lab.local.mk)
lab:
	@$(foreach v,$(sort $(filter LAB_%,$(.VARIABLES))),printf '%-26s %s\n' '$(v)' '$($(v))';)
	@test -f lab.local.mk && echo "(overrides from lab.local.mk)" || echo "(defaults of firmware/common/lab.mk; override in lab.local.mk)"

$(FLOW_ACTIONS):
	@test -n "$(FLOW)" -a -f Makefiles/$(FLOW)/Makefile || { echo "FLOW must be one of: $(FLOWS)"; exit 1; }
	$(MAKE) -f Makefiles/$(FLOW)/Makefile $@

# test: the flow's test with FLOW, the hardware-free self-check of the repository without
test:
ifeq ($(FLOW),)
	firmware/common/scripts/selfcheck.sh
else
	$(MAKE) -f Makefiles/$(FLOW)/Makefile $@
endif

# Makefile ends here

