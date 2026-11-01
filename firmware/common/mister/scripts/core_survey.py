#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Survey of a MiSTer core before the port (what it needs from Quartus)
#  Project    : fpga-mister
#  File       : core_survey.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-29
# ----------------------------------------------------------------------------------
#  Description: First step of a core port (doc/PORTING.md §2). Reads a MiSTer core tree
#               (a checkout; nothing is executed or changed) and prints a Markdown report:
#                 1. source files of files.qip / sys.qip by type
#                 2. Intel megafunctions and primitives instantiated outside sys/, and
#                    which of them the port already replaces (hdl/intel/*.vhd) or replaces
#                    by profile (PLL: cores/<core>/pll.vhd)
#                 3. altera_pll / altpll output clocks (the clocks of the core profile)
#                 4. emu ports the core uses (SDRAM, second SDRAM, DDRAM, UART, USER, ...)
#                    and the VERILOG_MACRO lines of its .qsf (core_defines)
#                 5. constructs Vivado rejects or reads differently, with
#                    file:line, as candidates for rules.py, patches or replacement files
#                 6. sys/ against the pinned Template_MiSTer (sys_top.v rewrite by text)
#                 7. lint: what costs a build or a hardware run when it is found late
#                    : falling clock edges traced to the PLL output they
#                    run on (derived clock: half period = master high time), timing
#                    exceptions of the core's .sdc against the profile's core.xdc,
#                    number of core clocks (BUFGCE cascade; free-running MMCM clocks with
#                    G_FREE_CLK 1), Intel primitives without a replacement, open VHDL
#                    inputs with defaults in Verilog instances, VHDL libraries other than
#                    work without a rule, VHDL 2008 by the .qsf without core_vhdl_std 2008
#               Usage:
#                 core_survey.py [--strict] [--profile <cores/<core>>] <core tree> [<Template_MiSTer tree>]
#               The profile is found by core_name (cores/*/core.tcl) unless given.
#               --strict: exit code 1 when the lint has errors (a primitive without a
#               replacement, a falling edge on a derived clock the profile does not
#               handle by a rule or patch, a VHDL library or VHDL 2008 the profile does
#               not handle); without it the exit code is 0.
#               The report is a checklist, not a verdict: every hit is read in context.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
"""core_survey.py [--strict] [--profile <profile dir>] <core tree> [<Template_MiSTer tree>]

Markdown report of what a MiSTer core needs from Quartus (see the file header)."""

import collections
import filecmp
import fnmatch
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
MISTER = HERE.parent

HDL_EXT = {".v": "Verilog", ".sv": "SystemVerilog", ".vhd": "VHDL", ".vhdl": "VHDL"}

# Intel megafunctions / primitives (instantiation names) and how the port handles them
MEGAFUNCTIONS = {
    "altsyncram": "hdl/intel/altsyncram.vhd (subset, asserts on the rest)",
    "altddio_out": "hdl/intel/altddio_out.vhd",
    "altera_pll": "profile: cores/<core>/pll.vhd (gated master clock, §3.7)",
    "altpll": "profile: cores/<core>/pll.vhd (gated master clock, §3.7)",
    "altera_pll_reconfig_top": "missing (PLL reconfiguration; mister_zynq acknowledges only)",
    "pll_cfg": "missing (core PLL reconfiguration with Altera register values: MMCM DRP replacement)",
    "altdpram": "hdl/intel/altdpram.vhd",
    "altsyncram_component": None,      # instance label of altsyncram, not a type
    "scfifo": "missing",
    "dcfifo": "missing",
    "dcfifo_mixed_widths": "missing",
    "altddio_in": "missing",
    "altddio_bidir": "missing",
    "altiobuf_in": "missing", "altiobuf_out": "missing", "altiobuf_bidir": "missing",
    "altshift_taps": "missing",
    "altmult_add": "missing", "altmult_accum": "missing",
    "altsqrt": "missing",
    "lpm_mult": "hdl/intel/lpm_mult.vhd", "lpm_divide": "missing", "lpm_add_sub": "missing",
    "lpm_shiftreg": "missing", "lpm_counter": "missing", "lpm_compare": "missing",
    "lpm_ram_dp": "missing", "lpm_rom": "missing",
    "altera_syncram": "missing",
    "altera_std_synchronizer": "missing",
    "altera_mult_add": "missing",
    "cyclonev_mac": "missing (DSP block)",
    "cyclonev_ram_block": "missing",
    "cyclonev_clkena": "missing (BUFGCE)",
    "cyclonev_clkselect": "missing outside sys/ (BUFGMUX)",
    "lcell": "missing (combinational loop / keep cell: replace the module)",
}
INST = re.compile(r"^\s*(?:(\w+)\s*:\s*(?:entity\s+\w+\.)?|)(?P<type>%s)\b(?:\s*#|\s+\w+\s*(?:\(|$)|\s*$|\s+(?:generic|port)\s+map)"
                  % "|".join(sorted((k for k, v in MEGAFUNCTIONS.items() if v), key=len, reverse=True)),
                  re.IGNORECASE)

