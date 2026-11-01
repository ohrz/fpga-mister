#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Unit tests of the lint of core_survey.py
#  Project    : fpga-mister
#  File       : core_survey_test.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-30
# ----------------------------------------------------------------------------------
#  Description: Tests of the lint section (core_survey.py §7) on a small synthetic core
#               tree: falling edges traced through the instances to the PLL output
#               (derived clock = error, fastest = info, asynchronous reset negedge not a
#               clock, inverted clock to a port), the profile's patches mark a file as
#               handled, .sdc path exceptions against core.xdc, the clock budget,
#               Intel primitives with and without a replacement, open VHDL inputs with
#               defaults (counted, checkout unchanged), free-running clocks (G_FREE_CLK),
#               VHDL libraries other than work, VHDL 2008 by the .qsf and --strict.  Run by
#               selfcheck.sh (make test):
#                 python3 core_survey_test.py
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------

import collections
import contextlib
import io
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import core_survey as cs  # noqa: E402

QIP = """set_global_assignment -name SYSTEMVERILOG_FILE [file join $::quartus(qip_path) core.sv]
set_global_assignment -name VHDL_FILE [file join $::quartus(qip_path) rtl/main.vhd]
set_global_assignment -name VHDL_FILE [file join $::quartus(qip_path) rtl/sub.vhd]
set_global_assignment -name VERILOG_FILE [file join $::quartus(qip_path) rtl/fifo.v]
"""

EMU = """module emu
(
\tinput CLK_50M,
\tinput RESET
);
wire clk_fast, clk_slow{extra_nets};
pll pll
(
\t.refclk(CLK_50M),
\t.outclk_0(clk_fast),
\t.outclk_1(clk_slow){extra_outs}
);
main main
(
\t.CLK(clk_slow),
\t.FCLK(clk_fast),
\t.RESET(RESET)
);
sub vsub
(
\t.C(clk_fast),
\t.D(1'b0)
);
always @(posedge clk_fast or negedge reset_n) q <= 1'b0;
dcfifo fifo (.data(d), .q(q));
endmodule
"""

PLL = """module pll_0002(input refclk);
altera_pll #(
\t.output_clock_frequency0("90.000000 MHz"),
\t.output_clock_frequency1("22.500000 MHz"),
\t.output_clock_frequency2("45.000000 MHz"),
\t.output_clock_frequency3("30.000000 MHz"),
\t.number_of_clocks(4)
) altera_pll_i ();
endmodule
"""

MAIN = """library ieee;
use ieee.std_logic_1164.all;
entity main is
\tport (CLK : in std_logic; FCLK : in std_logic; RESET : in std_logic);
end main;
architecture rtl of main is
begin
\tprocess (CLK) begin
\t\tif falling_edge(CLK) then
\t\t\tq <= d;
\t\tend if;
\tend process;
\tprocess (FCLK) begin
\t\tif FCLK'event and FCLK = '0' then
\t\t\tr <= d;
\t\tend if;
\tend process;
\tu : entity work.sub port map (C => CLK, D => '0');
\tram : altsyncram generic map (width_a => 8) port map (clock0 => not CLK, address_a => a);
end rtl;
"""

SUB = """library ieee;
use ieee.std_logic_1164.all;
entity sub is
\tport (C : in std_logic; D : in std_logic; EN : in std_logic := '1');
end sub;
architecture rtl of sub is
begin
\tprocess (C) begin
\t\tif falling_edge(C) then
\t\t\tq <= D;
\t\tend if;
\tend process;
end rtl;
"""

FIFO = """module fifo_wrap(input clk);
scfifo f (.clock(clk));
always @(negedge clk or negedge rst_n) q <= 1'b0;
always @(posedge clk or negedge locked) r <= 1'b0;
endmodule
"""

SDC = """derive_pll_clocks
set_max_delay 20 -from [get_registers {emu|main|*}] -to [get_registers {emu|sdram|*}]
# set_false_path -from {commented}
set_false_path -from {emu|x} ;# set_max_delay in a trailing comment
"""


def make_tree(root, extra_clocks=0):
    tree = root / "Test_MiSTer"
    (tree / "rtl" / "pll").mkdir(parents=True)
    nets = "".join(f", clk_x{i}" for i in range(extra_clocks))
    outs = "".join(f",\n\t.outclk_{2 + i}(clk_x{i})" for i in range(extra_clocks))
    (tree / "files.qip").write_text(QIP)
    (tree / "core.sv").write_text(EMU.format(extra_nets=nets, extra_outs=outs))
    (tree / "rtl" / "pll" / "pll_0002.v").write_text(PLL)
    (tree / "rtl" / "main.vhd").write_text(MAIN)
    (tree / "rtl" / "sub.vhd").write_text(SUB)
    (tree / "rtl" / "fifo.v").write_text(FIFO)
    (tree / "Test.sdc").write_text(SDC)
    return tree


