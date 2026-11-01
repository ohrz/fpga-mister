#-----------------------------------------------------------------------------
# File       : common.mk
#-----------------------------------------------------------------------------
# Description:
# Common part of the flow Makefiles (Makefiles/<flow>/Makefile), included first:
#   - FLOW_NAME: the flow, from the Makefile's directory
#   - XILINX_VIVADO must be set (source <Xilinx>/<version>/Vivado/settings64.sh)
#   - VIVADO_VER from the installation path:
#       /opt/Xilinx/2025.2/Vivado  -> 2025.2
#       /opt/Xilinx/Vivado/2024.2  -> 2024.2
#   - PLATFORMS: every board with a profile firmware/targets/<board>/platform.mk;
#     SUPPORTED_PLATFORMS: those whose PLATFORM_FLOWS name this flow
#   - PLATFORM must be one of SUPPORTED_PLATFORMS; its platform.mk is included
#     (board variables of the flows; nothing else in Makefiles/ is board-specific),
#     then Makefiles/arch-<PLATFORM_ARCH>.mk with the ?= defaults of its architecture
#-----------------------------------------------------------------------------

# Define echo
ECHO = echo

# the flow: Makefiles/<flow>/Makefile is the first Makefile of this make (empty for the
# root Makefile, which only needs VIVADO_VER)
FLOW_NAME	:= $(notdir $(patsubst %/,%,$(dir $(abspath $(firstword $(MAKEFILE_LIST))))))
FLOW_NAME	:= $(if $(wildcard Makefiles/$(FLOW_NAME)/Makefile),$(FLOW_NAME))

# 'make help' (or no goal, help is the first target) and the root goals without FLOW (test: self-check,
# lab, status, status-update) need neither the Xilinx environment nor a PLATFORM
ONLY_HELP := $(if $(filter-out help $(if $(FLOW_NAME),,test lab status status-update hwtest build-matrix),$(MAKECMDGOALS)),,1)

# the lab (addresses, hosts; lab.local.mk overrides)
include $(dir $(lastword $(MAKEFILE_LIST)))../firmware/common/lab.mk

# boards with a profile, and those whose profile lists this flow
# (firmware/targets/_template is no board)
PLATFORMS			:= $(filter-out _%,$(patsubst firmware/targets/%/platform.mk,%,$(wildcard firmware/targets/*/platform.mk)))
platform_flows		 = $(shell sed -n 's/^PLATFORM_FLOWS[[:space:]]*:=//p' firmware/targets/$(1)/platform.mk)
SUPPORTED_PLATFORMS	:= $(strip $(foreach p,$(PLATFORMS),$(if $(filter $(FLOW_NAME),$(call platform_flows,$(p))),$(p))))

ifndef ONLY_HELP
ifndef XILINX_VIVADO
$(error "No XILINX environment found, source <Xilinx>/<version>/Vivado/settings64.sh")
endif
endif

VIVADO_PATH_TRIMMED	:= $(patsubst %/Vivado,%,$(patsubst %/,%,$(XILINX_VIVADO)))
VIVADO_VER			:= $(lastword $(subst /, ,$(VIVADO_PATH_TRIMMED)))

ifneq ($(FLOW_NAME),)
ifndef ONLY_HELP
ifneq ($(words $(PLATFORM)),1)
$(error "PLATFORM must be one of: $(SUPPORTED_PLATFORMS)")
endif
ifeq ($(filter $(PLATFORM),$(SUPPORTED_PLATFORMS)),)
$(error "PLATFORM '$(PLATFORM)' is not supported by this flow, use one of: $(SUPPORTED_PLATFORMS)")
endif
endif
# the board profile (for help too, when a supported PLATFORM is given: its defaults show up)
ifneq ($(filter $(PLATFORM),$(SUPPORTED_PLATFORMS)),)
# VIDEO=dvi|hdmi is short for VIDEO_TX (video output of the MiSTer designs, set ?= in the profile)
ifneq ($(strip $(VIDEO)),)
VIDEO_TX := $(VIDEO)
endif
include firmware/targets/$(PLATFORM)/platform.mk
# defaults of the architecture (PLATFORM_ARCH zynq, zynqmp) for what the profile leaves out
include $(dir $(lastword $(filter %common.mk,$(MAKEFILE_LIST))))arch-$(PLATFORM_ARCH).mk
endif
endif

# recipes several flows share (patches, Kconfig fragments, worktrees, board .mk files)
include $(dir $(lastword $(filter %common.mk,$(MAKEFILE_LIST))))lib.mk
