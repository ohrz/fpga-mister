#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Unit tests of prepare_sources.py
#  Project    : fpga-mister
#  File       : prepare_sources_test.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-30
# ----------------------------------------------------------------------------------
#  Description: Tests of the source transformations that change what Vivado builds
#               without an error message when they are wrong: rule_declarations_first
#               (use before declaration) and fix_vhdl_port_case (spelling of named
#               connections to VHDL entities), convert_mif_files (memory contents)
#               rule_vhdl_intel_libraries and rule_vhdl_unit_order, the mid clock rules
#               falling_edge_to, add_port, connect_port.  Run by selfcheck.sh
#               (make test):
#                 python3 prepare_sources_test.py
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------

import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import prepare_sources as ps  # noqa: E402


MODULE = """module top
(
\tinput clk,
\toutput [7:0] q
);
`include "build_id.v"
child c (.a(addr), .y(q));
wire [15:0] addr;
wire [7:0] sum = addr[7:0] + 8'd1; // comment kept
localparam W = 8;
generate if (W == 8) begin : g
\twire [3:0] inner;
end endgenerate
always @(posedge clk) begin
\treg_x <= sum;
end
reg [7:0] reg_x = 8'h00;
endmodule
"""


class DeclarationsFirst(unittest.TestCase):
    def test_moves_module_level_declarations(self):
        out, count = ps.rule_declarations_first(MODULE)
        lines = [l.strip() for l in out.split("\n")]
        self.assertEqual(count, 5)  # include, addr, sum, W, reg_x
        top = lines.index("// declarations moved to the top of the module (Vivado: no use before declaration)")
        self.assertEqual(lines[top + 1:top + 6], ['`include "build_id.v"', "wire [15:0] addr;", "wire [7:0] sum;",
                                                  "localparam W = 8;", "reg [7:0] reg_x = 8'h00;"])
        # declarations come before the first use, the initial value of a wire becomes an assign in place
        self.assertLess(top, lines.index("child c (.a(addr), .y(q));"))
        self.assertIn("assign sum = addr[7:0] + 8'd1; // comment kept", lines)
        # declarations inside a block stay where they are
        self.assertIn("wire [3:0] inner;", lines[lines.index("generate if (W == 8) begin : g"):])
        self.assertEqual(lines.count("wire [3:0] inner;"), 1)

    def test_port_list_and_end_unchanged(self):
        out, _ = ps.rule_declarations_first(MODULE)
        self.assertTrue(out.startswith("module top\n(\n\tinput clk,\n\toutput [7:0] q\n);\n// declarations moved"))
        self.assertTrue(out.rstrip().endswith("endmodule"))

    def test_several_initialised_wires_refused(self):
        _, count = ps.rule_declarations_first("module m(input a);\nwire x = a, y = a;\nendmodule\n")
        self.assertEqual(count, -1)


ENT_VHD = """library ieee; use ieee.std_logic_1164.all;
entity ChipMap is
\tgeneric (ADDR_W : integer := 8);
\tport(
\t\tMCLK, RST_N : in std_logic;
\t\tENABLE   : in std_logic := '1';  -- default
\t\tDO       : out std_logic_vector(7 downto 0)
\t);
end ChipMap;
entity small is port (Clk : in std_logic; Q : out std_logic); end entity;
"""

TOP_SV = """module top(input clk, input rst, output [7:0] d, output q);
ChipMap #(.addr_w(4)) map (.mclk(clk), .rst_n(rst), .do(d));
small s(.clk(clk), .q(q));
dual u (.clk(clk));
endmodule
"""

DUAL_V = "module dual(input clk);\nendmodule\n"
DUAL_VHD = "entity DUAL is port (CLK : in bit); end entity;\n"