def make_profile(root, patched=(), xdc_exceptions=0, exclude=(), rules="", extra_tcl=""):
    prof = root / "prof"
    (prof / "patches").mkdir(parents=True)
    xdc = prof / "core.xdc"
    xdc.write_text("".join(f"set_max_delay 19.0 -from [get_cells a{i}] -to [get_cells b{i}]\n"
                           for i in range(xdc_exceptions)))
    (prof / "core.tcl").write_text(
        "set core_name    Test_MiSTer\n"
        f"set core_exclude {{{' '.join(exclude)}}}\n"
        "set core_add     {}\n"
        f"set core_xdc     {{{xdc}}}\n" + extra_tcl)
    (prof / "rules.py").write_text(rules)
    if patched:
        (prof / "patches" / "0001-x.patch").write_text(
            "".join(f"--- a/{f}\n+++ b/{f}\n@@ -1 +1 @@\n-a\n+b\n" for f in patched))
    return cs.read_profile(prof)


def run_lint(tree, prof=None):
    files = [p for p in cs.files_of_qip(tree / "files.qip") if p.exists()]
    texts = {p: p.read_bytes().decode("latin-1") for p in files}
    hits = collections.defaultdict(list)
    for p, t in texts.items():
        for n, line in enumerate(t.splitlines(), 1):
            m = cs.INST.match(line.split("//")[0].split("--")[0])
            if m:
                hits[m.group("type").lower()].append(f"{p.relative_to(tree)}:{n}")
    return cs.lint(tree, texts, hits, prof)


def having(lines, *words):
    return [x for x in lines if all(w in x for w in words)]


