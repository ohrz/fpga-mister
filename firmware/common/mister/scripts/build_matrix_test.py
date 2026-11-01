#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Unit tests of build_matrix.py
#  Project    : fpga-mister
#  File       : build_matrix_test.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-30
# ----------------------------------------------------------------------------------
#  Description: Report parsing on excerpts of the routed reports of zybo-z7-20_msx_hdmi
#               (Vivado 2025.2), the verdict per design (timing, routing, missing
#               reports, failed build), the STATUS.md row and its update, the
#               selection of board x core; plus the real reports in firmware/build
#               when a build is there.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
import glob, os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_matrix as bm  # noqa: E402

TIMING = """\
------------------------------------------------------------------------------------------------
| Design Timing Summary
| ---------------------
------------------------------------------------------------------------------------------------

    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints     WPWS(ns)     TPWS(ns)  TPWS Failing Endpoints  TPWS Total Endpoints
    -------      -------  ---------------------  -------------------      -------      -------  ---------------------  -------------------     --------     --------  ----------------------  --------------------
      0.127        0.000                      0                43304        0.051        0.000                      0                43304        0.538        0.000                       0                 17289


All user specified timing constraints are met.
"""
TIMING_FAIL = TIMING.replace("      0.127        0.000                      0",
                             "     -0.050       -1.250                     40").replace(
    "All user specified timing constraints are met.", "Timing constraints are not met.")
UTIL = """\
+----------------------------+-------+-------+------------+-----------+-------+
|          Site Type         |  Used | Fixed | Prohibited | Available | Util% |
+----------------------------+-------+-------+------------+-----------+-------+
| Slice LUTs                 | 18572 |     0 |          0 |     53200 | 34.91 |
|   LUT as Logic             | 17890 |     0 |          0 |     53200 | 33.63 |
| Slice Registers            | 15780 |     0 |          0 |    106400 | 14.83 |
+-------------------+------+-------+------------+-----------+-------+
| Block RAM Tile    | 26.5 |     0 |          0 |       140 | 18.93 |
|   RAMB36/FIFO*    |   41 |     0 |          0 |       140 | 29.29 |
+----------------+------+-------+------------+-----------+-------+
| DSPs           |   35 |     0 |          0 |       220 | 15.91 |
"""
ROUTE = """\
Design Route Status
                                               :      # nets :
   ------------------------------------------- : ----------- :
   # of routable nets..................... :       34272 :
       # of fully routed nets............. :       34272 :
       # of nets with routing errors.......... :           0 :
"""
HEAD = "| Board | Stage | Evidence | Commit | Date | Measurement / Remark |\n|---|---|---|---|---|---|\n"


class Reports(unittest.TestCase):

    def test_timing(self):
        t = bm.parse_timing(TIMING)
        self.assertEqual((t["wns"], t["tns"], t["whs"], t["ths"], t["met"]), (0.127, 0.0, 0.051, 0.0, True))
        f = bm.parse_timing(TIMING_FAIL)
        self.assertEqual((f["wns"], f["tns"], f["met"]), (-0.05, -1.25, False))
        self.assertIsNone(bm.parse_timing("no table"))

    def test_util_route(self):
        self.assertEqual(bm.parse_util(UTIL), dict(lut=18572, ff=15780, bram=26.5, dsp=35))
        self.assertEqual(bm.parse_route(ROUTE), 0)
        self.assertEqual(bm.parse_route(ROUTE.replace("..... :           0", "..... :           3")), 3)
        self.assertIsNone(bm.parse_route(""))


class Evaluate(unittest.TestCase):

    def impl(self, timing=TIMING, util=UTIL, route=ROUTE):
        d = tempfile.mkdtemp()
        for name, text in (("timing_summary_routed", timing), ("utilization_placed", util), ("route_status", route)):
            if text is not None:
                with open(os.path.join(d, "design_1_wrapper_%s.rpt" % name), "w") as f:
                    f.write(text)
        return d

    def test_verdicts(self):
        r = bm.evaluate(self.impl())
        self.assertTrue(r["ok"], r)
        self.assertEqual((r["wns"], r["whs"], r["lut"], r["bram"]), (0.127, 0.051, 18572, 26.5))
        cases = [(dict(timing=TIMING_FAIL), "timing not met"),
                 (dict(timing=TIMING.replace("0.051        0.000", "-0.010       -0.020")), "timing not met"),
                 (dict(route=ROUTE.replace("..... :           0", "..... :           3")), "3 nets with routing errors"),
                 (dict(route=None), "no route status"),
                 (dict(timing=TIMING.replace("are met.", "are not met (pulse width).")), "timing not met"),
                 (dict(timing=None), "no routed timing report"),
                 (dict(timing="x"), "no Design Timing Summary")]
        for kw, reason in cases:
            r = bm.evaluate(self.impl(**kw))
            self.assertFalse(r["ok"], (kw, r))
            self.assertEqual(r["reason"], reason)
        r = bm.evaluate(self.impl(), build_ok=False)
        self.assertEqual((r["ok"], r["reason"]), (False, "build failed"))

    def test_real_reports(self):
        impls = glob.glob(os.path.join(HERE, "../../../build/*/*/hw/*/*.runs/impl_1"))
        impls = [d for d in impls if os.path.isfile(os.path.join(d, "design_1_wrapper_timing_summary_routed.rpt"))]
        if not impls:
            self.skipTest("no routed design in firmware/build")
        for d in impls:
            r = bm.evaluate(d)
            self.assertIsNotNone(r["wns"], d)
            self.assertIsNotNone(r["lut"], d)