class VhdlPortCase(unittest.TestCase):
    def test_rewrites_connection_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "rtl").mkdir()
            (root / "rtl" / "ent.vhd").write_text(ENT_VHD)
            (root / "rtl" / "dual.vhd").write_text(DUAL_VHD)
            (root / "rtl" / "dual.v").write_text(DUAL_V)
            (root / "top.sv").write_text(TOP_SV)
            count = ps.fix_vhdl_port_case(root)
            out = (root / "top.sv").read_text()
        self.assertEqual(count, 6)
        self.assertIn("ChipMap #(.ADDR_W(4)) map (.MCLK(clk), .RST_N(rst), .DO(d));", out)
        self.assertIn("small s(.Clk(clk), .Q(q));", out)
        # a Verilog module of the same name wins: its connections stay as written
        self.assertIn("dual u (.clk(clk));", out)

    def test_interface_names(self):
        names = ps.vhdl_interface_names(ENT_VHD)
        self.assertEqual(names["chipmap"], {"addr_w": "ADDR_W", "mclk": "MCLK", "rst_n": "RST_N",
                                            "enable": "ENABLE", "do": "DO"})
        self.assertEqual(names["small"], {"clk": "Clk", "q": "Q"})


RAM_VHD = """entity ram is
\tgeneric (AW : integer := 8; INIT : string := " ");
\tport (
\t\tclock     : in  std_logic;
\t\tenable_a, cs_a : in std_logic := '1';    -- two ports, one default
\t\tdata_b    : in  std_logic_vector(AW-1 downto 0) := (others => '0');
\t\tfmt       : in  unsigned(1 downto 0) :="01";
\t\tborder    : IN  unsigned(7 downto 0) := x"A5";
\t\tq_b       : out std_logic_vector(7 downto 0) := x"00";
\t\tbus_io   : inout std_logic := 'Z';
\t\tmask      : in  std_logic_vector(AW-1 downto 0) := (AW-1 => '1', others => '0')
\t);
end entity;
entity plain is port (a : in std_logic; b : out std_logic); end entity;
"""

RAM_SV = """module top(input clk, output [7:0] q);
ram #(.AW(8)) r1 (
\t.clock(clk), // .enable_a(x) in a comment does not count
\t.cs_a(),
\t.mask(8'h80),
\t.q_b(q)
);
ram r2(.clock(clk), .enable_a(1'b0), .cs_a(1'b1), .data_b(8'd0), .fmt(2'b11), .border(8'd0), .mask(8'h01));
ram r3(clk, 1'b1);
ram #(.AW(4)) r4(clk, 1'b1);
plain p(.a(clk));
endmodule
"""


class VhdlPortDefaults(unittest.TestCase):
    def test_port_defaults(self):
        ports = ps.vhdl_port_defaults(RAM_VHD)
        self.assertEqual(sorted(ports["ram"]), ["border", "cs_a", "data_b", "enable_a", "fmt", "mask"])
        self.assertEqual(ports["ram"]["cs_a"], ("cs_a", "'1'"))
        self.assertEqual(ports["plain"], {})

    def test_literals(self):
        self.assertEqual([ps.vhdl_default_literal(v) for v in ["'1'", "(others => '0')", '"01"', 'x"A5"', "3", "true"]],
                         ["1'b1", "'0", "2'b01", "8'ha5", "3", "1'b1"])
        self.assertIsNone(ps.vhdl_default_literal("(AW-1 => '1', others => '0')"))

    def test_connects_open_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "ram.vhd").write_text(RAM_VHD)
            (root / "top.sv").write_text(RAM_SV)
            count, errors = ps.connect_vhdl_port_defaults(root)
            out = (root / "top.sv").read_text()
        # r1: cs_a() filled, enable_a, data_b, fmt, border added; mask, q_b connected
        self.assertEqual(count, 5)
        self.assertEqual(errors, [])
        self.assertIn("\t.cs_a(1'b1),\n", out)
        self.assertIn("\t.q_b(q),\n\t// VHDL port defaults (Vivado ties open inputs to 0)\n"
                      "\t.enable_a(1'b1),\n\t.data_b('0),\n\t.fmt(2'b01),\n\t.border(8'ha5)\n);", out)
        # all connected, positional, or no defaults: unchanged
        self.assertIn("ram r2(.clock(clk), .enable_a(1'b0), .cs_a(1'b1), .data_b(8'd0), .fmt(2'b11), "
                      ".border(8'd0), .mask(8'h01));", out)
        self.assertIn("ram r3(clk, 1'b1);", out)
        self.assertIn("ram #(.AW(4)) r4(clk, 1'b1);", out)
        self.assertIn("plain p(.a(clk));", out)

    def test_open_input_without_literal_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "ram.vhd").write_text(RAM_VHD)
            (root / "top.sv").write_text("ram r(.clock(c));\n")
            count, errors = ps.connect_vhdl_port_defaults(root)
        self.assertEqual(count, 5)
        self.assertEqual(errors, ["top.sv: ram.mask := (AW-1 => '1', others => '0')"])