# emu ports of the MiSTer framework (sys/emu ports, Template_MiSTer) and what the port offers
EMU_PORTS = [
    ("SDRAM_", "stage C SDRAM emulator (sdram_emu ... HP0)"),
    ("SDRAM2_", "missing: second SDRAM (MISTER_DUAL_SDRAM)"),
    ("DDRAM_", "missing in mister_zynq: avl_axi_bridge exists, ram1 not connected (HP2 planned)"),
    ("UART_", "not connected"),
    ("USER_", "not connected (USER port / SNAC)"),
    ("ADC_", "not connected"),
    ("AUDIO_", "audio_out -> I2S (codec, hdmi_out)"),
    ("VGA_", "ascal -> HDMI"),
    ("HDMI_", "framework side, fixed 720p60"),
    ("LED_", "board LEDs"),
    ("BUTTONS", "board buttons"),
    ("SD_", "not connected (SD card SPI of the IO board)"),
    ("FB_", "framebuffer mode (MISTER_FB): not tested"),
]

# emu outputs tied to a constant: assign X = 0; / assign {A, B} = '0;
TIE_OFF = re.compile(r"^\s*assign\s+(\{[\w\s,]+\}|\w+)\s*=\s*(?:'[01zZ]|\d+'[bdh][0-9a-fA-FxzXZ_]+|\d+|\{[^}]*\})\s*;", re.M)

# constructs Quartus accepts and Vivado rejects or reads differently
RISKY = [
    ("vhdl", r"^\s*\w+\s*:\s*work\.\w+", "VHDL instance 'label : work.ent' without 'entity' (generic rule)"),
    ("vlog", r"\binout\s+reg\b", "'inout reg' port (rule/patch)"),
    ("all", r"\blcell\b", "lcell (combinational loop or keep cell)"),
    ("all", r"altera_attribute|\bsynthesis\s+(?:keep|preserve|ramstyle|romstyle|ram_init_file)", "Quartus attribute"),
    ("vlog", r"\(\*\s*(?:ramstyle|romstyle|ram_init_file|altera_attribute|chip_pin|useioff)", "Quartus synthesis attribute"),
    ("all", r"\$readmem[hb]\s*\(", "$readmemh/b: path relative to the Quartus project"),
    ("all", r"init_file\s*[=(:]", "memory init file (.mif/.hex: Vivado needs .mem or inference)"),
    ("vlog", r"defparam\b", "defparam (Vivado: supported, check the target)"),
    ("vlog", r"\bassign\s+\w+\s*=\s*\w+\s*\?\s*\w+\s*:\s*\w+\s*;\s*//.*clk|\bclk\w*\s*=\s*.*&", "gated or muxed clock (check)"),
    ("vhdl", r"\bshared\s+variable\b", "shared variable (dual-port RAM style: check inference)"),
    ("vhdl", r"\battribute\s+(?:ramstyle|romstyle|ram_init_file|altera_attribute|preserve)\s+of\b",
     "Quartus attribute (VHDL): ram_style/rom_style/keep for Vivado"),
    ("vhdl", r"^\s*library\s+(?!(?:ieee|std|work|altera_mf|altera|lpm|altera_lnsim)\s*;)\w+\s*;",
     "VHDL library other than work (Quartus resolves it loosely: rule to work. or compile into it)"),
    ("vhdl", r"=>\s*not\s*\(?\s*\w*(?:clk|clock)\w*\s*\)?\s*[,)]",
     "inverted clock in a port map (negative edge: BRAM clock inversion, XDC clock)"),
    ("vhdl", r"=>\s*(?:not\b|\(?\s*\w+\s+(?:and|or|xor|nand|nor)\b)",
     "expression in a port map (VHDL-2008 syntax; Vivado took it as VHDL in the MSX build)"),
]


# literal burst counts (DDRAM/Avalon): AXI3 allows at most 16 beats per burst
BURST = re.compile(r"BURSTCNT\w*\s*(?:<=|=>|=)\s*(?:x\"([0-9a-fA-F]+)\"|\d*'h([0-9a-fA-F]+)|\d*'d(\d+)|(\d+)\b)",
                   re.IGNORECASE)


def files_of_qip(qip, base=None):
    """HDL files of a .qip (recursive), as qip.tcl reads them: [file join $::quartus(qip_path) x]
    relative to the .qip, plain paths relative to the project (base, default: the first .qip's
    directory); computed paths ([join ...], sys.qip's PLL by Quartus version) are left out."""
    out = []
    if not qip.exists():
        return out
    base = base or qip.parent
    for line in qip.read_text(errors="replace").splitlines():
        m = re.search(r"-name\s+(\w+)_FILE\s+(?:\[file join \$::quartus\(qip_path\)\s+(\S+)\s*\]|(\S+))", line)
        if not m:
            continue
        kind = m.group(1)
        if m.group(2):
            path = (qip.parent / m.group(2).strip('"')).resolve()
        elif m.group(3).startswith("["):
            continue
        else:
            path = (base / m.group(3).strip('"')).resolve()
        if kind == "QIP":
            out += files_of_qip(path, base)
        else:
            out.append(path)
    return out


