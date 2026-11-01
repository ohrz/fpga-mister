#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Prepare MiSTer sources for Vivado
#  Project    : fpga-mister
#  File       : prepare_sources.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-28
# ----------------------------------------------------------------------------------
#  Description: Copies a MiSTer source tree (a pinned checkout in _Checkouts/, never
#               edited) to a build directory and makes it readable for Vivado:
#                 1. named source rules for constructs Quartus accepts and Vivado does
#                    not (each rule reports how often it applied; a rule with an
#                    expected count fails the run when the count differs, so an
#                    upstream change shows up instead of slipping through):
#                    the rules of the core profile (cores/<core>/rules.py, list RULES,
#                    written with the helpers of RULE_API) and the generic rules
#                    (GENERIC_RULES, unless the profile lists them with a count)
#                 2. the same rules for the MiSTer framework copy sys/ of every source
#                    tree (SYS_RULES; each core carries its own, possibly older, sys/)
#                    and the spelling of named connections in Verilog instances of VHDL
#                    entities (fix_vhdl_port_case: Vivado matches them case-sensitively),
#                    .mif files converted to .mem with absolute names in the HDL
#                    (convert_mif_files)
#                 3. sys/sys_top_modules.sv: the helper modules at the end of sys/sys_top.v
#                    (sync_fix, csync; arcade_video.v needs sync_fix), listed in sys/sys.qip,
#                    so they stay when the port replaces sys_top.v
#                 4. sys/sys_top_zynq.sv: sys_top.v with the Cyclone V hard blocks and Quartus
#                    PLLs as ports ZYNQ_* (make_sys_top_zynq), listed in sys/sys.qip
#                 5. build_id.v (`define BUILD_DATE, made by sys/build_id.tcl in Quartus)
#                 6. the patches of the port in sorted order (git apply): those of a core in
#                    cores/<core>/patches/ of the profile with core_name <name>, the others
#                    (Main_MiSTer) in firmware/common/mister/patches/<name>/
#               Usage:
#                 prepare_sources.py <name> <source dir> <destination dir> [<rules.py>]
#                 prepare_sources.py --patch-dirs   "<name> <dir>" per checkout with patches
#               <name> is the checkout name (MSX_MiSTer, Template_MiSTer, ...), <rules.py>
#               the rules of its core profile (mister_project.tcl passes it when the
#               profile has one).  The destination is removed and recreated.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------

"""prepare_sources.py <name> <source dir> <destination dir> [<rules.py>]
prepare_sources.py --patch-dirs

Copies a MiSTer source tree for Vivado: source rules, sys/sys_top_zynq.sv, patches
(see the file header)."""

import os
import pathlib
import re
import shutil
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
PATCH_ROOT = HERE.parent / "patches"
CORES = HERE.parent / "cores"


def patch_dirs():
    """{checkout name: patch directory}: cores/<core>/patches/ of the profile whose core.tcl
    sets core_name, else patches/<name>/ (checkouts without a core profile, Main_MiSTer)."""
    dirs = {d.name: d for d in sorted(PATCH_ROOT.glob("*")) if d.is_dir()}
    for tcl in sorted(CORES.glob("[!_]*/core.tcl")):
        m = re.search(r"^set\s+core_name\s+(\S+)", tcl.read_text(), re.M)
        if m and (tcl.parent / "patches").is_dir():
            if m.group(1) in dirs:
                raise SystemExit(f"ERROR: patches of {m.group(1)} in {dirs[m.group(1)]} and {tcl.parent / 'patches'}")
            dirs[m.group(1)] = tcl.parent / "patches"
    return {n: d for n, d in dirs.items() if any(d.glob("*.patch"))}

# VHDL: "label : work.ent [port map | generic map]" without the keyword "entity"
# (Quartus instantiates the entity, VHDL and Vivado require "entity work.ent" or a
# component declaration).  Only instance lines: the label is the first word and
# nothing but port/generic map follows the entity name.
VHDL_DIRECT_INST = re.compile(
    r"^(?P<pre>\s*\w+\s*:\s*)(?P<ent>work\.\w+(?:\s*\(\s*\w+\s*\))?)(?P<post>\s*(?:(?:port|generic)\s+map\b.*)?)$",
    re.IGNORECASE)


def rule_vhdl_direct_instantiation(text):
    count = 0

    def fix(m):
        nonlocal count
        count += 1
        return m.group("pre") + "entity " + m.group("ent") + m.group("post")

    lines = [VHDL_DIRECT_INST.sub(fix, line) for line in text.split("\n")]
    return "\n".join(lines), count


# VHDL: a conditional signal assignment ending in "... when c else null;" (Quartus keeps the
# old value, a latch).  VHDL allows the null waveform only in guarded assignments; Vivado
# rejects it.  The last choice becomes all zeros: only for vector targets whose value does
# not matter when no condition holds (checked per use, see the expected counts).
def rule_vhdl_null_waveform(text):
    count = 0
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if line.strip().lower() != "null;" or i == 0:
            continue
        prev = lines[i - 1].split("--")[0].lower()
        if re.search(r"\bwhen\b", prev) and re.search(r"\belse\s*$", prev.rstrip()):
            lines[i] = line.lower().replace("null;", "(others => '0');")
            count += 1
    return "\n".join(lines), count


# exact text replacement for a single known construct (expected count in RULES)
def literal(old, new):
    def rule(text):
        return text.replace(old, new), text.count(old)
    return rule


# regular expression replacement (re.subn); count = replacements
def regex(pattern, repl, flags=0):
    rx = re.compile(pattern, flags)

    def rule(text):
        return rx.subn(repl, text)
    return rule


# SystemVerilog: move declarations out of a generate block to module scope (Quartus
# lets code outside the block use them, Vivado does not).  decls: the declaration lines
# (stripped), anchor: a module scope line the declarations are put in front of.  Count:
# declarations moved (all of them, or the anchor is missing: 0).
def hoist(decls, anchor):
    def rule(text):
        lines = text.split("\n")
        if anchor not in [l.strip() for l in lines]:
            return text, 0
        moved = 0
        for i, line in enumerate(lines):
            if line.strip() in decls and line != line.lstrip():
                lines[i] = line[:len(line) - len(line.lstrip())] + "// moved to module scope (Vivado): " + line.strip()
                moved += 1
        if moved != len(decls):
            return text, moved
        at = [l.strip() for l in lines].index(anchor)
        lines[at:at] = ["// moved from a generate block (Vivado)"] + decls
        return "\n".join(lines), moved
    return rule


# --- falling edges of a derived core clock (hdl/clk_pulse_div.vhd) ---
# A derived core clock is a pulse of the gated master clock, high for one master high
# time: logic at its falling edge gets that time instead of half the period of the DE10.
# The PLL replacement adds the mid clock (clk_pulse_div clk_mid, G_MID = G_DIV/2: the
# master pulse where the DE10 clock falls); falling_edge_to moves the falling edges of a
# file to its rising edges, add_port and connect_port carry it from the PLL to the
# modules.  Each counts what it changed (the expected count in RULES).

def close_paren(text, i):
    """Index after the bracket that closes the "(" at text[i]."""
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
    return len(text)


def skip_space(text, i):
    while i < len(text) and text[i].isspace():
        i += 1
    return i