MIF = """-- comment
WIDTH=12;
DEPTH=8;
ADDRESS_RADIX=HEX;
DATA_RADIX=HEX;
CONTENT BEGIN
\t[0..2]  :   ABC;
\t3 : 001 002;   -- two consecutive words
\t7 : FFF;
END;
"""

ROM_VHD = """rom : entity work.spram generic map(3, 12, "rtl/rom.mif")
other : entity work.spram generic map(3, 12, "rtl/missing.mif")
"""


class MifToMem(unittest.TestCase):
    def test_words(self):
        width, depth, words = ps.mif_words(MIF)
        self.assertEqual((width, depth), (12, 8))
        self.assertEqual(words, {0: 0xABC, 1: 0xABC, 2: 0xABC, 3: 1, 4: 2, 7: 0xFFF})

    def test_mem_file_and_literals(self):
        cwd = os.getcwd()
        with tempfile.TemporaryDirectory() as tmp:
            os.chdir(tmp)                       # relative tree: the HDL gets the absolute name
            self.addCleanup(os.chdir, cwd)
            root = pathlib.Path("tree")
            (root / "rtl").mkdir(parents=True)
            (root / "rtl" / "rom.mif").write_text(MIF)
            (root / "top.vhd").write_text(ROM_VHD)
            self.assertEqual(ps.convert_mif_files(root), (1, 1))
            mem = pathlib.Path(tmp).resolve() / "tree" / "rtl" / "rom.mif.mem"
            lines = mem.read_text().split("\n")
            out = (root / "top.vhd").read_text()
        self.assertEqual(lines[:-1], ["101010111100"] * 3 + ["000000000001", "000000000010", "000000000000",
                                                             "000000000000", "111111111111"])
        self.assertEqual(lines[-1], "")
        self.assertIn('generic map(3, 12, "' + str(mem) + '")', out)
        # a file that is not there stays as written
        self.assertIn('"rtl/missing.mif"', out)


BRAM_VHD = """LIBRARY ieee;
USE ieee.std_logic_1164.all;
LIBRARY altera_mf;
USE altera_mf.altera_mf_components.all;
entity ram is end entity;
architecture syn of ram is
begin
\taltsyncram_component : altsyncram
\tGENERIC MAP (width_a => 8)
\tPORT MAP (clock0 => clk);
end architecture;
"""

MULT_VHD = """LIBRARY lpm;
USE lpm.all;
architecture syn of m is
\tCOMPONENT lpm_mult
\tGENERIC (lpm_widtha : NATURAL);
\tEND COMPONENT;
begin
\tlpm_mult_component : lpm_mult
\tGENERIC MAP (lpm_widtha => 16)
end architecture;
"""


class VhdlIntelLibraries(unittest.TestCase):
    def test_clauses_and_entity_instance(self):
        out, count = ps.rule_vhdl_intel_libraries(BRAM_VHD)
        self.assertEqual(count, 3)
        self.assertIn("USE ieee.std_logic_1164.all;", out.split("\n"))
        self.assertIn("-- LIBRARY altera_mf;", out)
        self.assertIn("-- USE altera_mf.altera_mf_components.all;", out)
        self.assertIn("\taltsyncram_component : entity work.altsyncram\n", out)

    def test_local_component_kept(self):
        out, count = ps.rule_vhdl_intel_libraries(MULT_VHD)
        self.assertEqual(count, 2)
        self.assertIn("\tlpm_mult_component : lpm_mult\n", out)

    def test_untouched_without_intel_library(self):
        text = "architecture a of b is begin\n u : altsyncram generic map (x => 1);\nend;\n"
        self.assertEqual(ps.rule_vhdl_intel_libraries(text), (text, 0))