# ---------------------------------------------------------------------------- lint (section 7)

def read_profile(prof_dir):
    """Fields of cores/<core>/core.tcl (single-line set commands) plus dir, rules text and the
    files the profile's patches touch."""
    prof = {"dir": prof_dir}
    tcl = (prof_dir / "core.tcl").read_text(errors="replace")
    for m in re.finditer(r"^set\s+(core_\w+)\s+(?:\{([^}\n]*)\}|(\S+))\s*$", tcl, re.M):
        prof[m.group(1)] = m.group(2).split() if m.group(2) is not None else m.group(3)
    # core_generics {<name> <value> ...} over several lines
    m = re.search(r"^set\s+core_generics\s+\{([^}]*)\}", tcl, re.M)
    words = m.group(1).split() if m else []
    prof["generics"] = dict(zip(words[0::2], words[1::2]))
    rules = prof_dir / "rules.py"
    prof["rules_text"] = rules.read_text(errors="replace") if rules.exists() else ""
    patched = set()
    name = prof.get("core_name", "")
    for d in (MISTER / "patches" / str(name), prof_dir / "patches"):
        for patch in sorted(d.glob("*.patch")) if d.is_dir() else []:
            patched.update(re.findall(r"^\+\+\+ b/(\S+)", patch.read_text(errors="replace"), re.M))
    prof["patched"] = patched
    return prof


def find_profile(tree):
    """Profile directory whose core_name is the name of the core tree, or None."""
    for tcl in sorted((MISTER / "cores").glob("*/core.tcl")):
        if re.search(r"^set\s+core_name\s+%s\s*$" % re.escape(tree.name), tcl.read_text(errors="replace"), re.M):
            return tcl.parent
    return None


def strip_comments(text, lang):
    """Comments blanked (line numbers kept)."""
    if lang == "vhdl":
        return re.sub(r"--[^\n]*", "", text)
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def lang_of(path):
    return "vhdl" if path.suffix.lower() in (".vhd", ".vhdl") else "vlog"


def balanced(text, i):
    """Index after the parenthesis that closes the one opened just before i."""
    depth = 1
    while depth and i < len(text):
        depth += {"(": 1, ")": -1}.get(text[i], 0)
        i += 1
    return i


UNIT = re.compile(r"^\s*(?:module\s+(\w+)|architecture\s+\w+\s+of\s+(\w+)\s+is)", re.I | re.M)


def units_at(code):
    """[(start, unit name lower)] of the modules / architectures of a file."""
    return [(m.start(), (m.group(1) or m.group(2)).lower()) for m in UNIT.finditer(code)]


def unit_of(units, pos):
    name = None
    for start, u in units:
        if start <= pos:
            name = u
    return name


def instances(texts):
    """{child unit (lower): [(parent unit, {port lower: expression})]} of named connections in
    Verilog instances and VHDL port maps between units defined in the files."""
    codes = {p: strip_comments(t, lang_of(p)) for p, t in texts.items()}
    defined = set()
    for c in codes.values():
        defined.update(re.findall(r"^\s*module\s+(\w+)", c, re.M))
        defined.update(re.findall(r"^\s*entity\s+(\w+)\s+is", c, re.M | re.I))
    defined = {d.lower() for d in defined}
    inst = collections.defaultdict(list)
    for p, c in codes.items():
        units = units_at(c)
        if lang_of(p) == "vhdl":
            for m in re.finditer(r"\b\w+\s*:\s*(?:entity\s+\w+\.)?(\w+)\s*(?:generic\s+map\s*\(|port\s+map\s*\()", c, re.I):
                child = m.group(1).lower()
                if child not in defined:
                    continue
                i = m.end()
                if m.group(0).lower().rstrip("( \t\n").endswith("generic map"):
                    i = balanced(c, i)
                    pm = re.compile(r"\s*port\s+map\s*\(", re.I).match(c, i)
                    if not pm:
                        continue
                    i = pm.end()
                body = c[i:balanced(c, i) - 1]
                conns = {a.lower(): b.strip() for a, b in re.findall(r"(\w+)\s*=>\s*([^,]+)", body)}
                inst[child].append((unit_of(units, m.start()), conns))
        else:
            for m in re.finditer(r"^[ \t]*(\w+)\s*(#\s*\(|\w+\s*\()", c, re.M):
                child = m.group(1).lower()
                if child not in defined:
                    continue
                i = m.end()
                if m.group(2).startswith("#"):
                    i = balanced(c, i)
                    pm = re.compile(r"\s*\w+\s*\(").match(c, i)
                    if not pm:
                        continue
                    i = pm.end()
                body = c[i:balanced(c, i) - 1]
                conns = {a.lower(): b.strip() for a, b in re.findall(r"\.\s*(\w+)\s*\(\s*([^()]*?)\s*\)", body)}
                inst[child].append((unit_of(units, m.start()), conns))
    return inst


