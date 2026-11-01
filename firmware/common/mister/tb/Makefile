#-----------------------------------------------------------------------------
# File       : Makefile
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-28
#-----------------------------------------------------------------------------
# Description:
# GHDL testbenches of the own VHDL of the MiSTer port (firmware/common/mister/hdl, cores/*/).
#   make -C firmware/common/mister/tb            every testbench, PASS/FAIL per bench
#   make -C firmware/common/mister/tb <bench>    one bench (e.g. avl_axi_bridge_tb)
#   make -C firmware/common/mister/tb vhdl93     the synthesis sources as VHDL-93: Vivado reads
#                                                .vhd files of the project as VHDL-93, the
#                                                benches run as VHDL-2008 and would not notice
# Work libraries go to firmware/build/tb (not tracked).
#-----------------------------------------------------------------------------
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------

GHDL		?= ghdl
GHDL_FLAGS	:= --std=08 -frelaxed -Wno-shared
HDL			:= ../hdl
WORK		:= ../../../build/tb
# Xilinx unisim simulation models (VHDL sources of the Vivado installation, default
# $XILINX_VIVADO/data/vhdl/src/unisims; UNISIM_SRC=<dir> overrides).  Each bench that needs
# primitives gets its own library unisim of the 7-series package (unisim_VCOMP) and just its
# primitives: a precompiled library declares the components of unisim_retarget_VCOMP
# (UltraScale generics, e.g. BUFGCE SIM_DEVICE), which do not bind to the 7-series models.
UNISIM_SRC	?= $(XILINX_VIVADO)/data/vhdl/src/unisims

# bench: the design files it needs, in analysis order
BENCHES				:= altsyncram_tb altdpram_tb lpm_mult_tb altddio_out_tb avl_axi_bridge_tb avl_axi_bridge_err_tb avl_axi_bridge_werr_tb sdram_emu_tb sdram_cache_tb sdram_cache_split_tb core_clock_stall_tb core_clock_stall_1to1_tb core_clock_stall_alt_tb sdram_stagec_tb hps_bus_axi_tb hps_bus_axi_raw_tb perf_counters_tb mister_zynq_tb mister_zynq_noreg_tb mister_zynq_free_tb mister_zynq_hp2err_tb mister_zynq_hp3err_tb \
					   scc_rom_hide_tb msu_fifo_tb snes_pll_tb snes_pll_cfg_tb clk_pulse_div_tb n64_cpu_mul_tb n64_cpu_addr_fwd_tb n64_cop0_diff_tb n64_shiftreg_tb n64_pll_tb n64_sdram_tb n64_combinealpha_tb audio_i2s_simple_tb video_pll_tb \
					   psx_sdram_tb gpu_poly_diff_tb psx_savestates_tb psx_savestates_fast_tb psx_pll_tb
# benches with Xilinx primitives (unisim_src/primitive/*.vhd): NOT RUN (no failure) without UNISIM_SRC
UNISIM_BENCHES		:= mister_zynq_tb mister_zynq_noreg_tb mister_zynq_free_tb mister_zynq_hp2err_tb mister_zynq_hp3err_tb snes_pll_tb clk_pulse_div_tb n64_pll_tb video_pll_tb \
					   psx_pll_tb
