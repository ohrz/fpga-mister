# ----------------------------------------------------------------------------------
#  Title      : PSX core profile: Vivado source rules for PSX_MiSTer
#  Project    : fpga-mister
#  File       : rules.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-31
# ----------------------------------------------------------------------------------
#  Description: Read by scripts/prepare_sources.py (passed by mister_project.tcl).
#               RULES: (name, file glob, function, expected count over the tree or None),
#               functions from RULE_API of prepare_sources.py.  A count that differs
#               from the expected one stops the build: the upstream source changed.
#               Rule or patch: doc/PORTING.md §4.  Profile decisions: OSD
#               options as constants to fit the xc7z020, savestates off (rtl/savestates.vhd
#               replaced by cores/psx/savestates.vhd), SNAC and fast forward off.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------

# psx_mister port connections and option wires in PSX.sv: OSD option -> constant (the
# "Off" or default setting).  The menu still shows the options; they have no effect.
OPTION_CONSTANTS = [
    # unsafe / homebrew options off: 2 MB RAM, no turbo, original CD timing
    ("   .ram8mb(status[85]),", "   .ram8mb(1'b0),"),
    ("   TURBO_MEM      <= status[80:79] > 0;", "   TURBO_MEM      <= 1'b0;"),
    ("   TURBO_COMP     <= status[80:79] == 2'b11;", "   TURBO_COMP     <= 1'b0;"),
    ("   TURBO_CACHE    <= status[80];", "   TURBO_CACHE    <= 1'b0;"),
    ("   TURBO_CACHE50  <= status[80:79] == 2'b10;", "   TURBO_CACHE50  <= 1'b0;"),
    ("   .INSTANTSEEK(status[21]),", "   .INSTANTSEEK(1'b0),"),
    ("   .FORCECDSPEED(status[77:75]),", "   .FORCECDSPEED(3'd0),"),
    ("   .LIMITREADSPEED(status[78]),", "   .LIMITREADSPEED(1'b0),"),
    ("   .IGNORECDDMATIMING(status[88]),", "   .IGNORECDDMATIMING(1'b0),"),
    ("   .pauseOnCDSlow(~status[72]),", "   .pauseOnCDSlow(1'b1),"),
    ("   .drawSlow(status[90]),", "   .drawSlow(1'b0),"),
    ("   .pal60           (status[15]),", "   .pal60           (1'b0),"),
    # video hacks and enhancements off: 480i/480p hack (and with it the DDR frame buffer
    # mode), 24-bit rendering and dither, texture filter, widescreen, rotation, 480i sync
    ("wire hack_480p = status[89];", "wire hack_480p = 1'b0;"),
    ("   .interlaced480pHack(status[89]),", "   .interlaced480pHack(1'b0),"),
    ("   .render24(status[84] && ~hack_480p),", "   .render24(1'b0),"),
    ("   .dither24(status[73]),", "   .dither24(1'b0),"),
    ("   .textureFilter(status[82:81]),", "   .textureFilter(2'b00),"),
    ("   .textureFilterStrength(status[87:86]),", "   .textureFilterStrength(2'b00),"),
    ("   .textureFilter2DOff(status[83]),", "   .textureFilter2DOff(1'b0),"),
    ("   .WIDESCREEN(status[54:53]),", "   .WIDESCREEN(2'b00),"),
    ("   .rotate180(status[24]),", "   .rotate180(1'b0),"),
    ("   .syncInterlace(status[60]),", "   .syncInterlace(1'b0),"),
    # overlays off (gun crosshair, FPS, CD slow/seek, error, LBA)
    ("   .showGunCrosshairs(status[9]),", "   .showGunCrosshairs(1'b0),"),
    ("   .fpscountOn(status[28]),", "   .fpscountOn(1'b0),"),
    ("   .cdslowOn(status[59]),", "   .cdslowOn(1'b0),"),
    ("   .testSeek(status[70]),", "   .testSeek(1'b0),"),
    ("   .errorOn(status[74]),", "   .errorOn(1'b0),"),
    ("   .LBAOn(status[69]),", "   .LBAOn(1'b0),"),
    # debug page (h3, L3+R3+Select) at its defaults: video out on, textures and sound on
    ("   .videoout_on     (~status[14]),", "   .videoout_on     (1'b1),"),
    ("   .noTexture(status[27]),", "   .noTexture(1'b0),"),
    ("   .SPUon(~status[30]),", "   .SPUon(1'b1),"),
    ("   .SPUIRQTrigger(status[2]),", "   .SPUIRQTrigger(1'b0),"),
    ("   .REPRODUCIBLESPUDMA(status[43]),", "   .REPRODUCIBLESPUDMA(1'b0),"),
    # controllers: Dualshock, digital, analog (and off) only; no light guns, NeGcon,
    # wheels, mouse, analog joystick, Pop'n, SNAC, multitap
    ("wire PadPortGunCon1  = (status[48:45] == 4'b0100);", "wire PadPortGunCon1  = 1'b0;"),
    ("wire PadPortNeGcon1  = (status[48:45] == 4'b0101) || (status[48:45] == 4'b0110);", "wire PadPortNeGcon1  = 1'b0;"),
    ("wire PadPortWheel1   = (status[48:45] == 4'b0110) || (status[48:45] == 4'b0111);", "wire PadPortWheel1   = 1'b0;"),
    ("wire PadPortMouse1   = (status[48:45] == 4'b1000);", "wire PadPortMouse1   = 1'b0;"),
    ("wire PadPortJustif1  = (status[48:45] == 4'b1001);", "wire PadPortJustif1  = 1'b0;"),
    ("wire snacPort1       = (status[48:45] == 4'b1010) && ~multitap;", "wire snacPort1       = 1'b0;"),
    ("wire PadPortStick1   = (status[48:45] == 4'b1011);", "wire PadPortStick1   = 1'b0;"),
    ("wire PadPortPopn1    = (status[48:45] == 4'b1100);", "wire PadPortPopn1    = 1'b0;"),
    ("wire PadPortGunCon2  = (status[52:49] == 4'b0100);", "wire PadPortGunCon2  = 1'b0;"),
    ("wire PadPortNeGcon2  = (status[52:49] == 4'b0101) || (status[52:49] == 4'b0110);", "wire PadPortNeGcon2  = 1'b0;"),
    ("wire PadPortWheel2   = (status[52:49] == 4'b0110) || (status[52:49] == 4'b0111);", "wire PadPortWheel2   = 1'b0;"),
    ("wire PadPortMouse2   = (status[52:49] == 4'b1000);", "wire PadPortMouse2   = 1'b0;"),
    ("wire PadPortJustif2  = (status[52:49] == 4'b1001);", "wire PadPortJustif2  = 1'b0;"),
    ("wire snacPort2       = (status[52:49] == 4'b1010) && ~multitap;", "wire snacPort2       = 1'b0;"),
    ("wire PadPortStick2   = (status[52:49] == 4'b1011);", "wire PadPortStick2   = 1'b0;"),
    ("wire PadPortPopn2    = (status[52:49] == 4'b1100);", "wire PadPortPopn2    = 1'b0;"),
    ("wire multitap        = (status[57:56] != 2'b00);", "wire multitap        = 1'b0;"),
    ("wire multitapDigital = (status[57:56] == 2'b01);", "wire multitapDigital = 1'b0;"),
    ("wire multitapAnalog  = (status[57:56] == 2'b10);", "wire multitapAnalog  = 1'b0;"),
    ("   .enableNeGconRumble(status[91]),", "   .enableNeGconRumble(1'b0),"),
    ("   .snacMC(status[66]),", "   .snacMC(1'b0),"),
    # savestates off (cores/psx/savestates.vhd keeps only the reset sequence)
    ("   .save_state            (ss_save),", "   .save_state            (1'b0),"),
    ("   .load_state            (ss_load),", "   .load_state            (1'b0),"),
    ("\t.allow_ss       (cart_loaded   ),", "\t.allow_ss       (1'b0          ),"),
    # cheats off
    ("   .cheats_enabled(~status[6] && ~TURBO_MEM && ~ioctl_download),", "   .cheats_enabled(1'b0),"),
    ("   .cheat_on(gg_valid),", "   .cheat_on(1'b0),"),
    # fast forward off (pll2 has no 85 MHz source, cores/psx/pll2.vhd)
    ("wire FFrequest = joy[17] && ~FB_LL && ~DIRECT_VIDEO;", "wire FFrequest = 1'b0;"),
    # PAL video clock straight from isPal (pll2.vhd synchronises it): cfg_block ignores a region change
    # while a sequence runs (state <= state + 1 wins over state <= 1), and with pll_cfg's waitrequest
    # always low a sequence takes 16 cycles; on the board the last sequence wrote NTSC and left
    # pald2 = 1 with the PAL source deselected (ILA 2026-10-31)
    ("   .reconfig_to_pll(reconfig_to_pll),", "   .reconfig_to_pll({63'd0, isPal}),"),
]

