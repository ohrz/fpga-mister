#-----------------------------------------------------------------------------
# File       : lib.mk
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-10-24
#-----------------------------------------------------------------------------
# Description:
# Recipes several flow Makefiles share, included by Makefiles/common.mk:
#   $(call apply_patches_once,<git tree>,<patch files>)      recipe lines: apply each
#        patch unless the tree already carries it (git apply --reverse --check)
#   $(call merge_fragment,<tree>,<make env>,<fragments>)     recipe lines: merge the
#        Kconfig fragments into .config, olddefconfig, every fragment line must be in .config
#   $(call worktree_create,<checkout>,<worktree>,<rev>,<patches>)   recipe lines: a fresh
#        git worktree of the pinned checkout (an existing one is removed) with the patches
#   $(eval $(call require_board_mk,<flow>))   include <flow>.mk of BOARD_SCRIPTS_DIR or stop
#        (not for help)
#-----------------------------------------------------------------------------
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------

# version-dependent board files of a flow (<flow>.mk, designs)
BOARD_SCRIPTS_DIR	:= firmware/targets/$(PLATFORM)/scripts/$(VIVADO_VER)

define apply_patches_once
for p in $(2); do																\
	if git -C $(1) apply --reverse --check "$$p" 2>/dev/null; then				\
		echo "    applied:  $$(basename $$p)";									\
	else																		\
		git -C $(1) apply "$$p" && echo "    applying: $$(basename $$p)" || exit 1;	\
	fi;																			\
done
endef

define merge_fragment
cd $(1) && scripts/kconfig/merge_config.sh -m .config $(abspath $(3))
$(2) make olddefconfig -C $(1)
cat $(3) | while read -r line; do											\
	case "$$line" in "# CONFIG_"*" is not set") ;; ""|"#"*) continue ;; esac;	\
	grep -qxF "$$line" $(1)/.config || { echo "ERROR: '$$line' from $(3) is not in .config"; exit 1; };	\
done
endef

define worktree_create
if [ -e "$(2)" ]; then git -C "$(1)" worktree remove --force "$(2)"; fi
git -C "$(1)" worktree prune
mkdir -p $(dir $(2))
git -C "$(1)" worktree add -q --detach "$(2)" $(3)
for p in $(4); do echo "apply $$(basename $$p)"; git -C "$(2)" apply "$$p" || exit 1; done
endef

define require_board_mk
ifndef ONLY_HELP
ifeq ($$(wildcard $(BOARD_SCRIPTS_DIR)/$(1).mk),)
$$(error "No $(1) board profile $(BOARD_SCRIPTS_DIR)/$(1).mk for $(PLATFORM) with $(VIVADO_VER)")
endif
include $(BOARD_SCRIPTS_DIR)/$(1).mk
endif
endef

# Makefile ends here