# falling edges of clock -> rising edges of mid: Verilog "negedge clock" and inverted
# clocks on named ports ".p(~clock)", VHDL "falling_edge(clock)" and "=> not clock".  A
# VHDL process with a moved edge gets mid in its sensitivity list, in place of clock
# when the process no longer uses clock.  Count: edges and ports moved.
def falling_edge_to(clock, mid):
    c = re.escape(clock)
    v_neg = re.compile(r"\bnegedge(\s+)%s(?![\w$])" % c)
    v_inv = re.compile(r"(\.\w+\s*\(\s*)[~!]\s*%s(\s*\))" % c)
    h_fall = re.compile(r"\bfalling_edge(\s*)\(\s*%s\s*\)" % c, re.I)
    h_not = re.compile(r"(=>\s*)not\s+%s\b" % c, re.I)
    h_name = re.compile(r"\b%s\b" % c, re.I)
    h_proc = re.compile(r"\bprocess\s*\(([^)]*)\)(.*?)\bend\s+process\b", re.I | re.S)

    def rule(text):
        count = 0

        def proc(m):
            nonlocal count
            body, n = h_fall.subn(r"rising_edge\1(%s)" % mid, m.group(2))
            if not n:
                return m.group(0)
            count += n
            names = [s.strip() for s in m.group(1).split(",")]
            if h_name.search(body):
                names.append(mid)
            else:
                names = [mid if s.lower() == clock.lower() else s for s in names]
            o = m.start(0)
            return (m.string[o:m.start(1)] + ", ".join(names) + m.string[m.end(1):m.start(2)] + body
                    + m.string[m.end(2):m.end(0)])

        text = h_proc.sub(proc, text)
        for rx, repl in ((h_fall, r"rising_edge\1(%s)" % mid), (h_not, r"\g<1>%s" % mid),
                         (v_neg, r"posedge\g<1>%s" % mid), (v_inv, r"\g<1>%s\g<2>" % mid)):
            text, n = rx.subn(repl, text)
            count += n
        return text, count
    return rule


# a port as the first one of a module: decl is the Verilog declaration ("input clk_mid";
# ANSI port list, or a non-ANSI list: the name in the list, the declaration after it)
# or the VHDL interface declaration ("CLK_MID : in std_logic") of the entity.
# Count: modules changed (0 or 1).
def add_port(module, decl):
    v_mod = re.compile(r"\bmodule\s+%s(?![\w$])" % re.escape(module))
    h_ent = re.compile(r"\bentity\s+%s\s+is\b" % re.escape(module), re.I)

    def rule(text):
        m = h_ent.search(text)
        if m:
            p = re.compile(r"\bport\s*\(", re.I).search(text, m.end())
            e = re.compile(r"\bend\b", re.I).search(text, m.end())
            if not p or (e and e.start() < p.start()):
                return text, 0
            return text[:p.end()] + "\n\t\t%s;" % decl + text[p.end():], 1
        m = v_mod.search(text)
        if not m:
            return text, 0
        i = skip_space(text, m.end())
        if text.startswith("#", i):
            i = close_paren(text, text.index("(", i))
            i = skip_space(text, i)
        if not text.startswith("(", i):
            return text, 0
        end = close_paren(text, i)
        ports = text[i + 1:end - 1]
        sep = "" if not ports.strip() else ","
        # ANSI port list (also `include of ANSI declarations, MiSTer's sys/emu_ports.vh)
        if (not ports.strip() or re.search(r"\b(input|output|inout)\b", outside_brackets(ports))
                or "`include" in ports):
            return text[:i + 1] + "\n\t%s%s" % (decl, sep) + text[i + 1:], 1
        name = re.findall(r"[A-Za-z_][\w$]*", decl)[-1]
        semi = text.index(";", end)
        return (text[:i + 1] + "%s%s " % (name, sep) + text[i + 1:semi + 1] + "\n\t%s;" % decl
                + text[semi + 1:]), 1
    return rule


# a named connection port => net as the first one of every instance of module: Verilog
# "module [#(...)] inst (", VHDL "inst : [entity lib.]module ... port map (".  Instances
# with positional connections stay unchanged (not counted).  Count: instances changed.
def connect_port(module, port, net):
    m_ = re.escape(module)
    v_use = re.compile(r"(?<![\w$.])%s(?![\w$])" % m_)
    h_inst = re.compile(r"\b\w+\s*:\s*(?:entity\s+\w+\.|component\s+)?%s\b" % m_, re.I)
    h_map = re.compile(r"\bport\s+map\s*\(", re.I)

    def rule(text):
        out, at, count = [], 0, 0
        for m in h_inst.finditer(text):
            p = h_map.search(text, m.end())
            if p and ";" not in text[m.end():p.start()]:
                out.append(text[at:p.end()] + "\n\t\t%s => %s," % (port, net))
                at, count = p.end(), count + 1
        if count:
            return "".join(out) + text[at:], count
        for m in v_use.finditer(text):                  # declarations fail the checks below
            i = skip_space(text, m.end())
            if text.startswith("#", i):
                i = skip_space(text, close_paren(text, text.index("(", i)))
            n = re.compile(r"[A-Za-z_][\w$]*(\s*\[[^\]]*\])?\s*\(").match(text, i)
            if not n:
                continue
            j = n.end()                                  # after "(" of the connections
            first = text[skip_space(text, j):skip_space(text, j) + 1]
            if first not in (".", ")"):
                continue                                 # positional connections
            out.append(text[at:j] + "\n\t.%s(%s)%s" % (port, net, "" if first == ")" else ","))
            at, count = j, count + 1
        return "".join(out) + text[at:], count
    return rule


# video_mixer.sv: R_in/G_in/B_in are declared with an initializer in both branches of a
# generate if and used after it.  One declaration in front of the generate (width of
# the wider branch is fine: the users take the low bits), assignments in the branches.
VM_DECL = re.compile(r"^(\s*)wire\s+\[[^\]]+\]\s+([RGB]_in)\s*=\s*(.*)$")


def rule_video_mixer_scope(text):
    lines = text.split("\n")
    count = 0
    first = None
    for i, line in enumerate(lines):
        m = VM_DECL.match(line)
        if m:
            lines[i] = f"{m.group(1)}assign {m.group(2)} = {m.group(3)}"
            count += 1
            first = i if first is None else first
    if count != 6:
        return text, count
    gen = max(i for i in range(first) if lines[i].strip() == "generate")
    lines.insert(gen, "wire [((GAMMA && HALF_DEPTH) ? 7 : DWIDTH):0] R_in, G_in, B_in;  // one declaration (Vivado)")
    return "\n".join(lines), count


PS2_DECLS = ["reg  [7:0] kbd_data;", "reg        kbd_we;", "wire [8:0] kbd_data_host;", "reg        kbd_rd;",
             "reg  [7:0] mouse_data;", "reg        mouse_we;", "wire [8:0] mouse_data_host;", "reg        mouse_rd;"]