ORDER_VHD = """-- file header
library ieee;
use ieee.std_logic_1164.all;
entity top is port (a : in std_logic); end entity;
architecture rtl of top is
begin
\tu : entity work.leaf port map (a => a);  -- entity work.ignored in a comment
end architecture;

-- the leaf
library ieee;
use ieee.std_logic_1164.all;
use work.pkg.all;
entity leaf is port (a : in std_logic); end entity;
architecture rtl of leaf is begin end architecture;  -- no entity work.top here

package pkg is
end package;
"""


class VhdlUnitOrder(unittest.TestCase):
    def test_used_units_move_first(self):
        out, count = ps.rule_vhdl_unit_order(ORDER_VHD)
        self.assertEqual(count, 2)  # pkg and top swap places, leaf stays in the middle
        self.assertEqual([m.group(1) for m in map(ps.VHDL_UNIT_START.match, out.split("\n")) if m],
                         ["pkg", "leaf", "top"])
        # a pure reorder: same lines, the comments and context clauses travel with their unit
        self.assertEqual(sorted(out.split("\n")), sorted(ORDER_VHD.split("\n")))
        # comments right before a unit belong to it (also a file header: not told apart)
        self.assertTrue(out.startswith("\npackage pkg is\nend package;\n\n-- the leaf\nlibrary ieee;"))
        self.assertIn("-- the leaf\nlibrary ieee;\nuse ieee.std_logic_1164.all;\nuse work.pkg.all;\nentity leaf", out)
        self.assertIn("-- file header\nlibrary ieee;\nuse ieee.std_logic_1164.all;\nentity top", out)
        self.assertTrue(out.endswith("end architecture;\n"))

    def test_ordered_file_unchanged(self):
        out, _ = ps.rule_vhdl_unit_order(ORDER_VHD)
        self.assertEqual(ps.rule_vhdl_unit_order(out), (out, 0))

    def test_circular_use_refused(self):
        text = ("entity a is end;\narchitecture r of a is begin u : entity work.b; end;\n"
                "entity b is end;\narchitecture r of b is begin u : entity work.a; end;\n")
        self.assertEqual(ps.rule_vhdl_unit_order(text), (text, -1))



