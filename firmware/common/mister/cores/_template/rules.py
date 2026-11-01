# ----------------------------------------------------------------------------------
#  Title      : <CORE> core profile: Vivado source rules  -- TEMPLATE
#  Project    : fpga-mister
#  File       : rules.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : <date>
# ----------------------------------------------------------------------------------
#  Description: Read by scripts/prepare_sources.py.  RULES: (name, file glob, function,
#               expected count over the whole tree or None).  Functions (RULE_API):
#                 literal(old, new)              exact text, count = occurrences
#                 regex(pattern, repl, flags=0)  re.subn
#                 hoist(declarations, anchor)    move declarations out of a generate block
#                 vhdl_direct_instantiation      "label : work.ent" -> "label : entity work.ent"
#                 vhdl_null_waveform             "when c else null;" -> "(others => '0')"
#               Give every rule its expected count: an upstream change then stops the
#               build instead of slipping through.  Rule, patch or replacement file:
#               doc/PORTING.md §4.  Without this file only the generic rules run.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------

RULES = [
    # examples (from cores/msx/rules.py and cores/menu/rules.py):
    # ("vhdl-direct-instantiation", "**/*.vhd", vhdl_direct_instantiation, 24),
    # ("t80-ioq-mask", "**/t80.vhd", literal('(ioq and x"7")', '(ioq and "000000111")'), 1),
    # ("sdram-dq-assign", "rtl/sdram.sv", regex(r"\bSDRAM_DQ(\s*)<=", r"sdram_dq_r\1<="), 2),
]