# rules for <tree>/sys/ (the MiSTer framework; the same for every core that has it)
SYS_RULES = [
    # outputs assigned in always blocks need "reg" (Vivado error, Quartus accepts)
    ("sys-ddr-svc-output-reg", "sys/ddr_svc.sv",
     literal("output  [7:0] ram_bcnt,", "output reg [7:0] ram_bcnt,"), 1),
    ("sys-hq2x-output-reg", "sys/hq2x.sv", literal("output [23:0] Result", "output reg [23:0] Result"), 1),
    # PS/2 keyboard/mouse signals of hps_io: declared in "generate if(PS2DIV)", used outside
    ("sys-hps-io-ps2-scope", "sys/hps_io.sv",
     hoist(PS2_DECLS, "localparam MAX_W = $clog2((64 > (STRLEN+2)) ? 64 : (STRLEN+2))-1;"), 8),
    ("sys-video-mixer-scope", "sys/video_mixer.sv", rule_video_mixer_scope, 6),
]

# helper modules defined in sys/sys_top.v after module sys_top (the port replaces sys_top.v)
SYS_TOP_HELPERS = ["sync_fix", "csync"]


def extract_sys_top_helpers(sys_dir):
    top = sys_dir / "sys_top.v"
    text = top.read_bytes().decode("latin-1")
    found = []
    out = ["// Helper modules of sys_top.v, extracted by prepare_sources.py (fpga-mister):",
           "// the port replaces sys_top.v, other sys/ files use these modules.", ""]
    for name in SYS_TOP_HELPERS:
        m = re.search(r"^module\s+%s\b.*?^endmodule\b" % name, text, re.MULTILINE | re.DOTALL)
        if m:
            out += [m.group(0), ""]
            found.append(name)
    (sys_dir / "sys_top_modules.sv").write_text("\n".join(out))
    with open(sys_dir / "sys.qip", "a") as qip:
        qip.write("\nset_global_assignment -name SYSTEMVERILOG_FILE [file join $::quartus(qip_path) sys_top_modules.sv ]\n")
    return len(found)


