#-----------------------------------------------------------------------------
# File       : Makefile
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-26
#-----------------------------------------------------------------------------
# Description:
# GHDL testbenches of the own VHDL of the KR260 target (hdl/kr260_dp_live.vhd,
# hdl/kr260_dp_audio.vhd with i2s_rx of hdmi-tx).
#   make -C firmware/targets/kr260/tb            the DUTs as VHDL-93, every case, PASS/FAIL
#   make -C firmware/targets/kr260/tb <case>     one case (for example order1, audio3)
#   make ... DUT=<file> WORK=<dir>               another copy of kr260_dp_live (mutation test)
#   make ... AUD_DUT=<file> WORK=<dir>           another copy of kr260_dp_audio (mutation test)
# Work libraries go to firmware/build/tb/kr260 (not tracked).
#-----------------------------------------------------------------------------
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------

GHDL		?= ghdl
GHDL_FLAGS	:= --std=08 -frelaxed
DUT			?= ../hdl/kr260_dp_live.vhd
TB			:= kr260_dp_live_tb.vhd
AUD_DUT		?= ../hdl/kr260_dp_audio.vhd
AUD_TB		:= kr260_dp_audio_tb.vhd
I2S_RX		:= ../../../common/ip/hdmi-tx/src/i2s_rx.vhd
WORK		?= ../../../build/tb/kr260

# case: generics of the bench
CASES		:= order0 order1 order2 sync_inv
order0_G	:= -gG_ORDER=0
order1_G	:= -gG_ORDER=1
order2_G	:= -gG_ORDER=2
sync_inv_G	:= -gG_ORDER=0 -gG_HS_INV=true -gG_VS_INV=true
# audio cases: G_CASE of kr260_dp_audio_tb (0 I2S, 1 tone, 2 tone with tid 0 and preamble 0, 3 drops)
AUD_CASES	:= audio0 audio1 audio2 audio3

.PHONY: all vhdl93 analyse analyse_audio $(CASES) $(AUD_CASES)
all: vhdl93
	@fails=0; for c in $(CASES) $(AUD_CASES); do $(MAKE) --no-print-directory $$c || fails=$$((fails+1)); done; \
	if [ $$fails -eq 0 ]; then echo "kr260 tb: PASS"; else echo "kr260 tb: FAIL ($$fails cases)"; exit 1; fi

# Vivado reads .vhd as VHDL-93
vhdl93:
	@mkdir -p $(WORK)/vhdl93 && \
	if $(GHDL) -a --std=93c --workdir=$(WORK)/vhdl93 $(DUT) $(I2S_RX) $(AUD_DUT) > $(WORK)/vhdl93/run.log 2>&1; then echo "vhdl93: PASS"; \
	else cat $(WORK)/vhdl93/run.log; echo "vhdl93: FAIL"; exit 1; fi

analyse:
	@mkdir -p $(WORK) && $(GHDL) -a $(GHDL_FLAGS) --workdir=$(WORK) $(DUT) $(TB) && \
	$(GHDL) -e $(GHDL_FLAGS) --workdir=$(WORK) kr260_dp_live_tb

$(CASES): analyse
	@$(GHDL) -r $(GHDL_FLAGS) --workdir=$(WORK) kr260_dp_live_tb $($@_G) > $(WORK)/$@.log 2>&1; \
	grep -E "ERROR|error|failure" $(WORK)/$@.log | head -20; \
	if grep -q ": PASS" $(WORK)/$@.log; then echo "$@: PASS"; else echo "$@: FAIL (log $(WORK)/$@.log)"; exit 1; fi

analyse_audio:
	@mkdir -p $(WORK)/audio && $(GHDL) -a $(GHDL_FLAGS) --workdir=$(WORK)/audio $(I2S_RX) $(AUD_DUT) $(AUD_TB) && \
	$(GHDL) -e $(GHDL_FLAGS) --workdir=$(WORK)/audio kr260_dp_audio_tb

$(AUD_CASES): analyse_audio
	@$(GHDL) -r $(GHDL_FLAGS) --workdir=$(WORK)/audio kr260_dp_audio_tb -gG_CASE=$(subst audio,,$@) > $(WORK)/$@.log 2>&1; \
	grep -E "ERROR|error|failure" $(WORK)/$@.log | head -20; \
	if grep -q ": PASS" $(WORK)/$@.log; then echo "$@: PASS"; else echo "$@: FAIL (log $(WORK)/$@.log)"; exit 1; fi
