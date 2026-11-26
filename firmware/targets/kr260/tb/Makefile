#-----------------------------------------------------------------------------
# File       : Makefile
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-26
#-----------------------------------------------------------------------------
# Description:
# GHDL testbench of the own VHDL of the KR260 target (hdl/kr260_dp_live.vhd).
#   make -C firmware/targets/kr260/tb            the DUT as VHDL-93, every case, PASS/FAIL
#   make -C firmware/targets/kr260/tb <case>     one case (for example order1)
#   make ... DUT=<file> WORK=<dir>               another copy of the DUT (mutation test)
# Work libraries go to firmware/build/tb/kr260 (not tracked).
#-----------------------------------------------------------------------------
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------

GHDL		?= ghdl
GHDL_FLAGS	:= --std=08 -frelaxed
DUT			?= ../hdl/kr260_dp_live.vhd
TB			:= kr260_dp_live_tb.vhd
WORK		?= ../../../build/tb/kr260

# case: generics of the bench
CASES		:= order0 order1 order2 sync_inv
order0_G	:= -gG_ORDER=0
order1_G	:= -gG_ORDER=1
order2_G	:= -gG_ORDER=2
sync_inv_G	:= -gG_ORDER=0 -gG_HS_INV=true -gG_VS_INV=true

.PHONY: all vhdl93 analyse $(CASES)
all: vhdl93
	@fails=0; for c in $(CASES); do $(MAKE) --no-print-directory $$c || fails=$$((fails+1)); done; \
	if [ $$fails -eq 0 ]; then echo "kr260 tb: PASS"; else echo "kr260 tb: FAIL ($$fails cases)"; exit 1; fi

# Vivado reads .vhd as VHDL-93
vhdl93:
	@mkdir -p $(WORK)/vhdl93 && \
	if $(GHDL) -a --std=93c --workdir=$(WORK)/vhdl93 $(DUT) > $(WORK)/vhdl93/run.log 2>&1; then echo "vhdl93: PASS"; \
	else cat $(WORK)/vhdl93/run.log; echo "vhdl93: FAIL"; exit 1; fi

analyse:
	@mkdir -p $(WORK) && $(GHDL) -a $(GHDL_FLAGS) --workdir=$(WORK) $(DUT) $(TB) && \
	$(GHDL) -e $(GHDL_FLAGS) --workdir=$(WORK) kr260_dp_live_tb

$(CASES): analyse
	@$(GHDL) -r $(GHDL_FLAGS) --workdir=$(WORK) kr260_dp_live_tb $($@_G) > $(WORK)/$@.log 2>&1; \
	grep -E "ERROR|error|failure" $(WORK)/$@.log | head -20; \
	if grep -q ": PASS" $(WORK)/$@.log; then echo "$@: PASS"; else echo "$@: FAIL (log $(WORK)/$@.log)"; exit 1; fi