# sys_top.v -> sys/sys_top_zynq.sv (module sys_top_zynq): the Cyclone V hard blocks and
# Quartus PLLs of sys_top become ports ZYNQ_<instance>_<port>, everything else of sys_top
# (HPS bus logic, system commands, ascal, OSD, audio_out, ...) stays as it is.  A port the
# block reads becomes an output of sys_top_zynq, a port it drives an input; the top level of
# the board (firmware/common/mister/hdl/mister_zynq.vhd) connects them to the Zynq parts.
# (type, instance, {block port: (direction seen from the block, width)})
ZYNQ_HOIST = [
    ("cyclonev_hps_interface_mpu_general_purpose", "h2f_gp", {"gp_in": ("in", 32), "gp_out": ("out", 32)}),
    ("cyclonev_hps_interface_peripheral_uart", "uart",
     {"ri": ("in", 1), "dsr": ("in", 1), "dcd": ("in", 1), "cts": ("in", 1), "rxd": ("in", 1),
      "dtr": ("out", 1), "rts": ("out", 1), "txd": ("out", 1)}),
    ("cyclonev_hps_interface_interrupts", "interrupts", {"irq": ("in", 64)}),
    ("sysmem_lite", "sysmem",
     dict([("clock", ("out", 1)), ("reset_out", ("out", 1)), ("reset_hps_cold_req", ("in", 1)),
           ("reset_hps_warm_req", ("in", 1)), ("reset_core_req", ("in", 1))] +
          [(f"{p}_{s}", d) for p, aw, dw in (("ram1", 29, 64), ("ram2", 29, 64), ("vbuf", 29, 64))
           for s, d in (("clk", ("in", 1)), ("address", ("in", aw)), ("burstcount", ("in", 8)),
                        ("waitrequest", ("out", 1)), ("readdata", ("out", dw)), ("readdatavalid", ("out", 1)),
                        ("read", ("in", 1)), ("writedata", ("in", dw)), ("byteenable", ("in", dw // 8)),
                        ("write", ("in", 1)))])),
    ("pll_hdmi", "pll_hdmi", {"refclk": ("in", 1), "rst": ("in", 1), "outclk_0": ("out", 1),
                              "reconfig_to_pll": ("in", 64), "reconfig_from_pll": ("out", 64)}),
    ("pll_cfg_hdmi", "pll_cfg_hdmi",
     {"mgmt_clk": ("in", 1), "mgmt_reset": ("in", 1), "mgmt_waitrequest": ("out", 1), "mgmt_write": ("in", 1),
      "mgmt_address": ("in", 6), "mgmt_writedata": ("in", 32), "reconfig_to_pll": ("out", 64),
      "reconfig_from_pll": ("in", 64)}),
    ("cyclonev_hps_interface_peripheral_i2c", "hdmi_i2c",
     {"out_clk": ("out", 1), "scl": ("in", 1), "out_data": ("out", 1), "sda": ("in", 1)}),
    ("cyclonev_clkselect", "hdmi_clk_sw", {"clkselect": ("in", 2), "inclk": ("in", 4), "outclk": ("out", 1)}),
    ("cyclonev_clkselect", "vga_clk_sw", {"clkselect": ("in", 2), "inclk": ("in", 4), "outclk": ("out", 1)}),
    ("pll_audio", "pll_audio", {"refclk": ("in", 1), "rst": ("in", 1), "outclk_0": ("out", 1)}),
    ("cyclonev_hps_interface_peripheral_spi_master", "spi",
     {"sclk_out": ("out", 1), "txd": ("out", 1), "rxd": ("in", 1), "ss_0_n": ("out", 1), "ss_in_n": ("in", 1)}),
]

# further changes of sys_top for the Zynq (exact text, expected once each)
ZYNQ_LITERALS = [
    # the core gets the gated core master clock (stage C), sys_top keeps its free running 50 MHz
    (".CLK_50M(FPGA_CLK2_50),", ".CLK_50M(ZYNQ_CLK_CORE),"),
    # ascal on a 64-bit memory port (the HP ports of the Zynq are 64 bit wide)
    (".N_DW(128),", ".N_DW(64),"),
    (".N_AW(28)", ".N_AW(29)"),
    ("wire  [27:0] vbuf_address;", "wire  [28:0] vbuf_address;"),
    ("wire [127:0] vbuf_readdata;", "wire  [63:0] vbuf_readdata;"),
    ("wire [127:0] vbuf_writedata;", "wire  [63:0] vbuf_writedata;"),
    ("wire  [15:0] vbuf_byteenable;", "wire   [7:0] vbuf_byteenable;"),
    # menu core (MENU_CORE): 2048-byte bursts are 256 beats at 64 bit, more than the 8-bit
    # burstcount of the Avalon port; 1024 bytes = 128 beats as on the DE10-Nano (Main_MiSTer
    # takes the picture offset from the ascal header)
    (".N_BURST(2048),", ".N_BURST(1024),"),
    # ascal without the downscaler (its line buffer path limits CLK_VIDEO): for cores whose
    # picture is never larger than the HDMI mode, set by the core profile (core_defines)
    (".FRAC(8),", "`ifdef MISTER_ZYNQ_NO_DOWNSCALE\n\t\t.DOWNSCALE(0),\n\t`endif\n\t\t.FRAC(8),"),
    # audio_out replaced for a core at the area limit, set by the core profile (core_defines):
    # MISTER_ZYNQ_NO_AUDIO silent (I2S to the HDMI transmitter and codec, DAC, S/PDIF at 0);
    # MISTER_ZYNQ_SIMPLE_AUDIO the core audio straight to I2S (hdl/audio_i2s_simple.vhd, 48 kHz,
    # no filters, volume, S/PDIF and DAC; about 1.6k LUT less than audio_out)
    ("wire spdif;\naudio_out audio_out\n",
     "wire spdif;\n`ifdef MISTER_ZYNQ_NO_AUDIO\n"
     "\tassign {HDMI_SCLK, HDMI_LRCLK, HDMI_I2S, spdif} = 4'b0000;\n"
     "`ifndef MISTER_DUAL_SDRAM\n\tassign {analog_l, analog_r} = 2'b00;\n`endif\n"
     "`elsif MISTER_ZYNQ_SIMPLE_AUDIO\n"
     "audio_i2s_simple audio_i2s_simple\n(\n"
     "\t.clk(clk_audio),\n\t.reset(reset | areset),\n\t.is_signed(audio_s),\n"
     "\t.core_l(audio_l),\n\t.core_r(audio_r),\n"
     "\t.i2s_bclk(HDMI_SCLK),\n\t.i2s_lrclk(HDMI_LRCLK),\n\t.i2s_data(HDMI_I2S)\n);\n"
     "\tassign spdif = 1'b0;\n"
     "`ifndef MISTER_DUAL_SDRAM\n\tassign {analog_l, analog_r} = 2'b00;\n`endif\n"
     "`else\naudio_out audio_out\n"),
    ("\t.spdif(spdif)\n);\n", "\t.spdif(spdif)\n);\n`endif\n"),
    # no direct video on HDMI (the OSD option and MiSTer.ini direct_video have no effect): the HDMI
    # output always comes from ascal, so the VGA OSD and the direct video path drop out (the Zynq
    # boards have no VGA pins).  Set by the core profile (core_defines) of a core at the area limit
    ("\twire    direct_video = cfg[10];\n",
     "`ifdef MISTER_ZYNQ_NO_DIRECT_VIDEO\n\twire    direct_video = 0;\n`else\n"
     "\twire    direct_video = cfg[10];\n`endif\n"),
]

# memory port of a core that replaces its SDRAM controller (stage D, e.g. cores/n64/sdram.vhd): an
# Avalon-MM master named like DDRAM_* (emu port COREMEM_<name>), always a port ZYNQ_coremem_<port>
# of sys_top_zynq; connected to emu only with the Verilog macro MISTER_ZYNQ_COREMEM (core_defines,
# the profile adds the emu ports by rules), else tied off.  mister_zynq: G_COREMEM, HP3.
# (sys_top_zynq port, direction seen from sys_top_zynq, width, emu port suffix)
COREMEM = [("clk", "out", 1, "CLK"), ("address", "out", 29, "ADDR"), ("burstcount", "out", 8, "BURSTCNT"),
           ("waitrequest", "in", 1, "BUSY"), ("readdata", "in", 64, "DOUT"), ("readdatavalid", "in", 1, "DOUT_READY"),
           ("read", "out", 1, "RD"), ("writedata", "out", 64, "DIN"), ("byteenable", "out", 8, "BE"),
           ("write", "out", 1, "WE")]
COREMEM_ANCHOR = "	.DDRAM_CLK(ram_clk),"

# direct video on the HDMI transmitter (MISTER_DEBUG_NOHDMI: no ascal, HDMI_TX_* on CLK_VIDEO;
# mister_zynq G_DIRECT_VIDEO): sys_top's DE of that path is high outside the sync pulses (for VGA
# DACs), the transmitter needs the DE of the picture for its data islands: the DE of the VGA OSD
# output, delayed like the data (dv_d1, dv_d2, dv_data, hdmi_dv_data, d, hdmi_out_d: 6 clk_vid).
DV_DE_OLD = "assign HDMI_TX_DE = hdmi_out_de;"
DV_DE_STAGES = 6

# Boolean generics of ascal (VHDL) are given as strings in sys_top.v. Quartus maps "false" to
# false, Vivado binds every string to true: in the parameter list of ascal 0 and 1 instead.
ASCAL_BOOL = {'("false")': "(0)", '("true")': "(1)"}

PP_LINE = re.compile(r"^\s*`(ifdef|ifndef|else|endif)\b\s*(\w*)")


def pp_stack(lines, upto):
    """Conditional compilation directives in effect at line index upto ([(directive, macro)])."""
    stack = []
    for line in lines[:upto]:
        m = PP_LINE.match(line)
        if not m:
            continue
        if m.group(1) in ("ifdef", "ifndef"):
            stack.append((m.group(1), m.group(2)))
        elif m.group(1) == "else":
            d, mac = stack[-1]
            stack[-1] = ("ifndef" if d == "ifdef" else "ifdef", mac)
        else:
            stack.pop()
    return stack


def instance_span(text, typ, inst):
    """(start, end, connection text) of 'typ [#(...)] inst ( ... );' or None."""
    m = re.search(r"^[ \t]*%s\s*(?:#\s*\(.*?\)\s*)?%s\s*\(" % (re.escape(typ), re.escape(inst)),
                  text, re.MULTILINE | re.DOTALL)
    if not m:
        return None
    depth, i = 1, m.end()
    while depth:
        depth += {"(": 1, ")": -1}.get(text[i], 0)
        i += 1
    end = text.index(";", i) + 1
    return m.start(), end, text[m.end():i - 1]


def make_sys_top_zynq(sys_dir):
    """Writes sys/sys_top_zynq.sv, lists it in sys/sys.qip.  Returns (changes, errors)."""
    text = (sys_dir / "sys_top.v").read_bytes().decode("latin-1")
    errors = []
    # only module sys_top (its helper modules are in sys_top_modules.sv)
    m = re.search(r"^module\s+sys_top\b.*?^endmodule\b", text, re.MULTILINE | re.DOTALL)
    text = m.group(0)
    ports, assigns = [], []
    for typ, inst, pins in ZYNQ_HOIST:
        span = instance_span(text, typ, inst)
        if span is None:
            errors.append(f"instance {typ} {inst} not found")
            continue
        start, end, conns = span
        conns = re.sub(r"//[^\n]*", "", conns)
        lines = text[:start].split("\n")
        stack = pp_stack(lines, len(lines))
        body = []
        for pin, expr in re.findall(r"\.(\w+)\s*\(((?:[^()]|\([^()]*\))*)\)", conns):
            if pin not in pins:
                errors.append(f"{inst}: unknown port {pin}")
                continue
            if not expr.strip():
                continue
            d, w = pins[pin]
            name = f"ZYNQ_{inst}_{pin}"
            rng = f"[{w - 1}:0] " if w > 1 else ""
            ports.append(f"\t{'output' if d == 'in' else 'input '} {rng}{name},")
            body.append(f"assign {name} = {expr.strip()};" if d == "in" else f"assign {expr.strip()} = {name};")
        assigns += [f"`{d} {mac}" for d, mac in stack] + [f"// {typ} {inst}"] + body + ["`endif"] * len(stack)
        text = text[:start] + f"// {typ} {inst}: ports ZYNQ_{inst}_* (fpga-mister)" + text[end:]
    for old, new in ZYNQ_LITERALS:
        if text.count(old) != 1:
            errors.append(f"'{old}' found {text.count(old)} times, expected 1")
        text = text.replace(old, new)
    m = re.search(r"^[ \t]*ascal\s*#\s*\(", text, re.MULTILINE)
    if not m:
        errors.append("ascal parameter list not found")
    else:
        depth, i = 1, m.end()
        while depth:
            depth += {"(": 1, ")": -1}.get(text[i], 0)
            i += 1
        params = text[m.end():i]
        for old, new in ASCAL_BOOL.items():
            params = params.replace(old, new)
        if '"' in params:
            errors.append("ascal: string parameter left")
        text = text[:m.end()] + params + text[i:]
    # ZYNQ_CLK_HDMI_TX: clock of HDMI_TX_* (clk_hdmi, with MISTER_DEBUG_NOHDMI the core's CLK_VIDEO)
    ports += ["\tinput         ZYNQ_CLK_CORE,", "\toutput        ZYNQ_CLK_SYS,", "\toutput        ZYNQ_CLK_HDMI_TX,"]
    assigns += ["assign ZYNQ_CLK_SYS = clk_sys;", "assign ZYNQ_CLK_HDMI_TX = hdmi_tx_clk;"]
    if text.count(DV_DE_OLD) != 1:
        errors.append(f"'{DV_DE_OLD}' found {text.count(DV_DE_OLD)} times, expected 1")
    text = text.replace(DV_DE_OLD, f"`ifndef MISTER_DEBUG_NOHDMI\n{DV_DE_OLD}\n`endif")
    n = DV_DE_STAGES
    assigns += ["`ifdef MISTER_DEBUG_NOHDMI", "// direct video: DE of the picture (VGA OSD output), delayed like the data",
                f"reg [{n - 1}:0] zynq_dv_de;",
                f"always @(posedge clk_vid) zynq_dv_de <= {{zynq_dv_de[{n - 2}:0], vga_de_osd}};",
                f"assign HDMI_TX_DE = zynq_dv_de[{n - 1}];", "`endif"]
    # COREMEM: ports always, connections to emu with MISTER_ZYNQ_COREMEM, else outputs 0
    conns, ties = [], []
    for port, d, w, emu_port in COREMEM:
        rng = f"[{w - 1}:0] " if w > 1 else ""
        ports.append(f"\t{'output' if d == 'out' else 'input '} {rng}ZYNQ_coremem_{port},")
        conns.append(f"\t.COREMEM_{emu_port}(ZYNQ_coremem_{port}),")
        if d == "out":
            ties.append(f"assign ZYNQ_coremem_{port} = 0;")
    if text.count(COREMEM_ANCHOR) != 1:
        errors.append(f"'{COREMEM_ANCHOR.strip()}' found {text.count(COREMEM_ANCHOR)} times, expected 1")
    text = text.replace(COREMEM_ANCHOR, "`ifdef MISTER_ZYNQ_COREMEM\n" + "\n".join(conns) + "\n`endif\n"
                        + COREMEM_ANCHOR)
    assigns += ["`ifndef MISTER_ZYNQ_COREMEM", "// COREMEM unused: tied off"] + ties + ["`endif"]
    # PACE_ALT: the core asks for the second pacer ratio (G_PACE_NUM_ALT / G_PACE_DEN_ALT of
    # mister_zynq, e.g. SNES PAL); emu port ZYNQ_PACE_ALT (added by the profile's rules) with the
    # macro MISTER_ZYNQ_PACE_ALT, else 0
    ports.append("\toutput        ZYNQ_PACE_ALT,")
    text = text.replace(COREMEM_ANCHOR, "`ifdef MISTER_ZYNQ_PACE_ALT\n\t.ZYNQ_PACE_ALT(ZYNQ_PACE_ALT),\n`endif\n"
                        + COREMEM_ANCHOR)
    assigns += ["`ifndef MISTER_ZYNQ_PACE_ALT", "assign ZYNQ_PACE_ALT = 1'b0;", "`endif"]
    head = re.match(r"module\s+sys_top\s*\(", text)
    text = ("// sys_top.v of the MiSTer framework for the Zynq, made by prepare_sources.py (fpga-mister):\n"
            "// Cyclone V hard blocks and Quartus PLLs replaced by ports ZYNQ_*.\n"
            "module sys_top_zynq\n(\n" + "\n".join(ports) + "\n" + text[head.end():])
    text = text[:text.rindex("endmodule")] + "\n".join(
        ["", "// connections of the replaced blocks (at the end: every wire is declared)"] + assigns) + "\n\nendmodule\n"
    (sys_dir / "sys_top_zynq.sv").write_bytes(text.encode("latin-1"))
    with open(sys_dir / "sys.qip", "a") as qip:
        qip.write("set_global_assignment -name SYSTEMVERILOG_FILE [file join $::quartus(qip_path) sys_top_zynq.sv ]\n")
    return len(ZYNQ_HOIST) - sum(e.startswith("instance") for e in errors), errors


# SystemVerilog/Verilog: declarations at module level move to the top of the module (after
# the port list).  Quartus resolves a net used before its declaration to the later
# declaration, Vivado creates an implicit 1-bit wire instead (Synth 8-11241) and the
# connection silently loses all upper bits (SNES: VRAM/BSRAM addresses).  `include and
# `define lines at module level move along in their order (CONF_STR needs build_id.v).
# "wire x = e;" becomes "wire x;" on top and "assign x = e;" in place.  Count: statements
# moved.  Only for files the profile names (expected count): it rewrites the whole module.
DECL_START = re.compile(r"^\s*(wire|reg|logic|integer|localparam|parameter|`include|`define)\b")
WIRE_INIT = re.compile(r"(\s*wire\b(?:\s+signed)?\s*(?:\[[^\]]*\]\s*)*)(\w+)\s*=\s*(.*);(.*)$", re.S)


def outside_brackets(text):
    """text without the contents of (), {} and [] (innermost first)."""
    while True:
        flat = re.sub(r"\([^()]*\)|\{[^{}]*\}|\[[^\[\]]*\]", "", text)
        if flat == text:
            return flat
        text = flat


def rule_declarations_first(text):
    def code(line):
        return re.sub(r'"[^"]*"', '""', re.sub(r"//.*", "", line))
    lines = text.split("\n")
    # block comments blanked for the analysis (the output keeps them)
    plain = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S).split("\n")
    out, count, i = [], 0, 0
    while i < len(lines):
        if not re.match(r"\s*module\b", plain[i]):
            out.append(lines[i])
            i += 1
            continue
        head = i
        while ");" not in code(plain[i]):
            i += 1
        out += lines[head:i + 1]
        moved, body, depth, i = [], [], 0, i + 1
        while i < len(lines) and not re.match(r"\s*endmodule\b", code(plain[i])):
            c = code(plain[i])
            m = DECL_START.match(c)
            if depth == 0 and m:
                j = i
                while not c.lstrip().startswith("`") and ";" not in code(plain[j]):
                    j += 1
                stmt = "\n".join(lines[i:j + 1])
                w = WIRE_INIT.match(stmt) if m.group(1) == "wire" else None
                # a comma outside (), {}, [] of the initial value: a second declarator
                if w and ("," in w.group(1) or "," in outside_brackets(code(w.group(3)))):
                    return text, -1     # several declarators: not handled
                if w:
                    moved.append(w.group(1) + w.group(2) + ";")
                    body.append(re.match(r"\s*", lines[i]).group(0) + "assign " + w.group(2) + " = " + w.group(3) + ";" + w.group(4))
                elif m.group(1) == "wire" and "=" in code(stmt.split(";")[0]):
                    return text, -1     # initial value not recognised: not handled
                else:
                    moved.append(stmt)
                i = j + 1
                continue
            depth += len(re.findall(r"\b(begin|function|task|fork)\b", c))
            depth -= len(re.findall(r"\b(end|endfunction|endtask|join|join_any|join_none)\b", c))
            body.append(lines[i])
            i += 1
        out += ["// declarations moved to the top of the module (Vivado: no use before declaration)"] + moved + body
        count += len(moved)
    return "\n".join(out), count


# Verilog instances of VHDL entities: Vivado binds a named connection ".name(...)" to a
# VHDL port or generic only when the spelling matches exactly, Quartus ignores case.  A
# mismatch leaves the port open without an error (Synth 8-7071) and the logic behind it is
# removed (SNES main.v: ".mclk" for MCLK).  The step reads the ports and generics of every
# VHDL entity of the tree and rewrites the connection names in instances of those entities
# (modules with a Verilog definition of the same name are left alone).  Count: names changed.
def vhdl_interface_names(text):
    """{entity (lower case): {name (lower case): declared spelling}} of a VHDL file."""
    text = re.sub(r"--[^\n]*", "", text)
    result = {}
    for m in re.finditer(r"\bentity\s+(\w+)\s+is\b", text, re.I):
        names, pos = {}, m.end()
        end = re.compile(r"\bend\b", re.I).search(text, pos)
        for g in re.finditer(r"\b(generic|port)\s*\(", text[pos:end.start() if end else len(text)], re.I):
            i, depth = pos + g.end(), 1
            start = i
            while depth and i < len(text):
                depth += {"(": 1, ")": -1}.get(text[i], 0)
                i += 1
            for decl in text[start:i - 1].split(";"):
                if ":" in decl:
                    for n in decl.split(":")[0].split(","):
                        n = n.strip().split()[-1] if n.strip() else ""
                        if re.fullmatch(r"\w+", n):
                            names[n.lower()] = n
        result[m.group(1).lower()] = names
    return result


def fix_vhdl_port_case(dst):
    entities, modules = {}, set()
    for path in dst.rglob("*.vhd"):
        entities.update(vhdl_interface_names(path.read_bytes().decode("latin-1")))
    vfiles = sorted(p for p in dst.rglob("*") if p.suffix in (".v", ".sv") and p.is_file())
    for path in vfiles:
        modules.update(m.lower() for m in re.findall(r"^\s*module\s+(\w+)", path.read_bytes().decode("latin-1"), re.M))
    total = 0
    for path in vfiles:
        text = path.read_bytes().decode("latin-1")
        out, pos, count = [], 0, 0
        for m in re.finditer(r"^[ \t]*(\w+)\s*(#\s*\(|\w+\s*\()", text, re.M):
            ent = m.group(1).lower()
            if ent not in entities or ent in modules or m.start() < pos:
                continue
            i, depth = m.end(), 1
            while i < len(text) and not (depth == 0 and text[i] == ";"):
                depth += {"(": 1, ")": -1}.get(text[i], 0)
                i += 1
            names = entities[ent]

            def fix(c):
                nonlocal count
                right = names.get(c.group(2).lower())
                if right and right != c.group(2):
                    count += 1
                    return c.group(1) + right
                return c.group(0)
            out += [text[pos:m.start()], re.sub(r"(\.\s*)(\w+)(?=\s*\()", fix, text[m.start():i])]
            pos = i
        if count:
            out.append(text[pos:])
            path.write_bytes("".join(out).encode("latin-1"))
            total += count
    return total


# Verilog instances of VHDL entities: Vivado ignores the default value of a VHDL input port
# the instance leaves open and ties the port to 0 (Synth 8-7071), Quartus uses the default.
# SNES: dpram "enable_a : in std_logic := '1'" open in vram1/aram/bsram -> RAMs removed.
# The step reads the input ports with a default of every VHDL entity of the tree and adds
# ".port(default)" to each Verilog instance with named connections that does not connect
# the port (or connects it empty).  Count: connections added; defaults it cannot translate
# are returned as errors (entity.port: default).
VHDL_PORT_DECL = re.compile(r"^\s*([\w\s,]+?)\s*:\s*(?!\s)(?:in\s+)?(?!(?:out|inout|buffer|linkage)\b)([^:]+?)\s*:=\s*(.+?)\s*$",
                            re.I | re.S)


def vhdl_default_literal(value):
    """Verilog literal of a VHDL default value, None if it is not a plain constant."""
    v = value.strip().lower()
    m = re.fullmatch(r"'([01])'", v)
    if m:
        return "1'b" + m.group(1)
    m = re.fullmatch(r"\(\s*others\s*=>\s*'([01])'\s*\)", v)
    if m:
        return "'" + m.group(1)                     # SystemVerilog fill literal, any width
    m = re.fullmatch(r'"([01]+)"', v)
    if m:
        return f"{len(m.group(1))}'b{m.group(1)}"
    m = re.fullmatch(r'x"([0-9a-f]+)"', v)
    if m:
        return f"{4 * len(m.group(1))}'h{m.group(1)}"
    if re.fullmatch(r"\d+", v):
        return v
    return {"false": "1'b0", "true": "1'b1"}.get(v)


def vhdl_port_defaults(text):
    """{entity (lower case): {port (lower case): (declared spelling, default)}} of a VHDL file."""
    text = re.sub(r"--[^\n]*", "", text)
    result = {}
    for m in re.finditer(r"\bentity\s+(\w+)\s+is\b", text, re.I):
        ports, pos = {}, m.end()
        end = re.compile(r"\bend\b", re.I).search(text, pos)
        p = re.compile(r"\bport\s*\(", re.I).search(text, pos, end.start() if end else len(text))
        if p:
            i, depth = p.end(), 1
            while depth and i < len(text):
                depth += {"(": 1, ")": -1}.get(text[i], 0)
                i += 1
            for decl in re.split(r";(?![^(]*\))", text[p.end():i - 1]):
                d = VHDL_PORT_DECL.match(decl)
                if d:
                    for n in d.group(1).split(","):
                        ports[n.strip().lower()] = (n.strip(), d.group(3))
        result[m.group(1).lower()] = ports
    return result


def connect_vhdl_port_defaults(dst, write=True):
    defaults, modules = {}, set()
    for path in dst.rglob("*.vhd"):
        defaults.update(vhdl_port_defaults(path.read_bytes().decode("latin-1")))
    vfiles = sorted(p for p in dst.rglob("*") if p.suffix in (".v", ".sv") and p.is_file())
    for path in vfiles:
        modules.update(m.lower() for m in re.findall(r"^\s*module\s+(\w+)", path.read_bytes().decode("latin-1"), re.M))
    total, errors = 0, []
    for path in vfiles:
        text = path.read_bytes().decode("latin-1")
        out, pos, count = [], 0, 0
        for m in re.finditer(r"^[ \t]*(\w+)\s*(#\s*\(|\w+\s*\()", text, re.M):
            ent = m.group(1).lower()
            if not defaults.get(ent) or ent in modules or m.start() < pos:
                continue
            i, depth = m.end(), 1
            while i < len(text) and not (depth == 0 and text[i] == ";"):
                depth += {"(": 1, ")": -1}.get(text[i], 0)
                i += 1
            inst = text[m.start():i]
            code = re.sub(r"//[^\n]*|/\*.*?\*/", "", inst, flags=re.S)
            if m.group(2).startswith("#"):          # connections follow the parameter list
                k, depth = code.index("(") + 1, 1
                while depth:
                    depth += {"(": 1, ")": -1}.get(code[k], 0)
                    k += 1
                code = code[k:]
            if not re.search(r"\.\s*\w+\s*\(", code):
                continue                            # positional connections: left alone
            given = {c.group(1).lower(): c.group(2).strip()
                     for c in re.finditer(r"\.\s*(\w+)\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)", code)}
            add, n = [], 0
            for port, (spelling, value) in defaults[ent].items():
                if given.get(port, "") != "":
                    continue
                lit = vhdl_default_literal(value)
                if lit is None:
                    errors.append(f"{path.relative_to(dst)}: {ent}.{spelling} := {value.strip()}")
                    continue
                n += 1
                if port in given:                   # ".port()" becomes ".port(default)"
                    inst = re.sub(r"(\.\s*" + spelling + r"\s*\()\s*\)", r"\g<1>" + lit + ")", inst, flags=re.I)
                else:
                    add.append(f".{spelling}({lit})")
            if add:
                close = inst.rstrip().rindex(")")
                body = inst[:close].rstrip()
                sep = "," if not body.endswith("(") else ""
                inst = (body + sep + "\n\t// VHDL port defaults (Vivado ties open inputs to 0)\n\t"
                        + ",\n\t".join(add) + "\n" + inst[close:])
            if n:
                count += n
                out += [text[pos:m.start()], inst]
                pos = i
        if count:
            out.append(text[pos:])
            if write:                               # write=False: count only (core_survey.py lint)
                path.write_bytes("".join(out).encode("latin-1"))
            total += count
    return total, errors


# Quartus memory initialization files (.mif) as Vivado-readable .mem files: one line per
# word, WIDTH binary digits, DEPTH lines, words without a value 0 (the altsyncram
# replacement reads them with std.textio).  The HDL names the .mif relative to the Quartus
# project; Vivado opens files relative to its run directory, so the string literals become
# the absolute path of the .mem in the build tree.  Count: .mif files converted, literals.
MIF_RADIX = {"HEX": 16, "DEC": 10, "UNS": 10, "BIN": 2, "OCT": 8}


def mif_words(text):
    """(width, depth, {address: value}) of a .mif file."""
    text = re.sub(r"--[^\n]*|%[^%]*%", "", text)
    head = {k.upper(): v.strip().upper() for k, v in re.findall(r"(\w+)\s*=\s*([^;]+);", text.split("BEGIN")[0])}
    width, depth = int(head["WIDTH"]), int(head["DEPTH"])
    arad, drad = MIF_RADIX[head.get("ADDRESS_RADIX", "HEX")], MIF_RADIX[head.get("DATA_RADIX", "HEX")]
    body = re.split(r"\bBEGIN\b", text, maxsplit=1, flags=re.I)[1]
    body = re.split(r"\bEND\s*;", body, maxsplit=1, flags=re.I)[0]
    words = {}
    for entry in body.split(";"):
        if ":" not in entry:
            continue
        where, values = entry.split(":", 1)
        values = [int(v, drad) for v in values.split()]
        r = re.match(r"\s*\[\s*(\w+)\s*\.\.\s*(\w+)\s*\]\s*$", where)
        if r:                                       # [a..b] : v  (one value for the range)
            for a in range(int(r.group(1), arad), int(r.group(2), arad) + 1):
                words[a] = values[0]
        else:                                       # a : v0 v1 ...  (consecutive words)
            for k, v in enumerate(values):
                words[int(where, arad) + k] = v
    return width, depth, words


def convert_mif_files(dst):
    mems = {}
    for path in sorted(dst.rglob("*.mif")):
        width, depth, words = mif_words(path.read_bytes().decode("latin-1"))
        mem = path.with_name(path.name + ".mem")
        mem.write_text("".join(format(words.get(a, 0) & ((1 << width) - 1), f"0{width}b") + "\n"
                               for a in range(depth)))
        mems[path.relative_to(dst).as_posix()] = mem.resolve()
    literals = 0
    for path in sorted(p for p in dst.rglob("*") if p.suffix in (".vhd", ".v", ".sv") and p.is_file()):
        text = path.read_bytes().decode("latin-1")

        def fix(m):
            nonlocal literals
            mem = mems.get(m.group(1).lstrip("./"))
            if mem is None:
                return m.group(0)
            literals += 1
            return '"' + str(mem) + '"'
        new = re.sub(r'"([^"\n]*\.mif)"', fix, text)
        if new != text:
            path.write_bytes(new.encode("latin-1"))
    return len(mems), literals


# VHDL: Intel libraries.  "library altera_mf; use altera_mf.altera_mf_components.all;" (and
# lpm, altera, altera_lnsim) name libraries Vivado does not have: the clauses become
# comments, and instances of megafunctions without a local component declaration
# ("label : altsyncram" followed by its generic map) become entity instances of the
# replacements in work (hdl/intel/).  Count: clauses and instances changed.
INTEL_LIBS = r"(?:altera_mf|lpm|altera|altera_lnsim)"
INTEL_LIB_CLAUSE = re.compile(r"^(\s*)((?:library\s+" + INTEL_LIBS + r"|use\s+" + INTEL_LIBS + r"\.[\w.]+)\s*;)",
                              re.I | re.M)


def rule_vhdl_intel_libraries(text):
    if not INTEL_LIB_CLAUSE.search(text):
        return text, 0
    text, count = INTEL_LIB_CLAUSE.subn(r"\1-- \2  -- Intel library (Vivado: replacement in work)", text)
    local = {c.lower() for c in re.findall(r"^\s*component\s+(\w+)", text, re.I | re.M)}

    def inst(m):
        nonlocal count
        if m.group(2).lower() in local:
            return m.group(0)
        count += 1
        return m.group(1) + "entity work." + m.group(2)
    text = re.sub(r"^(\s*\w+\s*:\s*)(" + "|".join(INTEL_MEGAFUNCTIONS) + r")\b(?=\s*(?:--[^\n]*)?\s*(?:generic|port)\s+map)",
                  inst, text, flags=re.I | re.M)
    return text, count


# megafunctions with a replacement in hdl/intel/ (entity instances, rule above)
INTEL_MEGAFUNCTIONS = ["altsyncram", "altdpram", "altddio_out", "lpm_mult"]


# VHDL: order of the entities in one file.  Quartus analyses a file as a whole, Vivado unit
# by unit: "entity work.b" in the architecture of a fails when b comes later in the same
# file ("no such design unit", SNES rtl/bram.vhd dpram -> dpram_dif).  A unit is an entity
# (or package) with the comments, blank lines and library/use clauses right before it (a
# file header goes with the first unit), up to the next unit;
# its architectures follow it.  Units move behind the units of the same file they use,
# otherwise the order stays.  Count: units at another position (-1: circular use).
VHDL_UNIT_START = re.compile(r"^\s*(?:entity|package)\s+(\w+)\s+is\b", re.I)
VHDL_UNIT_PREFIX = re.compile(r"^\s*(?:$|--|library\s|use\s)", re.I)


def rule_vhdl_unit_order(text):
    lines = text.split("\n")
    tail = []
    if lines[-1] == "":                         # the final newline stays at the end of the file
        lines, tail = lines[:-1], [""]
    starts = []
    for i, line in enumerate(lines):
        m = VHDL_UNIT_START.match(line)
        if m and not re.match(r"\s*package\s+body\b", line, re.I):
            k = i
            while k > 0 and VHDL_UNIT_PREFIX.match(lines[k - 1]) and (not starts or k - 1 > starts[-1][1]):
                k -= 1
            starts.append((m.group(1).lower(), i, k))
    if len(starts) < 2:
        return text, 0
    head = lines[:starts[0][2]]
    units = []
    for n, (name, _, k) in enumerate(starts):
        end = starts[n + 1][2] if n + 1 < len(starts) else len(lines)
        units.append((name, lines[k:end]))
    names = {name for name, _ in units}
    uses = {}
    for name, body in units:
        code = re.sub(r"--[^\n]*", "", "\n".join(body)).lower()
        refs = set(re.findall(r"\bentity\s+work\.(\w+)", code)) | set(re.findall(r"\buse\s+work\.(\w+)", code))
        uses[name] = (refs & names) - {name}
    order, placed = [], set()
    pending = [name for name, _ in units]
    while pending:
        ready = [name for name in pending if uses[name] <= placed]
        if not ready:
            return text, -1
        order.append(ready[0])
        placed.add(ready[0])
        pending.remove(ready[0])
    original = [name for name, _ in units]
    if order == original:
        return text, 0
    moved = sum(1 for a, b in zip(order, original) if a != b)
    body = dict(units)
    out = head + [line for name in order for line in body[name]] + tail
    return "\n".join(out), moved


# generic rules, applied to every source tree (count reported, not checked) unless the core
# profile lists a rule of the same name, with its own pattern and expected count
GENERIC_RULES = [
    ("vhdl-direct-instantiation", "**/*.vhd", rule_vhdl_direct_instantiation, None),
    ("vhdl-intel-libraries", "**/*.vhd", rule_vhdl_intel_libraries, None),
    ("vhdl-unit-order", "**/*.vhd", rule_vhdl_unit_order, None),
]

# names a core profile's rules.py can use: (name, file glob, function, expected count or None)
RULE_API = {
    "literal": literal,                                     # literal(old, new)
    "regex": regex,                                         # regex(pattern, repl, flags=0)
    "hoist": hoist,                                         # hoist(declarations, anchor line)
    "falling_edge_to": falling_edge_to,                     # falling_edge_to(clock, mid clock)
    "add_port": add_port,                                   # add_port(module, declaration)
    "connect_port": connect_port,                           # connect_port(module, port, net)
    "vhdl_direct_instantiation": rule_vhdl_direct_instantiation,
    "vhdl_null_waveform": rule_vhdl_null_waveform,
    "declarations_first": rule_declarations_first,         # whole modules, give the file and count
    "re": re,
}


def load_rules(path):
    """RULES of a core profile's rules.py (list of (name, glob, function, expected))."""
    ns = dict(RULE_API)
    exec(compile(pathlib.Path(path).read_text(), str(path), "exec"), ns)
    rules = ns.get("RULES")
    if not isinstance(rules, list):
        raise SystemExit(f"ERROR: {path} defines no list RULES")
    return rules


def main(argv):
    if argv[1:] == ["--patch-dirs"]:
        for n, d in patch_dirs().items():
            print(n, d)
        return 0
    if len(argv) not in (4, 5):
        print(__doc__)
        return 2
    name, src, dst = argv[1], pathlib.Path(argv[2]).resolve(), pathlib.Path(argv[3]).resolve()
    rules = load_rules(argv[4]) if len(argv) == 5 else []
    if not src.is_dir():
        print(f"ERROR: {src} is not a directory (run the flow's setup first)")
        return 1
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns(".git"))

    ok = True
    names = [r[0] for r in rules]
    rules = rules + [r for r in GENERIC_RULES if r[0] not in names]
    if (dst / "sys").is_dir():
        rules = rules + SYS_RULES
    for rule, pattern, func, expected in rules:
        total = 0
        for path in sorted(dst.glob(pattern)):
            # sources of the cores are ASCII with Japanese comments in Shift-JIS: keep the bytes
            text = path.read_bytes().decode("latin-1")
            new, n = func(text)
            if n:
                path.write_bytes(new.encode("latin-1"))
                total += n
        status = ""
        if expected is not None and total != expected:
            status = f"  ERROR: expected {expected}"
            ok = False
        print(f"{name}: rule {rule}: {total} changes{status}")

    # connection names of Verilog instances of VHDL entities (Vivado: exact spelling)
    print(f"{name}: VHDL port names in Verilog instances: {fix_vhdl_port_case(dst)} changes")
    n, errors = connect_vhdl_port_defaults(dst)
    for e in errors:
        print(f"{name}: VHDL port default not translated: {e}  ERROR")
    ok = ok and not errors
    print(f"{name}: VHDL port defaults connected in Verilog instances: {n}")
    # memory initialization files for Vivado
    n, lit = convert_mif_files(dst)
    print(f"{name}: .mif files converted to .mem: {n}, file names in the HDL: {lit}")

    if (dst / "sys" / "sys_top.v").exists():
        n = extract_sys_top_helpers(dst / "sys")
        status = "" if n == len(SYS_TOP_HELPERS) else f"  ERROR: expected {len(SYS_TOP_HELPERS)}"
        ok = ok and not status
        print(f"{name}: sys_top.v helper modules extracted: {n}{status}")
        n, errors = make_sys_top_zynq(dst / "sys")
        for e in errors:
            print(f"{name}: sys_top_zynq.sv: ERROR: {e}")
        ok = ok and not errors
        print(f"{name}: sys_top_zynq.sv: {n} blocks replaced by ports{'  ERROR' if errors else ''}")

    # build_id.v: the cores include it for the version string of the OSD menu
    if (dst / "sys" / "build_id.tcl").exists() and not (dst / "build_id.v").exists():
        (dst / "build_id.v").write_text('`define BUILD_DATE "%s"' % time.strftime("%y%m%d"))
        print(f"{name}: build_id.v written")

    # dst lies inside this repository: git apply would take the patch paths relative to the
    # repository root, skip every file ("Skipped patch") and still return 0. The ceiling
    # directory keeps git from finding the repository, so it patches dst as a plain tree.
    env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(dst.parent))
    pdir = patch_dirs().get(name)
    for patch in sorted(pdir.glob("*.patch")) if pdir else []:
        r = subprocess.run(["git", "apply", "--whitespace=nowarn", str(patch)], cwd=dst, env=env)
        print(f"{name}: patch {patch.name}: {'applied' if r.returncode == 0 else 'FAILED'}")
        ok = ok and r.returncode == 0

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