def net_name(expr):
    """Signal name of a connection expression: 'not CLK', '~clk', 'clk_sys', 'x(0)' -> name."""
    m = re.match(r"^\s*(?:not\b|[~!])?\s*\(?\s*(\w+)", expr, re.I)
    return m.group(1) if m else None


def trace_clock(unit, net, inst, pll_nets, depth=0):
    """PLL output nets (lower) a clock port of a unit is driven from, through the instances;
    '?<net>' when the trace ends elsewhere (board clock, logic, unknown)."""
    n = net.lower()
    if n in pll_nets:
        return {n}
    parents = inst.get(unit or "", [])
    if depth > 10 or not parents:
        return {"?" + net}
    found = set()
    for parent, conns in parents:
        expr = conns.get(n)
        src = net_name(expr) if expr else None
        found |= trace_clock(parent, src, inst, pll_nets, depth + 1) if src else {"?" + net}
    return found


FALL_VHDL = re.compile(r"\bfalling_edge\s*\(\s*(\w+)\s*\)|\b(\w+)'event\s+and\s+(\w+)\s*=\s*'0'", re.I)
NEGEDGE = re.compile(r"@\s*\(([^)]*)\)")
PORT_INV_VHDL = re.compile(r"\b(\w*(?:clk|clock)\w*)\s*=>\s*not\s*\(?\s*(\w+)", re.I)
PORT_INV_VLOG = re.compile(r"\.\s*(\w*(?:clk|clock)\w*)\s*\(\s*[~!]\s*(\w+)\s*\)", re.I)
RESET_NAME = re.compile(r"rst|reset|res_n|clr|nres", re.I)


def falling_edges(texts, tree):
    """[(file rel, line, unit, clock net, what)] of logic on the falling edge of a clock:
    VHDL falling_edge / 'event and = '0', Verilog negedge of a clock (not of an asynchronous
    reset next to a posedge), and inverted clocks connected to clock ports."""
    out = []
    for p, t in texts.items():
        lang = lang_of(p)
        code = strip_comments(t, lang)
        units = units_at(code)
        rel = str(p.relative_to(tree))
        line_of = lambda pos: code.count("\n", 0, pos) + 1
        if lang == "vhdl":
            for m in FALL_VHDL.finditer(code):
                clk = m.group(1) or m.group(3)
                if m.group(2) and m.group(2).lower() != m.group(3).lower():
                    continue
                out.append((rel, line_of(m.start()), unit_of(units, m.start()), clk, "falling_edge"))
            for m in PORT_INV_VHDL.finditer(code):
                out.append((rel, line_of(m.start()), unit_of(units, m.start()), m.group(2),
                            f"inverted clock to port {m.group(1)}"))
        else:
            for m in NEGEDGE.finditer(code):
                sens = m.group(1)
                negs = re.findall(r"\bnegedge\s+(\w+)", sens)
                has_pos = re.search(r"\bposedge\b", sens)
                for clk in negs:
                    if RESET_NAME.search(clk) and not re.search(r"cl(?:oc)?k", clk, re.I):
                        continue                                # asynchronous reset
                    if has_pos and not re.search(r"cl(?:oc)?k", clk, re.I):
                        continue
                    out.append((rel, line_of(m.start()), unit_of(units, m.start()), clk, "negedge"))
            for m in PORT_INV_VLOG.finditer(code):
                out.append((rel, line_of(m.start()), unit_of(units, m.start()), m.group(2),
                            f"inverted clock to port {m.group(1)}"))
    return out


SDC_CMD = re.compile(r"^[ \t]*(set_max_delay|set_min_delay|set_multicycle_path|set_false_path|create_generated_clock|"
                     r"set_clock_groups)\b", re.M)


def timing_exceptions(text):
    """[(line, command, first line text)] of timing constraints of an .sdc/.xdc text."""
    code = re.sub(r"#[^\n]*", lambda c: " " * len(c.group(0)), text)
    return [(code.count("\n", 0, m.start()) + 1, m.group(1), (code[m.start():] + "\n").split("\n", 1)[0].strip())
            for m in SDC_CMD.finditer(code)]


def pll_clocks(tree, texts):
    """(emu PLL nets {net lower: output index}, {index: MHz}) of the core's altera_pll."""
    nets, freqs = {}, {}
    for p, t in texts.items():
        if re.search(r"^\s*module\s+emu\b", t, re.M):
            code = strip_comments(t, "vlog")
            m = re.search(r"^\s*pll\s+\w+\s*\(", code, re.M)
            if m:
                body = code[m.end():balanced(code, m.end())]
                nets = {n.lower(): int(i) for i, n in re.findall(r"\.outclk_(\d+)\s*\(\s*(\w+)\s*\)", body)}
    for p in sorted(tree.rglob("*.v")) + sorted(tree.rglob("*.vhd")):
        if "sys" in p.relative_to(tree).parts[:1]:
            continue
        t = p.read_bytes().decode("latin-1")
        if "altera_pll" not in t:
            continue
        for i, f in re.findall(r"output_clock_frequency(\d+)\s*[=(:]+\s*\"?([\d.]+)\s*MHz", t):
            freqs.setdefault(int(i), float(f))
        if freqs:
            break
    return nets, freqs


