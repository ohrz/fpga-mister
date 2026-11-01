#-----------------------------------------------------------------------------
# File       : Makefile
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-29
#-----------------------------------------------------------------------------
# Description:
# GHDL testbenches of the HDMI transmitter (firmware/common/ip/hdmi-tx/src).
#   make -C firmware/common/ip/hdmi-tx/tb            every bench, PASS/FAIL per bench
#   make -C firmware/common/ip/hdmi-tx/tb <bench>    one bench (e.g. hdmi_tx_fast_tb)
#   make -C firmware/common/ip/hdmi-tx/tb vhdl93     the synthesis sources as VHDL-93: Vivado reads
#                                                    .vhd files of a project as VHDL-93, the benches
#                                                    run as VHDL-2008 and would not notice
# Work libraries go to WORK (default firmware/build/tb/hdmi-tx of the repository the
# component lies in; not tracked).  hdmi_out needs the unisim component declarations
# (OSERDESE2, OBUFDS) of the Vivado installation (UNISIM_SRC, default
# $XILINX_VIVADO/data/vhdl/src/unisims); without them vhdl93 is NOT RUN.  There is no OSERDESE2 model: the serializer is checked on
# hardware only (README.md).
#-----------------------------------------------------------------------------
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------

GHDL		?= ghdl
GHDL_FLAGS	:= --std=08 -frelaxed -Wno-shared
SRC			:= ../src
# repository root = five levels up (firmware/common/ip/hdmi-tx/tb)
ROOT		:= $(abspath $(CURDIR)/../../../../..)
WORK		?= $(ROOT)/firmware/build/tb/hdmi-tx
UNISIM_SRC	?= $(XILINX_VIVADO)/data/vhdl/src/unisims

# synthesis sources in analysis order
CORE_SRC	:= $(SRC)/hdmi_pkg.vhd $(SRC)/i2s_rx.vhd $(SRC)/tmds_enc.vhd $(SRC)/hdmi_audio.vhd $(SRC)/hdmi_tx.vhd
VHDL93_SRC	:= $(CORE_SRC) $(SRC)/hdmi_out.vhd

# hdmi_tx_tb.vhd holds the bench and its variants (entities with other generics):
#   hdmi_tx_neg_tb    active-low hsync
#   hdmi_tx_fast_tb   8 times the audio rate (several samples per packet, samples in the load clock)
#   hdmi_tx_short_tb  blanking too short for a data island (no island, video still right)
BENCHES		:= hdmi_tx_tb hdmi_tx_neg_tb hdmi_tx_fast_tb hdmi_tx_short_tb

.PHONY: all vhdl93 $(BENCHES)
all: vhdl93 $(BENCHES)

vhdl93:
	@[ -f "$(UNISIM_SRC)/unisim_VCOMP.vhd" ] || { echo "$@: NOT RUN (no unisim sources in $(UNISIM_SRC))"; exit 0; }; \
	rm -rf $(WORK)/$@ && mkdir -p $(WORK)/$@ && \
	$(GHDL) -a --std=93c -frelaxed --work=unisim --workdir=$(WORK)/$@ $(UNISIM_SRC)/unisim_VPKG.vhd \
		$(UNISIM_SRC)/unisim_VCOMP.vhd > $(WORK)/$@/unisim.log 2>&1 && \
	if $(GHDL) -a --std=93c --workdir=$(WORK)/$@ -P$(WORK)/$@ $(VHDL93_SRC) > $(WORK)/$@/run.log 2>&1; then \
		echo "$@: PASS"; \
	else grep -E "error" $(WORK)/$@/run.log; echo "$@: FAIL (log $(WORK)/$@/run.log)"; exit 1; fi

$(BENCHES):
	@mkdir -p $(WORK)/$@ && \
	$(GHDL) -a $(GHDL_FLAGS) --workdir=$(WORK)/$@ $(CORE_SRC) hdmi_tx_tb.vhd && \
	{ $(GHDL) -r $(GHDL_FLAGS) --workdir=$(WORK)/$@ $@ --assert-level=error 2>&1 | tee $(WORK)/$@/run.log | grep -E "PASS|FAIL|error|failure" ; \
	grep -q "PASS" $(WORK)/$@/run.log && echo "$@: PASS" || { echo "$@: FAIL (log $(WORK)/$@/run.log)"; exit 1; }; }
