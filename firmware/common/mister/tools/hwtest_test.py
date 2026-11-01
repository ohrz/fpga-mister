#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Tests of hwtest.py (nominal values from the core profiles)
#  Project    : fpga-mister
#  File       : hwtest_test.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-31
# ----------------------------------------------------------------------------------
#  Description: pacer_share against the profiles in cores/ (stage C at 21/22, SNES
#               PAL 227/240, menu without G_PACE_* = 1/1, N64 with G_FREE_CLK) and
#               the perf.py parser on a free-clock report. Run by selfcheck.sh.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
import os, sys, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hwtest  # noqa: E402


class PacerShare(unittest.TestCase):

    def test_stage_c(self):
        self.assertAlmostEqual(hwtest.pacer_share("msx"), 100.0 * 21 / 22)
        self.assertAlmostEqual(hwtest.pacer_share("snes", "main"), 100.0 * 21 / 22)

    def test_snes_pal(self):
        self.assertAlmostEqual(hwtest.pacer_share("snes", "alt"), 100.0 * 227 / 240)

    def test_defaults_and_free_clock(self):
        self.assertEqual(hwtest.pacer_share("menu"), 100.0)
        self.assertEqual(hwtest.pacer_share("n64"), 100.0)

    def test_alt_without_profile_values(self):
        with self.assertRaises(ValueError):
            hwtest.pacer_share("msx", "alt")


class Mgl(unittest.TestCase):

    def test_index(self):
        self.assertIn('index="0" path="a.smc"', hwtest.mgl_text("_Console/SNES", "a.smc"))
        cfg = hwtest.read_cfg(os.path.join(hwtest.CORES, "n64", "hwtest.cfg"))
        m = hwtest.mgl_text("_Console/N64", cfg["game"], cfg.get("index", "0"))
        self.assertIn('<rbf>_Console/N64</rbf>', m)
        self.assertIn('index="1" path="<PAL game>.z64', m)     # N64.sv: "FS1,N64z64n64v64"

    def test_type(self):
        self.assertIn('type="f" index="0"', hwtest.mgl_text("_Console/SNES", "a.smc"))
        cfg = hwtest.read_cfg(os.path.join(hwtest.CORES, "psx", "hwtest.cfg"))
        m = hwtest.mgl_text("_Console/PSX", cfg["game"], cfg.get("index", "0"), cfg.get("type", "f"))
        self.assertIn('type="s" index="1" path="<PAL game>/', m)   # PSX.sv: "S1,CUECHD"
        self.assertTrue(m.rstrip().endswith('.cue"/>\n</mistergamedescription>'))
        with self.assertRaises(ValueError):
            hwtest.mgl_text("_Console/PSX", "a.cue", "1", "x")


class ParsePerf(unittest.TestCase):

    def test_free_clock_report(self):
        out = ("seq 7: window 134217728 cycles (2.68 s at 50.0 MHz, measured)\n"
               "  core edges 100.000 % of the master clock (50.000 MHz), stall 0.000 %, pacer wait 0.000 %, "
               "bucket full 0.000 %\n"
               "  free-running core clock (G_FREE_CLK, stage D): an edge every master cycle, ...\n")
        self.assertEqual(hwtest.parse_perf(out), (100.0, []))


if __name__ == "__main__":
    unittest.main(verbosity=1)