def lint(tree, texts, hits, prof):
    """(errors, warnings, infos): lines of the lint section."""
    errors, warnings, infos = [], [], []
    nets, freqs = pll_clocks(tree, texts)
    used = {n: i for n, i in nets.items()}
    fast = max(used, key=lambda n: freqs.get(used[n], 0)) if used and freqs else None
    derived = {n for n in used if n != fast}

    # free-running core clocks (G_FREE_CLK 1, stage D, N64): the profile's pll.vhd makes them
    # with an MMCM, real clocks with a 50 % duty cycle: no BUFGCE cascade, falling edges as usual
    free = bool(prof) and prof.get("generics", {}).get("G_FREE_CLK") == "1"

    # clocks: one BUFGCE per derived clock in the cascade behind core_buf (PORTING §3.3)
    if used and free:
        desc = ", ".join(f"{n} ({freqs[i]:.3f} MHz)" if i in freqs else n for n, i in sorted(used.items(), key=lambda x: x[1]))
        infos.append(f"core clocks from the PLL: {len(used)}: {desc}; G_FREE_CLK 1: free-running clocks from "
                     f"the MMCM of the profile's pll.vhd, no BUFGCE cascade")
    elif used:
        desc = ", ".join(f"{n} ({freqs[i]:.3f} MHz)" if i in freqs else n for n, i in sorted(used.items(), key=lambda x: x[1]))
        line = f"core clocks from the PLL: {len(used)}: {desc}; fastest {fast or '?'}"
        (warnings if len(used) > 3 else infos).append(
            line + (": more than 3 clocks, the BUFGCE cascade needs adjacent BUFGCTRL sites" if len(used) > 3 else ""))
    else:
        infos.append("no PLL instance 'pll' with outclk_<n> in emu found (clock trace not possible)")

    # does the profile touch a file: a patch changes it, or rules.py names its stem or one of its
    # directories (SNES: "SPC7110" in the rule that switches the chip off).  A heuristic: the
    # line is reported anyway, only not as an error
    rule_words = set(re.findall(r"\w+", prof["rules_text"])) if prof else set()

    def touched(rel):
        if prof is None:
            return False
        pp = pathlib.PurePosixPath(rel)
        return rel in prof["patched"] or pp.stem in rule_words or bool((set(pp.parts[:-1]) - {"rtl", "chip", "src"}) & rule_words)

    inst = instances(texts)
    for rel, n, unit, clk, what in falling_edges(texts, tree):
        src = trace_clock(unit, clk, inst, used)
        kind = ("derived clock " + "/".join(sorted(s for s in src if s in derived)) if src & derived else
                "fastest clock (half period kept)" if src == {fast} else
                "clock not traced to the PLL (" + ", ".join(sorted(s.lstrip("?") for s in src)) + ")")
        handled = touched(rel)
        msg = f"{rel}:{n}: {what} on {clk}: {kind}" + (" (the profile's rules/patches touch the file: check)" if handled else "")
        if free:
            infos.append(msg + " (G_FREE_CLK: an MMCM clock, the falling edge keeps its half period)")
        elif src & derived and not handled:
            errors.append(msg + ": runs on the master high time (5.6 ns at 90 MHz): mid clock of hdl/clk_pulse_div.vhd + rule falling_edge_to (PORTING §3.3)")
        elif src & derived or not src <= {fast}:
            warnings.append(msg)
        else:
            infos.append(msg)

    # .sdc of the core against core.xdc of the profile
    sdcs = [p for p in sorted(tree.rglob("*.sdc")) if "sys" not in p.relative_to(tree).parts[:1]]
    xdc_n = 0
    for x in (prof or {}).get("core_xdc", []) if prof else []:
        if (MISTER / x).exists():
            xdc_n += len([e for e in timing_exceptions((MISTER / x).read_text(errors="replace"))
                          if e[1] in ("set_max_delay", "set_multicycle_path", "set_false_path")])
    for sdc in sdcs:
        ex = timing_exceptions(sdc.read_text(errors="replace"))
        paths = [e for e in ex if e[1] in ("set_max_delay", "set_multicycle_path", "set_false_path")]
        lst = "; ".join(f"{n}: {txt[:70]}" for n, cmd, txt in ex)
        line = (f"{sdc.relative_to(tree)}: {len(paths)} path exceptions, {len(ex) - len(paths)} other "
                f"({lst}); core.xdc of the profile: {xdc_n} path exceptions")
        (warnings if len(paths) > xdc_n else infos).append(
            line + (": translate them into core.xdc (scaled to the master period)" if len(paths) > xdc_n else ""))
        for n, cmd, txt in ex:
            if cmd == "create_generated_clock" and "-invert" in sdc.read_text(errors="replace"):
                warnings.append(f"{sdc.relative_to(tree)}:{n}: inverted generated clock (RAM on the falling edge)")
                break

    # Intel primitives: replacement in hdl/intel, by the profile (core_add / excluded file) or missing
    adds = (prof or {}).get("core_add", []) if prof else []
    add_units = set()
    for a in adds:
        f = MISTER / a
        if f.exists():
            add_units.update(u.lower() for u in re.findall(r"^\s*(?:entity|module)\s+(\w+)", f.read_text(errors="replace"), re.M | re.I))
    excl = (prof or {}).get("core_exclude", []) if prof else []
    for k, where in sorted(hits.items()):
        files = {w.rsplit(":", 1)[0] for w in where}
        if (MISTER / "hdl" / "intel" / f"{k}.vhd").exists():
            infos.append(f"{k}: {len(where)} instance(s), replaced by hdl/intel/{k}.vhd")
        elif k in add_units:
            infos.append(f"{k}: {len(where)} instance(s), replaced by the profile (core_add)")
        elif all(any(fnmatch.fnmatch("/" + f, pat) or fnmatch.fnmatch(f, pat.lstrip("*/")) for pat in excl) for f in files):
            infos.append(f"{k}: {len(where)} instance(s), only in files the profile excludes")
        elif all(touched(f) for f in files):
            warnings.append(f"{k}: {len(where)} instance(s) without a replacement, in files the profile's rules/patches "
                            f"touch (switched off?): {', '.join(where[:4])}")
        else:
            errors.append(f"{k}: {len(where)} instance(s) without a replacement ({', '.join(where[:4])})")

    # VHDL libraries other than work (N64: mem): Quartus resolves lib.x like work.x, Vivado stops
    # at "library mem;" unless rules.py renames it (or the files are compiled into it)
    libs = collections.defaultdict(list)
    for p, text in texts.items():
        if lang_of(p) != "vhdl":
            continue
        for n, line in enumerate(strip_comments(text, "vhdl").splitlines(), 1):
            for lib in re.findall(r"^\s*library\s+(\w+)\s*;", line, re.I):
                if lib.lower() not in ("ieee", "std", "work", "altera_mf", "altera", "lpm", "altera_lnsim", "unisim"):
                    libs[lib.lower()].append(f"{p.relative_to(tree)}:{n}")
    rules_low = prof["rules_text"].lower() if prof else ""
    for lib, where in sorted(libs.items()):
        line = f"VHDL library {lib}: {len(where)} file(s) ({', '.join(where[:3])})"
        # a rule that names the library next to the word library (a heuristic, as touched())
        if "library" in rules_low and lib in re.findall(r"\w+", rules_low):
            infos.append(line + ": rules.py renames it")
        else:
            errors.append(line + ": Vivado compiles everything into work and stops at 'library " + lib +
                          ";': rule to work. in rules.py (N64: mem-library-clause/-names)")

    # VHDL 2008 by the .qsf (Quartus VHDL_INPUT_VERSION, N64): the profile must read the core so
    # (core_vhdl_std 2008), Vivado reads VHDL-93 otherwise and stops on 2008 syntax
    for qsf in sorted(tree.glob("*.qsf")):
        m = re.search(r"^\s*set_global_assignment\s+-name\s+VHDL_INPUT_VERSION\s+VHDL_(\d+)",
                      qsf.read_text(errors="replace"), re.M)
        if m and m.group(1) == "2008":
            line = f"{qsf.name}: VHDL_INPUT_VERSION VHDL_2008"
            if prof and prof.get("core_vhdl_std") == "2008":
                infos.append(line + ": the profile reads the core as VHDL 2008 (core_vhdl_std)")
            else:
                errors.append(line + ": set core_vhdl_std 2008 in core.tcl, Vivado reads VHDL-93 otherwise")

    # open VHDL inputs with a default in Verilog instances (prepare_sources.py connects them)
    try:
        sys.path.insert(0, str(HERE))
        import prepare_sources
        count, errs = prepare_sources.connect_vhdl_port_defaults(tree, write=False)
        infos.append(f"open VHDL inputs with a default in Verilog instances: {count} "
                     f"(prepare_sources.py connects them; Vivado would tie them to 0)")
        for e in errs:
            warnings.append(f"VHDL default prepare_sources.py cannot translate: {e}")
    except Exception as e:                                  # report only
        warnings.append(f"port default check not run: {e}")
    return errors, warnings, infos