# emu port COREMEM_<name> (as DDRAM_*), its declaration, port of cores/psx/sdram.vhd
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
    # --- VHDL library mem: Quartus compiles rtl/mem.qip and rtl/psx.qip into one library and
    #     resolves mem.X and work.X alike (dpram is bound as both); Vivado: everything in work
    ("mem-library-clause", "rtl/**/*.vhd", regex(r"(?im)^(\s*)library\s+mem\s*;", r"\1-- library mem;  (Vivado: work)"), 20),
    ("mem-library-names", "rtl/**/*.vhd", regex(r"(?i)\b(entity|use)(\s+)mem\.", r"\1\2work."), 38),

    # --- savestates off: Main does not save or load state files (the core cannot); the
    #     CONF_STR entry SS<base>:<size> made Main load them into 0x3E00_0000 of the DDR
    ("conf-no-savestates", "PSX.sv", literal('"PSX;SS3E000000:400000;",', '"PSX;;",'), 1),

    # --- PSX.sv: VGA_DISABLE (an emu output net) was assigned in the always_ff block of the
    #     video aspect logic; fast forward is off (OPTION_CONSTANTS), so it is 0
    ("vga-disable-proc", "PSX.sv", literal("\tVGA_DISABLE <= fast_forward;\n", ""), 1),
    ("vga-disable-assign", "PSX.sv", literal("assign CE_PIXEL = ce_pix;\n",
                                             "assign CE_PIXEL = ce_pix;\nassign VGA_DISABLE = 1'b0;   // fast forward off (cores/psx/rules.py)\n"), 1),

    # --- PSX.sv: SNAC off (both ports never SNAC above): the always block assigned the emu
    #     output USER_OUT and wires (ack, Dat, irq10Snac, ...); their values with snacPort1/2 = 0
    ("snac-block", "PSX.sv",
     regex(r"(?s)always @\(posedge clk_1x\)\nbegin\n\n   USER_IN3_1 <= USER_IN\[3\];\n.*?\n\tend\nend\n\nendmodule",
           "// SNAC off (cores/psx/rules.py): the values of the SNAC block with snacPort1/2 = 0\n"
           "assign USER_OUT          = '1;\n"
           "assign irq10Snac         = 1'b0;\n"
           "assign ack               = 1'b1;\n"
           "assign receiveBufferSnac = 8'd0;\n"
           "assign receiveValidSnac  = 1'b0;\n"
           "assign actionNextSnac    = 1'b0;\n\n"
           "endmodule"), 1),
] + [("option-" + old.strip().split("(")[0].split("<=")[0].split("=")[0].strip(". ").replace("wire ", "").lower(),
      "PSX.sv", literal(old, new), 1)
     for old, new in OPTION_CONSTANTS] + [
    # --- stage D: rtl/sdram.sv is replaced by cores/psx/sdram.vhd (core.tcl), whose Avalon master
    #     mem_* goes out as emu port COREMEM_* (sys_top_zynq: ZYNQ_coremem_*, MISTER_ZYNQ_COREMEM).
    #     The port list of emu is only `include "sys/emu_ports.vh" (ANSI): add_port would take
    #     it for a non-ANSI list, so the declarations go in front of the include
    ("coremem-ports", "PSX.sv",
     literal('module emu\n(\n\t`include "sys/emu_ports.vh"\n);',
             "module emu\n(\n" + "".join("\t%s,\n" % decl for _, decl, _ in COREMEM)
             + '\t`include "sys/emu_ports.vh"\n);'), 1),
    # only the instance sdram (sdram2 in `ifdef MISTER_DUAL_SDRAM stays as it is)
    ("coremem-connect", "PSX.sv",
     literal("sdram sdram\n(\n",
             "sdram sdram\n(\n" + "".join("\t.%s(COREMEM_%s),\n" % (mem, emu) for emu, _, mem in COREMEM)), 1),

    # --- use before declaration (Synth 8-6901/8-8895: Quartus takes the later declaration,
    #     Vivado an implicit net): PSX.sv connects reconfig_to_pll, sdram_addr,
    #     spuram_*, ... before their declarations, hps_ext.v uses io_dout, dout_en and the
    #     localparams CD_GET/CD_SET (in EXT_CMD_MIN/MAX) before theirs.  After all PSX.sv rules
    ("hps-ext-localparam-order", "rtl/hps_ext.v",      # CRLF file
     regex(r"(localparam EXT_CMD_MIN = CD_GET;\r?\nlocalparam EXT_CMD_MAX = CD_SET;\r?\n)(\r?\n)"
           r"(localparam CD_GET = 'h34;\r?\nlocalparam CD_SET = 'h35;\r?\n)", r"\3\2\1"), 1),
    ("declarations-first-hps-ext", "rtl/hps_ext.v", declarations_first, 10),
    # the members of typedef struct vid_info would count as module declarations: one line
    ("struct-one-line", "PSX.sv",
     regex(r"typedef struct \{\n((?:\t[^\n]*\n)+)\} vid_info;",
           lambda m: "typedef struct { " + " ".join(m.group(1).split()) + " } vid_info;"), 1),
    ("declarations-first-psx", "PSX.sv", declarations_first, 279),
]