mister_zynq_tb_UNISIM	:= BUFGCE.vhd
mister_zynq_noreg_tb_UNISIM	:= $(mister_zynq_tb_UNISIM)
mister_zynq_free_tb_UNISIM	:= $(mister_zynq_tb_UNISIM) PLLE2_ADV.vhd PLLE2_BASE.vhd BUFG.vhd
mister_zynq_free_tb_FLAGS	:= -fsynopsys -Wno-hide
mister_zynq_hp2err_tb_UNISIM	:= $(mister_zynq_free_tb_UNISIM)
mister_zynq_hp2err_tb_FLAGS	:= $(mister_zynq_free_tb_FLAGS)
mister_zynq_hp3err_tb_UNISIM	:= $(mister_zynq_free_tb_UNISIM)
mister_zynq_hp3err_tb_FLAGS	:= $(mister_zynq_free_tb_FLAGS)
snes_pll_tb_UNISIM	:= BUFGCE.vhd
clk_pulse_div_tb_UNISIM	:= BUFGCE.vhd
n64_pll_tb_UNISIM	:= MMCME2_ADV.vhd MMCME2_BASE.vhd PLLE2_ADV.vhd PLLE2_BASE.vhd BUFGCTRL.vhd BUFG.vhd
# extra GHDL options of a bench (the MMCM models use std_logic_signed/std_logic_arith and hide signals)
n64_pll_tb_FLAGS	:= -fsynopsys -Wno-hide
video_pll_tb_UNISIM	:= PLLE2_ADV.vhd PLLE2_BASE.vhd BUFG.vhd
video_pll_tb_FLAGS	:= -fsynopsys -Wno-hide
scc_rom_hide_tb_SRC	:= ../cores/msx/scc_rom_hide.vhd scc_rom_hide_tb.vhd
msu_fifo_tb_SRC		:= ../cores/snes/msu_fifo.vhd msu_fifo_tb.vhd
snes_pll_tb_SRC		:= ../cores/snes/pll.vhd snes_pll_tb.vhd
snes_pll_cfg_tb_SRC	:= ../cores/snes/pll_cfg.vhd snes_pll_cfg_tb.vhd
clk_pulse_div_tb_SRC	:= $(HDL)/clk_pulse_div.vhd clk_pulse_div_tb.vhd
audio_i2s_simple_tb_NEEDS	= $(HDMI_TX)/i2s_rx.vhd
audio_i2s_simple_tb_SRC	= $(HDL)/audio_i2s_simple.vhd $(HDMI_TX)/i2s_rx.vhd audio_i2s_simple_tb.vhd
n64_cpu_mul_tb_SRC	:= ../cores/n64/cpu_mul.vhd n64_cpu_mul_tb.vhd
n64_cpu_addr_fwd_tb_SRC	:= ../cores/n64/cpu_addr_fwd.vhd n64_cpu_addr_fwd_tb.vhd
n64_shiftreg_tb_SRC	:= ../cores/n64/Shiftreg.vhd n64_shiftreg_tb.vhd
# replacement against the original from the checkout: <bench>_NEEDS must exist (else NOT RUN),
# <bench>_PRE runs before the analysis (here: the original renamed to RDP_CombineAlpha_orig)
N64_RTL			:= ../../../../_Checkouts/N64_MiSTer/rtl
n64_combinealpha_tb_NEEDS	:= $(N64_RTL)/RDP_CombineAlpha.vhd
n64_combinealpha_tb_PRE	:= sed 's/\bRDP_CombineAlpha\b/RDP_CombineAlpha_orig/g' $(N64_RTL)/RDP_CombineAlpha.vhd \
			   > $(WORK)/n64_combinealpha_tb/RDP_CombineAlpha_orig.vhd
n64_combinealpha_tb_SRC	:= $(N64_RTL)/functions.vhd $(N64_RTL)/RDP_package.vhd \
			   $(WORK)/n64_combinealpha_tb/RDP_CombineAlpha_orig.vhd ../cores/n64/RDP_CombineAlpha.vhd \
			   n64_combinealpha_tb.vhd