class Lint(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.tree = make_tree(self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def test_falling_edge_on_derived_clock_is_an_error(self):
        errors, warnings, infos = run_lint(self.tree)
        self.assertTrue(having(errors, "rtl/main.vhd:9", "falling_edge on CLK", "derived clock clk_slow"))
        # sub runs on clk_slow through main (u) and on clk_fast from emu (vsub): derived wins
        self.assertTrue(having(errors, "rtl/sub.vhd:9", "falling_edge on C", "clk_slow"))

    def test_falling_edge_on_fastest_clock_is_info(self):
        errors, warnings, infos = run_lint(self.tree)
        self.assertTrue(having(infos, "rtl/main.vhd:14", "falling_edge on FCLK", "fastest clock"))
        self.assertFalse(having(errors + warnings, "FCLK"))

    def test_reset_negedge_is_not_a_clock(self):
        errors, warnings, infos = run_lint(self.tree)
        self.assertFalse(having(errors + warnings + infos, "reset_n"))
        # negedge clock with negedge reset (no posedge): the clock counts, the reset does not
        self.assertTrue(having(errors + warnings + infos, "rtl/fifo.v:3", "negedge on clk"))
        self.assertFalse(having(errors + warnings + infos, "rst_n"))
        # negedge of a signal that is no clock next to a posedge: an asynchronous reset too
        self.assertFalse(having(errors + warnings + infos, "locked"))

    def test_inverted_clock_to_a_port(self):
        errors, warnings, infos = run_lint(self.tree)
        self.assertTrue(having(errors, "rtl/main.vhd:19", "inverted clock to port clock0 on CLK", "clk_slow"))

    def test_patch_of_the_profile_marks_the_file(self):
        prof = make_profile(self.root, patched=["rtl/main.vhd"], xdc_exceptions=2)
        errors, warnings, infos = run_lint(self.tree, prof)
        self.assertFalse(having(errors, "rtl/main.vhd"))
        self.assertTrue(having(warnings, "rtl/main.vhd:9", "touch the file"))
        self.assertTrue(having(errors, "rtl/sub.vhd:9"))

    def test_sdc_exceptions_against_core_xdc(self):
        prof = make_profile(self.root, xdc_exceptions=1)
        errors, warnings, infos = run_lint(self.tree, prof)
        self.assertTrue(having(warnings, "Test.sdc: 2 path exceptions", "core.xdc of the profile: 1", "translate"))
        prof = make_profile(pathlib.Path(tempfile.mkdtemp(dir=self.root)), xdc_exceptions=2)
        errors, warnings, infos = run_lint(self.tree, prof)
        self.assertTrue(having(infos, "Test.sdc: 2 path exceptions", "core.xdc of the profile: 2"))
        self.assertFalse(having(warnings, "Test.sdc"))
        self.assertFalse(having(infos + warnings, "commented"))
        # a trailing comment is neither a constraint nor part of the constraint's text
        self.assertEqual([(c, x) for _, c, x in cs.timing_exceptions(SDC)],
                         [("set_max_delay", SDC.splitlines()[1]), ("set_false_path", "set_false_path -from {emu|x} ;")])

    def test_clock_budget(self):
        errors, warnings, infos = run_lint(self.tree)
        self.assertTrue(having(infos, "core clocks from the PLL: 2", "fastest clk_fast"))
        tree = make_tree(pathlib.Path(tempfile.mkdtemp(dir=self.root)), extra_clocks=2)
        errors, warnings, infos = run_lint(tree)
        self.assertTrue(having(warnings, "core clocks from the PLL: 4", "more than 3 clocks"))

    def test_primitives(self):
        errors, warnings, infos = run_lint(self.tree)
        self.assertTrue(having(errors, "dcfifo", "without a replacement", "core.sv:25"))
        self.assertTrue(having(errors, "scfifo", "rtl/fifo.v:2"))
        self.assertTrue(having(infos, "altsyncram", "replaced by hdl/intel/altsyncram.vhd"))
        prof = make_profile(self.root, exclude=["*/rtl/fifo.v"], xdc_exceptions=2)
        errors, warnings, infos = run_lint(self.tree, prof)
        self.assertTrue(having(infos, "scfifo", "only in files the profile excludes"))
        self.assertTrue(having(errors, "dcfifo"))

    def test_port_defaults_counted_tree_unchanged(self):
        before = (self.tree / "core.sv").read_text()
        errors, warnings, infos = run_lint(self.tree)
        self.assertTrue(having(infos, "open VHDL inputs with a default in Verilog instances: 1 "))
        self.assertEqual((self.tree / "core.sv").read_text(), before)

    def test_free_clock(self):
        # G_FREE_CLK 1 (N64): MMCM clocks, falling edges keep their half period, no cascade
        prof = make_profile(self.root, xdc_exceptions=2,
                            extra_tcl="set core_generics {\n  G_FREE_CLK         1\n  G_DDRAM 1\n}\n")
        self.assertEqual(prof["generics"], {"G_FREE_CLK": "1", "G_DDRAM": "1"})
        errors, warnings, infos = run_lint(self.tree, prof)
        self.assertFalse(having(errors, "falling_edge"))
        self.assertTrue(having(infos, "rtl/main.vhd:9", "G_FREE_CLK"))
        self.assertTrue(having(infos, "core clocks from the PLL: 2", "no BUFGCE cascade"))

    def test_vhdl_library(self):
        (self.tree / "rtl" / "lib.vhd").write_text("library ieee;\nlibrary mem; -- ram\n-- library old;\n"
                                                   "use mem.ram_pkg.all;\nentity l is end l;\n")
        with open(self.tree / "files.qip", "a") as q:
            q.write("set_global_assignment -name VHDL_FILE [file join $::quartus(qip_path) rtl/lib.vhd]\n")
        errors, warnings, infos = run_lint(self.tree, make_profile(self.root, xdc_exceptions=2))
        self.assertTrue(having(errors, "VHDL library mem", "rtl/lib.vhd:2"))
        self.assertFalse(having(errors + warnings + infos, "library old"))
        self.assertFalse(having(errors + warnings + infos, "library ieee"))
        prof = make_profile(pathlib.Path(tempfile.mkdtemp(dir=self.root)), xdc_exceptions=2,
                            rules='RULES = [("mem-lib", "rtl/*.vhd", regex(r"(?im)^(\\s*)library\\s+mem\\s*;", ""), 1)]\n')
        errors, warnings, infos = run_lint(self.tree, prof)
        self.assertFalse(having(errors, "VHDL library"))
        self.assertTrue(having(infos, "VHDL library mem", "rules.py renames it"))

    def test_vhdl_2008_by_qsf(self):
        (self.tree / "Test.qsf").write_text("set_global_assignment -name VHDL_INPUT_VERSION VHDL_2008\n")
        errors, warnings, infos = run_lint(self.tree, make_profile(self.root, xdc_exceptions=2))
        self.assertTrue(having(errors, "Test.qsf", "core_vhdl_std 2008"))
        prof = make_profile(pathlib.Path(tempfile.mkdtemp(dir=self.root)), xdc_exceptions=2,
                            extra_tcl="set core_vhdl_std 2008\n")
        errors, warnings, infos = run_lint(self.tree, prof)
        self.assertFalse(having(errors, "Test.qsf"))
        self.assertTrue(having(infos, "Test.qsf", "reads the core as VHDL 2008"))

    def test_strict_exit_code(self):
        prof = make_profile(self.root, xdc_exceptions=2)
        with contextlib.redirect_stdout(io.StringIO()) as out:
            plain = cs.main(["core_survey.py", "--profile", str(prof["dir"]), str(self.tree)])
            strict = cs.main(["core_survey.py", "--strict", "--profile", str(prof["dir"]), str(self.tree)])
        self.assertEqual((plain, strict), (0, 1))
        self.assertIn("## 7. Lint", out.getvalue())
        self.assertIn("lint: ", out.getvalue())


if __name__ == "__main__":
    unittest.main()