class FallingEdge(unittest.TestCase):
    """falling_edge_to, add_port, connect_port: the mid clock of a derived clock."""

    def test_verilog_edges(self):
        text = ("always @(negedge clk_sys) a <= b;\n"
                "always @(posedge clk_sys or negedge reset_n) c <= d;\n"
                "always @(negedge clk_sys2) e <= f;\n"
                "cpu u (.CLKx2(~clk_sys), .clk(clk_sys), .en(!clk_sys));\n")
        out, n = ps.falling_edge_to("clk_sys", "clk_sys_mid")(text)
        self.assertEqual(n, 3)
        self.assertIn("always @(posedge clk_sys_mid) a <= b;", out)
        self.assertIn("always @(posedge clk_sys or negedge reset_n)", out)
        self.assertIn("negedge clk_sys2", out)
        self.assertIn(".CLKx2(clk_sys_mid), .clk(clk_sys), .en(clk_sys_mid)", out)

    def test_vhdl_process_sensitivity(self):
        text = ("p1 : process(clk_sys)\nbegin\n  if falling_edge(clk_sys) then ce <= '1'; end if;\n"
                "end process;\n"
                "process (CLK, RST_N)\nbegin\n  if RST_N = '0' then x <= '0';\n"
                "  elsif rising_edge(clk) then x <= y; end if;\n"
                "  if Falling_Edge(Clk) then z <= x; end if;\nend process;\n"
                "process (clk)\nbegin\n  if rising_edge(clk) then q <= r; end if;\nend process;\n"
                "ram : entity work.dpram port map (clock => not CLK, data => d);\n")
        out, n = ps.falling_edge_to("clk", "clk_mid")(text.replace("clk_sys", "clk"))
        self.assertEqual(n, 3)
        self.assertIn("p1 : process(clk_mid)\nbegin\n  if rising_edge(clk_mid) then", out)
        self.assertIn("process (CLK, RST_N, clk_mid)", out)
        self.assertIn("if rising_edge(clk_mid) then z <= x;", out)
        self.assertIn("process (clk)\nbegin\n  if rising_edge(clk) then q <= r;", out)
        self.assertIn("clock => clk_mid, data", out)

    def test_add_port_verilog_ansi(self):
        text = "module video #(parameter W = $clog2(8))\n(\n\tinput clk,\n\toutput [W-1:0] q\n);\nendmodule\n"
        out, n = ps.add_port("video", "input clk_mid")(text)
        self.assertEqual(n, 1)
        self.assertIn("(\n\tinput clk_mid,\n\tinput clk,", out)
        self.assertEqual(ps.add_port("vid", "input clk_mid")(text)[1], 0)
        out, n = ps.add_port("top", "input clk_mid")("module top();\nendmodule\n")
        self.assertEqual((out, n), ("module top(\n\tinput clk_mid);\nendmodule\n", 1))

    def test_add_port_verilog_include(self):
        # MiSTer's emu: the port list is `include "sys/emu_ports.vh" (ANSI declarations)
        text = 'module emu\n(\n\t`include "sys/emu_ports.vh"\n);\nendmodule\n'
        out, n = ps.add_port("emu", "output ZYNQ_PACE_ALT")(text)
        self.assertEqual(n, 1)
        self.assertIn('(\n\toutput ZYNQ_PACE_ALT,\n\t`include "sys/emu_ports.vh"\n);', out)

    def test_add_port_verilog_non_ansi(self):
        text = "module gb(clk_sys, q);\ninput clk_sys;\noutput q;\nendmodule\n"
        out, n = ps.add_port("gb", "input clk_sys_mid")(text)
        self.assertEqual(n, 1)
        self.assertIn("module gb(clk_sys_mid, clk_sys, q);\n\tinput clk_sys_mid;\ninput clk_sys;", out)

    def test_add_port_vhdl(self):
        text = "entity speedcontrol is\n   port\n   (\n      clk_sys : in std_logic;\n"
        out, n = ps.add_port("speedcontrol", "clk_sys_mid : in std_logic")(text)
        self.assertEqual(n, 1)
        self.assertIn("   (\n\t\tclk_sys_mid : in std_logic;\n      clk_sys : in std_logic;", out)
        # an entity without ports: not the port list of a later component
        text = "entity sc is\n  generic (N : natural := 2);\nend entity;\ncomponent x port (y : in bit); end component;\n"
        self.assertEqual(ps.add_port("sc", "m : in bit")(text), (text, 0))

    def test_connect_port_verilog(self):
        text = ("module video(input clk);\nendmodule\n"
                "video #(.W(8)) video (\n\t.clk(clk_sys)\n);\n"
                "video v2[1:0] (.clk(c));\n"
                "video v3 (a, b);\n"
                "my_video v4 (.clk(c));\n"
                "video v5 ();\n")
        out, n = ps.connect_port("video", "clk_mid", "clk_sys_mid")(text)
        self.assertEqual(n, 3)
        self.assertIn("video v5 (\n\t.clk_mid(clk_sys_mid));", out)
        self.assertIn("module video(input clk);", out)
        self.assertIn("video #(.W(8)) video (\n\t.clk_mid(clk_sys_mid),\n\t.clk(clk_sys)", out)
        self.assertIn("video v2[1:0] (\n\t.clk_mid(clk_sys_mid),.clk(c));", out)
        self.assertIn("video v3 (a, b);", out)
        self.assertIn("my_video v4 (.clk(c));", out)

    def test_connect_port_vhdl(self):
        text = ("component sc port (clk : in std_logic); end component;\n"
                "u1 : entity work.sc generic map (N => 2) port map (clk => c);\n"
                "u2: sc\n  port map(\n    clk => c\n  );\n"
                "u3 : sc generic map (N => 1);\nu4 : other port map (clk => c);\n")
        out, n = ps.connect_port("sc", "clk_mid", "c_mid")(text)
        self.assertEqual(n, 2)
        self.assertIn("generic map (N => 2) port map (\n\t\tclk_mid => c_mid,clk => c);", out)
        self.assertIn("port map(\n\t\tclk_mid => c_mid,\n    clk => c", out)
        self.assertIn("component sc port (clk : in std_logic);", out)
        self.assertIn("u4 : other port map (clk => c);", out)


if __name__ == "__main__":
    unittest.main(verbosity=1)
