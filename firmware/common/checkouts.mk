#-----------------------------------------------------------------------------
# File       : checkouts.mk
#-----------------------------------------------------------------------------
# Description:
# The external sources of fpga-mister for the Makefiles: reads the table
# firmware/common/checkouts.txt (name url branch rev options) that
# firmware/common/scripts/checkout.sh clones and pins.
#   $(call checkout_url,<name>)     $(call checkout_branch,<name>)
#   $(call checkout_rev,<name>)     commit or tag (empty: tip of the branch)
#   $(call checkout_dir,<name>)     _Checkouts/<name>
#   $(CHECKOUT_SH) <name> [<dir>]   the setup recipe of a flow
#   $(CHECKOUT_SH) --check <name>   verify the checkout
#-----------------------------------------------------------------------------

# immediate assignments: $(lastword $(MAKEFILE_LIST)) is this file only while it is being read
CHECKOUTS_TABLE	:= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/checkouts.txt)
CHECKOUT_SH		:= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/scripts/checkout.sh)
ifndef CHECKOUTS_DIR
CHECKOUTS_DIR	:= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../_Checkouts)
endif

# $(1) name, $(2) column: 2 url, 3 branch, 4 rev, 5 options ("-" is empty)
checkout_field	 = $(filter-out -,$(shell awk -v n='$(1)' -v c=$(2) '$$1 == n {print $$c; exit}' $(CHECKOUTS_TABLE)))
checkout_url	 = $(call checkout_field,$(1),2)
checkout_branch	 = $(subst $$VIVADO_VER,$(VIVADO_VER),$(call checkout_field,$(1),3))
checkout_rev	 = $(call checkout_field,$(1),4)
checkout_dir	 = $(CHECKOUTS_DIR)/$(1)
