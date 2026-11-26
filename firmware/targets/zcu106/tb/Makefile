#-----------------------------------------------------------------------------
# File       : Makefile
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-07
#-----------------------------------------------------------------------------
# Description:
# GHDL testbench of the own VHDL of the ZCU106 target (hdl/zcu106_hdmi_ctl.vhd with the
# generic i2c_bit_engine of firmware/common/mister/hdl, tested here through it).
#   make -C firmware/targets/zcu106/tb            selftest of si5324_regs.py, the
#                                                 DUT as VHDL-93, every case, PASS/FAIL
#   make -C firmware/targets/zcu106/tb <case>     one case (e.g. nack_first)
#   make ... DUT=<file> WORK=<dir>                another copy of the DUT (mutation probe)
# Work libraries go to firmware/build/tb/zcu106 (not tracked).
#-----------------------------------------------------------------------------
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------

GHDL		?= ghdl
GHDL_FLAGS	:= --std=08 -frelaxed -Wno-shared
DUT			?= ../hdl/zcu106_hdmi_ctl.vhd
# the generic part of the DUT (firmware/common/mister/hdl), analysed before it
ENGINE		?= ../../../common/mister/hdl/i2c_bit_engine.vhd
TB			:= zcu106_hdmi_ctl_tb.vhd
WORK		?= ../../../build/tb/zcu106
PYTHON		?= python3

# case: G_CASE of the bench plus extra generics
CASES		:= normal normal_late fast_clk nack_first nack_always lol_stuck bad_id stretch scl_stuck
normal_G		:= -gG_CASE=normal
normal_late_G	:= -gG_CASE=normal -gG_TX_EN_FIRST=false
fast_clk_G		:= -gG_CASE=normal -gG_CLK_HZ=1200000 -gG_I2C_HZ=25000
nack_first_G	:= -gG_CASE=nack_first
nack_always_G	:= -gG_CASE=nack_always
lol_stuck_G		:= -gG_CASE=lol_stuck
bad_id_G		:= -gG_CASE=bad_id
stretch_G		:= -gG_CASE=stretch -gG_CLK_HZ=2000000
scl_stuck_G		:= -gG_CASE=scl_stuck

.PHONY: all selftest vhdl93 analyse $(CASES)
all: selftest vhdl93
	@fails=0; for c in $(CASES); do $(MAKE) --no-print-directory $$c || fails=$$((fails+1)); done; \
	if [ $$fails -eq 0 ]; then echo "zcu106 tb: PASS"; else echo "zcu106 tb: FAIL ($$fails cases)"; exit 1; fi

selftest:
	@if $(PYTHON) ../scripts/si5324_regs.py --selftest > /dev/null; then echo "si5324_regs.py --selftest: PASS"; \
	else $(PYTHON) ../scripts/si5324_regs.py --selftest | grep FAIL; echo "si5324_regs.py --selftest: FAIL"; exit 1; fi

# Vivado reads .vhd as VHDL-93
vhdl93:
	@mkdir -p $(WORK)/vhdl93 && \
	if $(GHDL) -a --std=93c --workdir=$(WORK)/vhdl93 $(ENGINE) $(DUT) > $(WORK)/vhdl93/run.log 2>&1; then echo "vhdl93: PASS"; \
	else cat $(WORK)/vhdl93/run.log; echo "vhdl93: FAIL"; exit 1; fi

analyse:
	@mkdir -p $(WORK) && $(GHDL) -a $(GHDL_FLAGS) --workdir=$(WORK) $(ENGINE) $(DUT) $(TB) && \
	$(GHDL) -e $(GHDL_FLAGS) --workdir=$(WORK) zcu106_hdmi_ctl_tb

$(CASES): analyse
	@$(GHDL) -r $(GHDL_FLAGS) --workdir=$(WORK) zcu106_hdmi_ctl_tb $($@_G) > $(WORK)/$@.log 2>&1; \
	grep -E "ERROR|error|failure" $(WORK)/$@.log | head -20; \
	if grep -q ": PASS" $(WORK)/$@.log; then echo "$@: PASS"; else echo "$@: FAIL (log $(WORK)/$@.log)"; exit 1; fi
