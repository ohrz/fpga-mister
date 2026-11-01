# ----------------------------------------------------------------------------------
#  Title      : N64 core profile: Vivado source rules for N64_MiSTer
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
#               (PORTING §5.2).
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------

# n64top port connections in N64.sv: OSD option -> constant (profile decisions).
# The menu still shows the options; they have no effect.
OPTION_CONSTANTS = [
    # overlays off (error codes, frame counter)
    (".errorCodesOn(status[2]),", ".errorCodesOn(1'b0),"),
    (".fpscountOn(status[28]),", ".fpscountOn(1'b0),"),
    # VI filters off (the "Off" setting of each option), VI path instead of clean HDMI
    (".VI_BILINEAROFF(status[32]),", ".VI_BILINEAROFF(1'b1),"),
    (".VI_GAMMAOFF(status[33]),", ".VI_GAMMAOFF(1'b1),"),
    (".VI_DEDITHEROFF(status[87]),", ".VI_DEDITHEROFF(1'b1),"),
    (".VI_AAOFF(status[35]),", ".VI_AAOFF(1'b1),"),
    (".VI_DIVOTOFF(status[36]),", ".VI_DIVOTOFF(1'b1),"),
    (".VI_NOISEOFF(status[37]),", ".VI_NOISEOFF(1'b1),"),
    (".VI_DIRECTFBMODE(clean_hdmi),", ".VI_DIRECTFBMODE(1'b0),"),
    # debug settings (menu page P3) at their defaults (status bit 0)
    (".FASTRAM(status[83]),", ".FASTRAM(1'b0),"),
    (".FASTROM(status[106]),", ".FASTROM(1'b0),"),
    (".INSTRCACHEON(~status[93]),", ".INSTRCACHEON(1'b1),"),
    (".DATACACHEON(~status[43]),", ".DATACACHEON(1'b1),"),
    (".DATACACHESLOW(status[27:24]),", ".DATACACHESLOW(4'd0),"),
    (".DATACACHEFORCEWEB(status[29]),", ".DATACACHEFORCEWEB(1'b0),"),
    (".DATACACHETLBON(~status[100]),", ".DATACACHETLBON(1'b1),"),
    (".DISABLE_BOOTCOUNT(status[98]),", ".DISABLE_BOOTCOUNT(1'b0),"),
    (".DISABLE_DTLBMINI(status[99]),", ".DISABLE_DTLBMINI(1'b0),"),
    (".DDR3SLOW(status[23:20]),", ".DDR3SLOW(4'd0),"),
    (".write9(!status[11]),", ".write9(1'b1),"),
    (".read9(!status[12]),", ".read9(1'b1),"),
    (".wait9(!status[13]),", ".wait9(1'b1),"),
    (".writeZ(!status[14]),", ".writeZ(1'b1),"),
    (".readZ(!status[15]),", ".readZ(1'b1),"),
    (".DISABLE_AI       (status[101]),", ".DISABLE_AI       (1'b0),"),
    (".DISABLE_AI_IRQ   (status[102]),", ".DISABLE_AI_IRQ   (1'b0),"),
    (".PIFCOMPARE             (status[91]),", ".PIFCOMPARE             (1'b0),"),
    # savestates off (save_state is 0 upstream)
    (".load_state            (ss_load),", ".load_state            (1'b0),"),
    # no 64DD
    (".ddDiskAvailable   (ddDisk_loaded     ),", ".ddDiskAvailable   (1'b0              ),"),
    (".ddIplAvailable    (ddIpl_loaded      ),", ".ddIplAvailable    (1'b0              ),"),
    (".ddDevMode         (status[107]       ),", ".ddDevMode         (1'b0              ),"),
    # controller 1 only: N64Pad, None, ControllerPak, RumblePak, TransferPak (SNAC 100,
    # keyboard 110 and mouse 111 become N64Pad); controllers 2-4 none (001)
    (".PADTYPE0         (status[51:49]),",
     ".PADTYPE0         ((status[51:49] == 3'b100 || status[51:50] == 2'b11) ? 3'b000 : status[51:49]),"),
    (".PADTYPE1         (status[54:52]),", ".PADTYPE1         (3'b001),"),
    (".PADTYPE2         (status[57:55]),", ".PADTYPE2         (3'b001),"),
    (".PADTYPE3         (status[60:58]),", ".PADTYPE3         (3'b001),"),
    (".MOUSETYPE        (status[86:84]),", ".MOUSETYPE        (3'b000),"),
    (".KeyboardPS2Key(ps2_key),", ".KeyboardPS2Key(11'd0),"),
    # SNAC inputs idle
    (".toPad_readySNAC        (toPad_ready),", ".toPad_readySNAC        (1'b0),"),
    (".toPIF_enaSNAC          (toPIF_ena),", ".toPIF_enaSNAC          (1'b0),"),
    (".toPIF_timeoutSNAC      (toPIF_timeout),", ".toPIF_timeoutSNAC      (1'b0),"),
    (".toPIF_dataSNAC         (toPIF_data),", ".toPIF_dataSNAC         (8'd0),"),
]

