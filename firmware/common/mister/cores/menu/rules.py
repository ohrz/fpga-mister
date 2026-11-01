# ----------------------------------------------------------------------------------
#  Title      : Menu core profile: Vivado source rules for Menu_MiSTer
#  Project    : fpga-mister
#  File       : rules.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-29
# ----------------------------------------------------------------------------------
#  Description: Read by scripts/prepare_sources.py (passed by mister_project.tcl);
#               format as in cores/msx/rules.py.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------

RULES = [
    # rtl/sdram.sv: "inout reg" port with procedural assignments (Quartus accepts it,
    # Vivado does not): a plain inout driven by a reg of the same value, 'Z' included
    ("sdram-dq-port", "rtl/sdram.sv",
     literal("inout  reg [15:0] SDRAM_DQ,", "inout      [15:0] SDRAM_DQ,"), 1),
    ("sdram-dq-reg", "rtl/sdram.sv",
     literal("assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];",
             "assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];\n"
             "reg [15:0] sdram_dq_r;\nassign SDRAM_DQ = sdram_dq_r;"), 1),
    # the procedural assignments to the port go to sdram_dq_r
    ("sdram-dq-assign", "rtl/sdram.sv", regex(r"\bSDRAM_DQ(\s*)<=", r"sdram_dq_r\1<="), 2),
    # rtl/lfsr.v is an lcell ring (combinational loop); cores/menu/lfsr.vhd is clocked
    ("lfsr-clock", "menu.sv",
     literal("lfsr #(lfsr_n) random(rnd);", "lfsr #(.N(lfsr_n)) random(.clk(CLK_VIDEO), .rnd(rnd));"), 1),
]
