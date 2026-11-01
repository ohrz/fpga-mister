# ----------------------------------------------------------------------------------
#  Title      : MSX core profile: Vivado source rules for MSX_MiSTer
#  Project    : fpga-mister
#  File       : rules.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-29
# ----------------------------------------------------------------------------------
#  Description: Read by scripts/prepare_sources.py (passed by mister_project.tcl).
#               RULES: (name, file glob, function, expected count over the tree or None),
#               functions from RULE_API of prepare_sources.py (literal, regex, hoist,
#               vhdl_direct_instantiation, vhdl_null_waveform).  A count that differs
#               from the expected one stops the build: the upstream source changed.
#               Rule or patch: doc/PORTING.md §4.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------

RULES = [
    # "label : work.ent port map" without the keyword "entity"
    ("vhdl-direct-instantiation", "**/*.vhd", vhdl_direct_instantiation, 24),
    # emsx_top.vhd CpuAdr(19:0): no slot selected -> no RamReq, the address is unused
    ("vhdl-null-waveform", "**/*.vhd", vhdl_null_waveform, 1),
    # T80 block I/O flags: 9-bit ioq "and" a 4-bit literal (Quartus extends it, Vivado
    # requires equal lengths); the mask keeps bits 2:0
    ("t80-ioq-mask", "**/t80.vhd", literal('(ioq and x"7")', '(ioq and "000000111")'), 1),
]