def section(title):
    print(f"\n## {title}\n")


def main(argv):
    args, strict, prof_dir = [], False, None
    it = iter(argv[1:])
    for a in it:
        if a == "--strict":
            strict = True
        elif a == "--profile":
            prof_dir = pathlib.Path(next(it, "")).resolve()
        else:
            args.append(a)
    if len(args) not in (1, 2) or not all(pathlib.Path(a).is_dir() for a in args) or \
            prof_dir is not None and not (prof_dir / "core.tcl").exists():
        print(__doc__, file=sys.stderr)
        return 2
    tree = pathlib.Path(args[0]).resolve()
    tmpl = pathlib.Path(args[1]).resolve() if len(args) == 2 else None
    prof_dir = prof_dir or find_profile(tree)
    prof = read_profile(prof_dir) if prof_dir else None
    print(f"# Core survey: {tree.name}")
    qsf = sorted(tree.glob("*.qsf"))
    print(f"\nTree `{tree}`, project files: {', '.join(p.name for p in qsf) or 'none'}")

    # 1. files
    section("1. Source files (files.qip, sys/sys.qip)")
    core_files = files_of_qip(tree / "files.qip")
    sys_files = files_of_qip(tree / "sys" / "sys.qip", tree)
    if not core_files:
        core_files = sorted(p for p in tree.rglob("*") if p.suffix in HDL_EXT and "sys" not in p.relative_to(tree).parts[:1])
        print("files.qip missing or empty: every HDL file outside sys/ is listed instead.\n")
    for name, lst in (("core", core_files), ("sys", sys_files)):
        kinds = collections.Counter(HDL_EXT.get(p.suffix.lower(), p.suffix or "?") for p in lst)
        print(f"- {name}: {len(lst)} files ({', '.join(f'{v} {k}' for k, v in sorted(kinds.items()))})")
    missing = [p for p in core_files + sys_files if not p.exists()]
    if missing:
        print(f"- listed but missing: {', '.join(str(p.relative_to(tree)) for p in missing[:10])}")

    hdl = [p for p in core_files if p.exists() and p.suffix.lower() in HDL_EXT]
    texts = {p: p.read_bytes().decode("latin-1") for p in hdl}

    # 2. megafunctions
    section("2. Intel megafunctions and primitives (outside sys/)")
    hits = collections.defaultdict(list)
    for p, t in texts.items():
        for n, line in enumerate(t.splitlines(), 1):
            m = INST.match(line.split("//")[0].split("--")[0])
            if m:
                hits[m.group("type").lower()].append(f"{p.relative_to(tree)}:{n}")
    if not hits:
        print("none")
    else:
        print("| type | instances | port | where |\n|---|---|---|---|")
        for k in sorted(hits):
            where = ", ".join(hits[k][:4]) + (" …" if len(hits[k]) > 4 else "")
            print(f"| `{k}` | {len(hits[k])} | {MEGAFUNCTIONS[k]} | {where} |")

    # 3. PLL clocks
    section("3. PLL output clocks (core profile: master clock, pll.vhd, core.xdc)")
    found = False
    for p in sorted(tree.rglob("*.v")) + sorted(tree.rglob("*.sv")) + sorted(tree.rglob("*.vhd")):
        if "sys" in p.relative_to(tree).parts[:1]:
            continue
        t = p.read_bytes().decode("latin-1")
        if "altera_pll" not in t and "altpll" not in t:
            continue
        freqs = re.findall(r"output_clock_frequency(\d+)\s*[=(:]+\s*\"?([\d.]+\s*\w*)", t)
        if not freqs:
            continue
        found = True
        refc = re.search(r"reference_clock_frequency\s*[=(:]+\s*\"?([\d.]+\s*\w*)", t)
        phases = dict(re.findall(r"phase_shift(\d+)\s*[=(:]+\s*\"?(-?[\d.]+\s*\w*)", t))
        nclk = re.search(r"number_of_clocks\s*[=(:]+\s*(\d+)", t)
        n = int(nclk.group(1)) if nclk else len(freqs)
        outs = [f"{i}: {f}" + (f" (phase {phases[i]})" if phases.get(i, "0 ps").split()[0] not in ("0", "0.0") else "")
                for i, f in freqs if int(i) < n]
        print(f"- `{p.relative_to(tree)}`: ref {refc.group(1) if refc else '?'}; " + "; ".join(outs))
    if not found:
        print("no altera_pll / altpll parameters found (PLL from a .qsys/.ip file or none)")

    # 4. emu ports and macros
    section("4. emu ports and Quartus macros")
    emu = next((p for p, t in texts.items() if re.search(r"^\s*module\s+emu\b", t, re.M)), None)
    if emu is None:
        print("module emu not found in the core files")
    else:
        t = re.sub(r"//[^\n]*", "", texts[emu])
        body = t[t.find("module emu"):]
        body = body[body.find(");") + 2:]
        tied = set(n for lhs in TIE_OFF.findall(body) for n in re.findall(r"\w+", lhs))
        live = TIE_OFF.sub("", body)
        print(f"emu: `{emu.relative_to(tree)}`\n\n| ports | used in emu | only tied off | port |\n|---|---|---|---|")
        for pre, how in EMU_PORTS:
            rx = r"\b(%s\w*)" % re.escape(pre)
            used = sorted(set(re.findall(rx, live)))
            off = sorted(set(re.findall(rx, body)) & tied - set(used))
            if used or off:
                u = ", ".join(used[:8]) + (" …" if len(used) > 8 else "")
                print(f"| `{pre}*` | {u or '–'} | {', '.join(off[:6]) + (' …' if len(off) > 6 else '') or '–'} | "
                      f"{how if used else 'nothing to do'} |")
        star = re.findall(r"^\s*(\w+)\s+(?:#\s*\(.*?\)\s*)?(\w+)\s*\(\s*\.\*", body, re.M | re.S)
        if star:
            print("\nImplicit port connections (`.*`), emu ports may be used inside: " +
                  ", ".join(f"`{typ} {inst}`" for typ, inst in star) + " (read the module's ports)")
        hps = re.search(r"hps_io\s*#\s*\((.*?)\)\s*hps_io", t, re.S)
        if hps:
            print(f"\nhps_io parameters: `{' '.join(hps.group(1).split())}`")
    for q in qsf:
        # without comment lines (N64.qsf: "# set_global_assignment ... MISTER_DISABLE_YC=1")
        qt = re.sub(r"(?m)^\s*#.*$", "", q.read_text(errors="replace"))
        macros = re.findall(r"VERILOG_MACRO\s+\"?([^\"\s]+)", qt)
        print(f"\n{q.name} VERILOG_MACRO: {', '.join(f'`{m}`' for m in macros) or 'none'}")
        vhdl = re.search(r"VHDL_INPUT_VERSION\s+(\w+)", qt)
        if vhdl:
            print(f"\n{q.name} VHDL_INPUT_VERSION: `{vhdl.group(1)}` (Vivado: file type of the VHDL files)")

    # 5. risky constructs
    section("5. Constructs to check for Vivado (candidates for rules.py / patches)")
    rows = collections.defaultdict(list)
    for p, t in texts.items():
        lang = "vhdl" if p.suffix.lower() in (".vhd", ".vhdl") else "vlog"
        lines = t.splitlines()
        for n, line in enumerate(lines, 1):
            code = line.split("--")[0] if lang == "vhdl" else line.split("//")[0]
            # "when c else null;" (possibly with null on the next line): latch of a conditional assignment
            if lang == "vhdl" and re.search(r"^\s*null\s*;", code) and n > 1 and \
                    re.search(r"\bwhen\b.*\belse\s*$", lines[n - 2].split("--")[0].rstrip(), re.IGNORECASE) or \
                    lang == "vhdl" and re.search(r"\belse\s+null\s*;", code, re.IGNORECASE):
                rows["'when ... else null' latch (rule per use, vhdl_null_waveform)"].append(f"{p.relative_to(tree)}:{n}")
            for b in BURST.finditer(code):
                h1, h2, d1, d2 = b.groups()
                beats = int(h1 or h2, 16) if (h1 or h2) else int(d1 or d2)
                if beats > 16:
                    rows["burst count > 16 beats (AXI3: avl_axi_bridge needs burst splitting)"].append(
                        f"{p.relative_to(tree)}:{n} ({beats})")
            for scope, rx, what in RISKY:
                if scope in ("all", lang) and re.search(rx, code, re.IGNORECASE):
                    rows[what].append(f"{p.relative_to(tree)}:{n}")
    if not rows:
        print("none found")
    for what, where in rows.items():
        print(f"- {what}: {len(where)}: {', '.join(where[:6])}{' …' if len(where) > 6 else ''}")

    # 6. sys/ against Template_MiSTer
    section("6. sys/ against Template_MiSTer")
    sysd = tree / "sys"
    if not sysd.is_dir():
        print("no sys/ directory")
    elif tmpl is None or not (tmpl / "sys").is_dir():
        print("no Template_MiSTer tree given")
    else:
        cmp = filecmp.dircmp(sysd, tmpl / "sys")
        # line endings differ between cores (CRLF/LF); prepare_sources.py reads both
        def same_text(name):
            a, b = ((d / name).read_bytes().replace(b"\r\n", b"\n") for d in (sysd, tmpl / "sys"))
            return a == b
        eol = sorted(n for n in cmp.diff_files if same_text(n))
        diff = sorted(n for n in cmp.diff_files if n not in eol)
        print(f"- differing files: {len(diff)}" + (f": {', '.join(diff)}" if diff else ""))
        print(f"- only line endings differ (CRLF/LF): {len(eol)}")
        print(f"- only in the core: {', '.join(sorted(cmp.left_only)) or 'none'}")
        print(f"- only in the template: {', '.join(sorted(cmp.right_only)) or 'none'}")
        if "sys_top.v" in diff:
            print("- sys_top.v differs: prepare_sources.py rewrites it by exact text; its run shows"
                  " whether every block and literal was found")

    # 7. lint
    section("7. Lint (found here instead of in a build or on the hardware)")
    shown = prof["dir"] if prof and not prof["dir"].is_relative_to(MISTER) else prof["dir"].relative_to(MISTER) if prof else None
    print(f"Profile: {shown or 'none (no cores/*/core.tcl with this core_name)'}\n")
    errors, warnings, infos = lint(tree, texts, hits, prof)
    for tag, lst in (("ERROR", errors), ("WARN", warnings), ("INFO", infos)):
        for line in lst:
            print(f"- {tag}: {line}")
    print(f"\nlint: {len(errors)} errors, {len(warnings)} warnings")
    return 1 if strict and errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