class Rows(unittest.TestCase):

    def test_row(self):
        ok = dict(ok=True, reason="", wns=0.127, whs=0.051, lut=18572, bram=68.0)
        self.assertEqual(bm.row("b", "b_x_hdmi", "abc1234", "2026-10-30", ok),
                         "| b | timing | Timing | abc1234 | 2026-10-30 | `b_x_hdmi` WNS +0.127 ns, WHS +0.051 ns, "
                         "18,572 LUT, 68 BRAM tiles (build_matrix) |")
        bad = dict(ok, ok=False, reason="timing not met", wns=-0.05, bram=26.5)
        self.assertEqual(bm.row("b", "d", "c", "t", bad),
                         "| b | timing | FAIL | c | t | `d` WNS −0.050 ns, WHS +0.051 ns, 18,572 LUT, "
                         "26.5 BRAM tiles – timing not met (build_matrix) |")
        none = dict(ok=False, reason="build failed", wns=None, whs=None, lut=None, bram=None)
        self.assertEqual(bm.row("b", "d", "c", "t", none), "| b | timing | FAIL | c | t | `d` – build failed (build_matrix) |")

    def write(self, rows):
        fd, p = tempfile.mkstemp(suffix=".md")
        with os.fdopen(fd, "w") as f:
            f.write("# x\n\n" + HEAD + rows + "\nmore text\n")
        return p

    def table(self, p):
        return [line for line in open(p).read().split("\n") if line.startswith("| b ")]

    def test_update(self):
        new = "| b | timing | Timing | c2 | d | new |"
        p = self.write("| b | ooc | OOC | c | d | |\n| b | timing | FAIL | c | d | old |\n| b | load | HW | c | d | |\n")
        self.assertTrue(bm.update_status(p, "b", new))
        self.assertEqual(self.table(p), ["| b | ooc | OOC | c | d | |", new, "| b | load | HW | c | d | |"])
        self.assertFalse(bm.update_status(p, "b", new))
        self.assertTrue(open(p).read().endswith("\nmore text\n"))
        # missing row: after the earlier stages, before the later ones
        p = self.write("| b | prepare | Script | c | d | |\n| b | ooc | OOC | c | d | |\n| b | speed | HW | c | d | |\n")
        bm.update_status(p, "b", new)
        self.assertEqual([r.split("|")[2].strip() for r in self.table(p)], ["prepare", "ooc", "timing", "speed"])
        p = self.write("| b | prepare | Script | c | d | |\n")
        bm.update_status(p, "b", new)
        self.assertEqual(self.table(p)[-1], new)
        # another board's timing row stays
        p = self.write("| a | timing | Timing | c | d | |\n| b | ooc | OOC | c | d | |\n")
        bm.update_status(p, "b", new)
        self.assertIn("| a | timing | Timing | c | d | |", open(p).read())
        self.assertEqual(self.table(p), ["| b | ooc | OOC | c | d | |", new])


class Selection(unittest.TestCase):

    def test_pairs(self):
        root = tempfile.mkdtemp()

        def w(rel, text):
            p = os.path.join(root, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as f:
                f.write(text)
        w("firmware/targets/b/platform.mk", "MISTER_CORES := b_menu$(SUFFIX):menu b_msx$(SUFFIX):MSX\n")
        w("firmware/targets/c/platform.mk", "X := 1\n")
        w("firmware/targets/_template/platform.mk", "MISTER_CORES := _template_menu:menu\n")
        for core in ("menu", "msx", "snes", "n64", "gone"):
            if core != "gone":
                w("firmware/common/mister/cores/%s/core.tcl" % core, "\n")
        w("firmware/common/mister/cores/snes/STATUS.md", HEAD + "| b | timing | Timing | c | d | |\n")
        w("firmware/common/mister/cores/n64/STATUS.md", HEAD + "| b | timing | BLOCKED | | | |\n| b | ooc | FAIL | c | d | |\n")
        w("firmware/common/mister/cores/gone/STATUS.md", HEAD + "| b | timing | Timing | c | d | |\n")
        w("firmware/common/mister/cores/msx/STATUS.md", HEAD + "| c | timing | NOT RUN | | | |\n")
        self.assertEqual(bm.boards_and_cores(root),
                         [("b", "menu"), ("b", "msx"), ("b", "snes"), ("c", "msx")])
        self.assertEqual(bm.boards_and_cores(root, ["c"]), [("c", "msx")])
        self.assertEqual(bm.boards_and_cores(root, (), ["snes"]), [("b", "snes")])
        self.assertEqual(bm.design_name("b", "x", "hdmi"), "b_x_hdmi")
        self.assertEqual(bm.design_name("b", "x", "dvi"), "b_x")


if __name__ == "__main__":
    unittest.main(verbosity=1)