# emu port COREMEM_<name> (as DDRAM_*), its declaration, port of cores/n64/sdram.vhd
COREMEM = [
    ("CLK", "output        COREMEM_CLK", "mem_clk"),
    ("BUSY", "input         COREMEM_BUSY", "mem_waitrequest"),
    ("BURSTCNT", "output  [7:0] COREMEM_BURSTCNT", "mem_burstcount"),
    ("ADDR", "output [28:0] COREMEM_ADDR", "mem_address"),
    ("DOUT", "input  [63:0] COREMEM_DOUT", "mem_readdata"),
    ("DOUT_READY", "input         COREMEM_DOUT_READY", "mem_readdatavalid"),
    ("RD", "output        COREMEM_RD", "mem_read"),
    ("DIN", "output [63:0] COREMEM_DIN", "mem_writedata"),
    ("BE", "output  [7:0] COREMEM_BE", "mem_byteenable"),
    ("WE", "output        COREMEM_WE", "mem_write"),
]

RULES = [
    # --- VHDL library mem: Quartus compiles rtl/mem.qip and rtl/N64.qip into one library and
    #     resolves mem.X and work.X alike (RamMLAB is used as both); Vivado: everything in work
    ("mem-library-clause", "rtl/**/*.vhd", regex(r"(?im)^(\s*)library\s+mem\s*;", r"\1-- library mem;  (Vivado: work)"), 32),
    ("mem-library-names", "rtl/**/*.vhd", regex(r"(?i)\b(entity|use)(\s+)mem\.", r"\1\2work."), 47),

    # --- N64.sv: SDRAM_* to 'Z next to the drivers of sdram (.*) and pll (SDRAM_CLK):
    #     Quartus resolves the tri-state, Vivado reports multiple drivers
    ("sdram-z", "N64.sv",
     literal("assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, "
             "SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;",
             "// SDRAM_* driven by sdram and pll (Vivado: no second driver 'Z)"), 1),

    # --- N64.sv: SNAC off (n64top inputs idle above, PADTYPE0 never SNAC): the always block
    #     assigned the nets USER_OUT and dataIn; USER_OUT all ones as with snac = 0
    ("snac-user-out", "N64.sv",
     regex(r"(?s)always @\(posedge clk_1x\) begin\n\tif \(snac\) begin\n.*?\t\tUSER_OUT <= '1;\n\tend\nend\n",
           "// SNAC off (cores/n64/rules.py): USER_OUT as with snac = 0\n"
           "assign USER_OUT = '1;\nassign dataIn = 1'b1;\n"), 1),

    # --- RDP colour combiner, blender, Z buffer, colour correction and texel unit: their
    #     multipliers and adders in DSP48 (use_dsp "yes" on the entity).  OOC emu at 2/3:
    #     43 800 -> 42 579 LUT, 63 -> 122 DSP, clk_1x WNS +1.805 -> +2.641 ns after synthesis
    ("rdp-use-dsp", "rtl/RDP_*.vhd",
     regex(r"(?ms)^(entity (RDP_(?:BlendColor|CombineAlpha|CombineColor|RGBACorrection|TexSingle|Zbuffer)) is\n.*?)^end entity;",
           r'\1   attribute use_dsp : string;\n   attribute use_dsp of \2 : entity is "yes";\nend entity;'), 6),
] + [("option-" + old.split("(")[0].strip(". ").lower(), "N64.sv", literal(old, new), 1)
     for old, new in OPTION_CONSTANTS] + [
    # --- stage D: rtl/sdram.sv is replaced by cores/n64/sdram.vhd (core.tcl), whose Avalon master
    #     mem_* goes out as emu port COREMEM_* (sys_top_zynq: ZYNQ_coremem_*, MISTER_ZYNQ_COREMEM)
    ("coremem-port-" + emu.lower(), "N64.sv", add_port("emu", decl), 1) for emu, decl, _ in COREMEM
] + [
    ("coremem-connect-" + emu.lower(), "N64.sv", connect_port("sdram", mem, "COREMEM_" + emu), 1)
    for emu, _, mem in COREMEM
]
