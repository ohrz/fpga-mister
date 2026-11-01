# ----------------------------------------------------------------------------------
#  Title      : SNES core profile: Vivado source rules for SNES_MiSTer
#  Project    : fpga-mister
#  File       : rules.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-30
# ----------------------------------------------------------------------------------
#  Description: Read by scripts/prepare_sources.py (passed by mister_project.tcl).
#               RULES: (name, file glob, function, expected count over the tree or None),
#               functions from RULE_API of prepare_sources.py.  A count that differs
#               from the expected one stops the build: the upstream source changed.
#               Rule or patch: doc/PORTING.md §4.  Found in OOC runs of the core
#               (PORTING §5.1); GSU's two-edge processes and the VHDL
#               side of CLK_MID are patches (cores/snes/patches/).
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------

RULES = [
    # --- profile decisions ---
    # no SPC7110 (3 Japan-only games, 7000 LUT): the core does not fit with it
    ("use-spc7110", "rtl/main.v",
     literal("parameter USE_SPC7110 = 1'b1;", "parameter USE_SPC7110 = 1'b0;"), 1),
    # backup RAM 128 KB instead of 256 KB (32 RAMB36 less)
    ("bsram-bits", "SNES.sv",
     literal("localparam  BSRAM_BITS = 18; // 256Kbyte", "localparam  BSRAM_BITS = 17; // 128Kbyte (Zybo)"), 1),

    # --- SystemVerilog nets with procedural assignments (Quartus accepts them) ---
    # USER_OUT (an output net of emu_ports.vh): bits 2, 5, 6 continuous, 0, 1, 3, 4 from an
    # always_comb; all bits go through the variable user_out_c
    ("user-out-var", "SNES.sv",
     literal("assign USER_OUT[2] = 1'b1;",
             "logic [6:0] user_out_c;\nassign USER_OUT = user_out_c;\nassign USER_OUT[2] = 1'b1;"), 1),
    ("user-out-bits", "SNES.sv", regex(r"\bUSER_OUT\[", "user_out_c["), 12),
    # plain module-level wires of SNES.sv (JOY1_DI and others are assigned in always blocks):
    # logic, same net with a single driver; "wire x = e;" stays a wire (declarations_first)
    ("snes-wire-logic", "SNES.sv", regex(r"(?m)^(\s*)wire\b(?=[^;=]*;)", r"\1logic"), 143),
    ("cheat-dup-index", "rtl/cheatcodes.sv",
     literal("wire [INDEX_SIZE-1:0] index, dup_index;",
             "wire [INDEX_SIZE-1:0] index;\nlogic [INDEX_SIZE-1:0] dup_index;"), 1),
    ("cheat-found-dup", "rtl/cheatcodes.sv", literal("wire found_dup;", "logic found_dup;"), 1),
    # ANSI output ports without a type are nets: output logic (also for continuous drivers)
    ("output-logic-sv", "rtl/**/*.sv",
     regex(r"(?m)^(\s*)output(\s+)(?!(?:reg|wire|logic|integer|var|bit)\b)", r"\1output logic\2"), 54),
    ("output-logic-v", "rtl/**/*.v",
     regex(r"(?m)^(\s*)output(\s+)(?!(?:reg|wire|logic|integer|var|bit)\b)", r"\1output logic\2"), 63),
    # rtl/sdram.sv: "inout reg" port with procedural assignments (as menu/rules.py)
    ("sdram-dq-port", "rtl/sdram.sv",
     literal("inout  reg [15:0] SDRAM_DQ,", "inout      [15:0] SDRAM_DQ,"), 1),
    ("sdram-dq-reg", "rtl/sdram.sv",
     literal("assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];",
             "assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];\n"
             "reg [15:0] sdram_dq_r;\nassign SDRAM_DQ = sdram_dq_r;"), 1),
    ("sdram-dq-assign", "rtl/sdram.sv", regex(r"\bSDRAM_DQ(\s*)<=", r"sdram_dq_r\1<="), 2),

    # --- declarations after their use (Vivado: implicit 1-bit wire, upper bits lost) ---
    ("declarations-first-snes", "SNES.sv", declarations_first, 248),
    ("declarations-first-main", "rtl/main.v", declarations_first, 147),

    # --- VHDL operand lengths (Quartus extends, Vivado requires equal lengths) ---
    # DSPn: 11-bit address "or" an 8-bit literal (sets bit 6)
    ("dspn-addr-width", "rtl/chip/DSP/DSPn.vhd",
     literal('DATA_RAM_ADDR_A or x"40";', 'DATA_RAM_ADDR_A or "00001000000";'), 1),
    # CX4Map: 22-bit cartridge address "and" a 23-bit mask
    ("cx4map-rom-width", "rtl/chip/CX4/CX4Map.vhd",
     literal("ROM_ADDR <= CART_ADDR and ROM_MASK(22 downto 0);",
             'ROM_ADDR <= ("0" & CART_ADDR) and ROM_MASK(22 downto 0);'), 1),

    # --- MSU-1 FIFO: positional parameters to the VHDL replacement (cores/snes/msu_fifo.vhd)
    ("msu-fifo-generics", "rtl/chip/MSU1/msu_audio.v",
     literal("msu_fifo #(32,10) audio_fifo", "msu_fifo #(.WIDTH(32), .DEPTH(10)) audio_fifo"), 1),

    # --- clk_sys falling edge as its own clock CLK_MID (patch 0002 has the VHDL side):
    #     outclk_3 of cores/snes/pll.vhd to main (MCLK_MID) and msu_audio (CEGen)
    ("mid-clk-net", "SNES.sv",
     literal("logic clk_sys;\n", "logic clk_sys;\nlogic clk_sys_mid;  // falling edge of clk_sys as a clock (pll.vhd)\n"), 1),
    ("mid-clk-pll", "SNES.sv",
     literal("\t.outclk_2(clk_sys),\n", "\t.outclk_2(clk_sys),\n\t.outclk_3(clk_sys_mid),\n"), 1),
    ("mid-clk-main", "SNES.sv",
     literal("\t.ACLK(clk_sys),\n", "\t.ACLK(clk_sys),\n\t.MCLK_MID(clk_sys_mid),\n"), 1),
    ("mid-clk-msu", "SNES.sv",
     literal("\t.clk(clk_sys),\n\t.clk_rate(", "\t.clk(clk_sys),\n\t.clk_mid(clk_sys_mid),\n\t.clk_rate("), 1),
    ("mid-clk-msu-port", "rtl/chip/MSU1/msu_audio.v",
     literal("\tinput             clk,\n", "\tinput             clk,\n\tinput             clk_mid,\n"), 1),
    ("mid-clk-msu-cegen", "rtl/chip/MSU1/msu_audio.v",
     literal("CEGen sample_clock\n(\n\t.CLK(clk),", "CEGen sample_clock\n(\n\t.CLK(clk_mid),"), 1),
    ("mid-clk-main-port", "rtl/main.v",
     literal("\tinput             ACLK,\n", "\tinput             ACLK,\n\tinput             MCLK_MID,\n"), 1),
    ("mid-clk-main-snes", "rtl/main.v",
     literal("\t.dspclk(ACLK),\n", "\t.dspclk(ACLK),\n\t.DSPCLK_MID(MCLK_MID),\n"), 1),
    ("mid-clk-main-chips", "rtl/main.v",
     regex(r"(\n(?:DSP_LHRomMap #\(\.USE_DSPn\(USE_DSPn\)\) DSP_LHRomMap|CX4Map CX4Map|GSUMap GSUMap)\n\(\n\t\.mclk\(MCLK\),\n)",
           r"\1\t.MCLK_MID(MCLK_MID),\n"), 3),

    # --- PAL clock: cores/snes/pll_cfg.vhd decodes the region writes into
    #     reconfig_to_pll[0]; out as emu port ZYNQ_PACE_ALT (macro MISTER_ZYNQ_PACE_ALT,
    #     sys_top_zynq -> mister_zynq: pacer at G_PACE_NUM_ALT / G_PACE_DEN_ALT)
    ("pace-alt-port", "SNES.sv", add_port("emu", "output        ZYNQ_PACE_ALT"), 1),
    ("pace-alt-assign", "SNES.sv",
     literal("pll_cfg pll_cfg\n(", "assign ZYNQ_PACE_ALT = reconfig_to_pll[0];  // PAL: second pacer ratio\n\n"
             "pll_cfg pll_cfg\n("), 1),
]