n64_sdram_tb_SRC	:= ../cores/n64/sdram.vhd n64_sdram_tb.vhd
# N64 COP0 timing patch: the checkout's cpu_cop0 (cpu_cop0_orig) against the copy with all N64 patches
# applied (cpu_cop0_new); RamMLAB as prepare_sources.py makes it (generic altdpram) in library mem
N64_PATCHES		:= $(sort $(wildcard ../cores/n64/patches/*.patch))
NCD			:= $(WORK)/n64_cop0_diff_tb
n64_cop0_diff_tb_NEEDS	:= $(N64_RTL)/cpu_cop0.vhd
n64_cop0_diff_tb_PRE	:= rm -rf $(NCD)/p && mkdir -p $(NCD)/p/rtl && \
			   cp $(N64_RTL)/cpu.vhd $(N64_RTL)/cpu_cop0.vhd $(NCD)/p/rtl/ && \
			   for f in $(abspath $(N64_PATCHES)); do patch -s -p1 -d $(NCD)/p -i $$f || exit 1; done && \
			   sed 's/\bcpu_cop0\b/cpu_cop0_new/g' $(NCD)/p/rtl/cpu_cop0.vhd > $(NCD)/cpu_cop0_new.vhd && \
			   sed 's/\bcpu_cop0\b/cpu_cop0_orig/g' $(N64_RTL)/cpu_cop0.vhd > $(NCD)/cpu_cop0_orig.vhd && \
			   sed -e 's/^\s*\(LIBRARY\|library\) altera_mf;/-- &/' -e 's/^\s*\(USE\|use\) altera_mf\..*/-- &/' \
			       -e 's/ialtdpram : altdpram/ialtdpram : entity work.altdpram/' $(N64_RTL)/RamMLAB.vhd > $(NCD)/RamMLAB.vhd && \
			   $(GHDL) -a $(GHDL_FLAGS) --work=mem --workdir=$(NCD) $(HDL)/intel/altdpram.vhd $(NCD)/RamMLAB.vhd
n64_cop0_diff_tb_RUN	:= --ieee-asserts=disable
n64_cop0_diff_tb_SRC	:= $(N64_RTL)/functions.vhd $(N64_RTL)/export.vhd $(N64_RTL)/cpu_TLB_instr.vhd $(N64_RTL)/cpu_TLB_data.vhd \
			   $(NCD)/cpu_cop0_orig.vhd $(NCD)/cpu_cop0_new.vhd n64_cop0_diff_tb.vhd
# PSX: the DMA write FIFO of the core (SyncFifoFallThrough) from the checkout drives dmafifo_*
PSX_RTL			:= ../../../../_Checkouts/PSX_MiSTer/rtl
psx_sdram_tb_NEEDS	:= $(PSX_RTL)/SyncFifoFallThrough.vhd
psx_sdram_tb_SRC	:= $(PSX_RTL)/SyncFifoFallThrough.vhd ../cores/psx/sdram.vhd psx_sdram_tb.vhd
# PSX gpu_poly timing patch: the original (renamed gpu_poly_orig) against the patched copy (gpu_poly_new);
# library mem only has to exist (gpu_poly declares it)
GPD			:= $(WORK)/gpu_poly_diff_tb
GPU_POLY_PATCH		:= ../cores/psx/patches/0001-gpu-poly-target-timing-factors-in-sortvertices.patch
gpu_poly_diff_tb_NEEDS	:= $(PSX_RTL)/gpu_poly.vhd
# run options only: the dividers start with undefined quotients (numeric_std metavalue warnings flood the log)
gpu_poly_diff_tb_RUN	:= --ieee-asserts=disable
gpu_poly_diff_tb_PRE	:= rm -rf $(GPD)/p && mkdir -p $(GPD)/p/rtl && cp $(PSX_RTL)/gpu_poly.vhd $(GPD)/p/rtl/ && \
			   patch -s -p1 -d $(GPD)/p -i $(abspath $(GPU_POLY_PATCH)) && \
			   sed 's/\bgpu_poly\b/gpu_poly_new/g' $(GPD)/p/rtl/gpu_poly.vhd > $(GPD)/gpu_poly_new.vhd && \
			   sed 's/\bgpu_poly\b/gpu_poly_orig/g' $(PSX_RTL)/gpu_poly.vhd > $(GPD)/gpu_poly_orig.vhd && \
			   $(GHDL) -a $(GHDL_FLAGS) --work=mem --workdir=$(GPD) $(PSX_RTL)/SyncFifo.vhd
gpu_poly_diff_tb_SRC	:= $(PSX_RTL)/pGPU.vhd $(PSX_RTL)/divider.vhd $(PSX_RTL)/mul9s.vhd $(PSX_RTL)/mul32u.vhd \
			   $(GPD)/gpu_poly_orig.vhd $(GPD)/gpu_poly_new.vhd gpu_poly_diff_tb.vhd
psx_savestates_tb_NEEDS	:= $(PSX_RTL)/savestates.vhd
psx_savestates_tb_PRE	:= sed 's/\bsavestates\b/savestates_orig/g' $(PSX_RTL)/savestates.vhd \
			   > $(WORK)/psx_savestates_tb/savestates_orig.vhd
psx_savestates_tb_SRC	:= $(WORK)/psx_savestates_tb/savestates_orig.vhd ../cores/psx/savestates.vhd psx_savestates_tb.vhd
psx_savestates_fast_tb_NEEDS	:= $(psx_savestates_tb_NEEDS)
psx_savestates_fast_tb_PRE	:= sed 's/\bsavestates\b/savestates_orig/g' $(PSX_RTL)/savestates.vhd \
			   > $(WORK)/psx_savestates_fast_tb/savestates_orig.vhd
psx_savestates_fast_tb_SRC	:= $(WORK)/psx_savestates_fast_tb/savestates_orig.vhd ../cores/psx/savestates.vhd psx_savestates_tb.vhd
psx_pll_tb_UNISIM	:= MMCME2_ADV.vhd MMCME2_BASE.vhd PLLE2_ADV.vhd PLLE2_BASE.vhd BUFGCTRL.vhd BUFG.vhd
psx_pll_tb_FLAGS	:= -fsynopsys -Wno-hide
psx_pll_tb_SRC		:= $(HDL)/pll_reset.vhd ../cores/psx/pll.vhd ../cores/psx/pll2.vhd ../cores/psx/pll_cfg.vhd psx_pll_tb.vhd
n64_pll_tb_SRC		:= $(HDL)/pll_reset.vhd ../cores/n64/pll.vhd ../cores/n64/pll2.vhd ../cores/n64/pll_cfg_small.vhd n64_pll_tb.vhd
video_pll_tb_SRC	:= $(HDL)/pll_reset.vhd $(HDL)/video_pll.vhd video_pll_tb.vhd
altsyncram_tb_SRC		:= $(HDL)/intel/altsyncram.vhd altsyncram_tb.vhd
altdpram_tb_SRC		:= $(HDL)/intel/altdpram.vhd altdpram_tb.vhd
lpm_mult_tb_SRC		:= $(HDL)/intel/lpm_mult.vhd lpm_mult_tb.vhd
altddio_out_tb_SRC		:= $(HDL)/intel/altddio_out.vhd altddio_out_tb.vhd
avl_axi_bridge_tb_SRC	:= $(HDL)/avl_axi_bridge.vhd axi3_mem_model.vhd avl_axi_bridge_tb.vhd
avl_axi_bridge_err_tb_SRC	:= $(avl_axi_bridge_tb_SRC)
avl_axi_bridge_werr_tb_SRC	:= $(avl_axi_bridge_tb_SRC)
sdram_emu_tb_SRC		:= $(HDL)/sdram_emu.vhd $(HDL)/sdram_bram.vhd sdram_emu_tb.vhd
core_clock_stall_tb_SRC	:= $(HDL)/core_clock_stall.vhd core_clock_stall_tb.vhd
core_clock_stall_1to1_tb_SRC	:= $(core_clock_stall_tb_SRC)
core_clock_stall_alt_tb_SRC	:= $(core_clock_stall_tb_SRC)
hps_bus_axi_tb_SRC		:= $(HDL)/hps_bus_axi.vhd hps_bus_axi_tb.vhd
hps_bus_axi_raw_tb_SRC	:= $(hps_bus_axi_tb_SRC)
perf_counters_tb_SRC	:= $(HDL)/perf_counters.vhd perf_counters_tb.vhd
sdram_cache_tb_SRC		:= $(HDL)/sdram_cache.vhd $(HDL)/avl_axi_bridge.vhd axi3_mem_model.vhd sdram_cache_tb.vhd
sdram_cache_split_tb_SRC	:= $(sdram_cache_tb_SRC)
mister_zynq_tb_SRC	:= $(HDL)/core_clock_stall.vhd $(HDL)/sdram_emu.vhd $(HDL)/sdram_region.vhd $(HDL)/sdram_bram.vhd \
					   $(HDL)/sdram_cache.vhd $(HDL)/avl_axi_bridge.vhd $(HDL)/hps_bus_axi.vhd $(HDL)/perf_counters.vhd \
					   $(HDL)/pll_reset.vhd $(HDL)/video_pll.vhd axi3_mem_model.vhd mister_zynq_tb_pkg.vhd sys_top_zynq_stub.vhd $(HDL)/mister_zynq.vhd mister_zynq_tb.vhd
mister_zynq_noreg_tb_SRC	:= $(mister_zynq_tb_SRC)
mister_zynq_free_tb_SRC	:= $(mister_zynq_tb_SRC)
mister_zynq_hp2err_tb_SRC	:= $(mister_zynq_tb_SRC)
mister_zynq_hp3err_tb_SRC	:= $(mister_zynq_tb_SRC)
sdram_stagec_tb_SRC	:= $(HDL)/core_clock_stall.vhd $(HDL)/sdram_emu.vhd $(HDL)/sdram_region.vhd $(HDL)/sdram_bram.vhd \
					   $(HDL)/sdram_cache.vhd $(HDL)/avl_axi_bridge.vhd axi3_mem_model.vhd sdram_stagec_tb.vhd

# HDMI transmitter of the _hdmi designs: firmware/common/ip/hdmi-tx (its own benches run in
# selfcheck.sh step 4); analysed here with the rest
HDMI_TX		:= ../../ip/hdmi-tx/src
HDMI_TX_SRC	:= $(addprefix $(HDMI_TX)/,hdmi_pkg.vhd i2s_rx.vhd tmds_enc.vhd hdmi_audio.vhd hdmi_tx.vhd hdmi_out.vhd)

# replacement files Vivado reads as VHDL 2008 (profile core_vhdl2008: they use the core's
# VHDL-2008 packages), not part of the VHDL-93 check
VHDL2008_ONLY	:= ../cores/n64/RDP_CombineAlpha.vhd

# synthesis sources in analysis order (the VHDL of the block designs, without benches)
VHDL93_SRC	:= $(HDL)/intel/altsyncram.vhd $(HDL)/intel/altdpram.vhd $(HDL)/intel/lpm_mult.vhd \
			   $(HDL)/intel/altddio_out.vhd $(HDL)/avl_axi_bridge.vhd \
			   $(HDL)/core_clock_stall.vhd $(HDL)/clk_pulse_div.vhd $(HDL)/sdram_emu.vhd $(HDL)/sdram_bram.vhd $(HDL)/sdram_region.vhd \
			   $(HDL)/sdram_cache.vhd $(HDL)/hps_bus_axi.vhd $(HDL)/perf_counters.vhd $(HDL)/pll_reset.vhd $(HDL)/video_pll.vhd $(HDL)/mister_zynq.vhd \
			   $(HDMI_TX_SRC) $(filter-out $(VHDL2008_ONLY),$(wildcard ../cores/*/*.vhd))

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
	@if [ -n "$(filter $@,$(UNISIM_BENCHES))" ]; then \
		[ -f "$(UNISIM_SRC)/unisim_VCOMP.vhd" ] || { echo "$@: NOT RUN (no unisim sources in $(UNISIM_SRC))"; exit 0; }; \
		mkdir -p $(WORK)/$@ && \
		$(GHDL) -a $(GHDL_FLAGS) $($@_FLAGS) --work=unisim --workdir=$(WORK)/$@ $(UNISIM_SRC)/unisim_VPKG.vhd \
			$(UNISIM_SRC)/unisim_VCOMP.vhd $(addprefix $(UNISIM_SRC)/primitive/,$($@_UNISIM)) || exit 1; \
	fi; \
	[ -z "$($@_NEEDS)" ] || [ -f "$($@_NEEDS)" ] || { echo "$@: NOT RUN (no $($@_NEEDS))"; exit 0; }; \
	mkdir -p $(WORK)/$@ && $(if $($@_PRE),$($@_PRE) &&) \
	$(GHDL) -a $(GHDL_FLAGS) $($@_FLAGS) --workdir=$(WORK)/$@ -P$(WORK)/$@ $($@_SRC) && \
	{ $(GHDL) -r $(GHDL_FLAGS) $($@_FLAGS) --workdir=$(WORK)/$@ -P$(WORK)/$@ $@ --assert-level=error $($@_RUN) 2>&1 | tee $(WORK)/$@/run.log | grep -E "PASS|FAIL|error|failure" ; \
	grep -q "PASS" $(WORK)/$@/run.log && echo "$@: PASS" || { echo "$@: FAIL (log $(WORK)/$@/run.log)"; exit 1; }; }
