#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Unit tests of status.py
#  Project    : fpga-mister
#  File       : status_test.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-30
# ----------------------------------------------------------------------------------
#  Description: status.load()/matrix() on a throw-away Git repository with one board
#               and one core: valid table, each kind of error, the warning for HW
#               evidence older than a profile change, --update of a marker block.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
import os, subprocess, sys, tempfile, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import status  # noqa: E402

HEAD = "| Board | Stage | Evidence | Commit | Date | Measurement / Remark |\n|---|---|---|---|---|---|\n"
BHEAD = "| Stage | Evidence | Commit | Date | Measurement / Remark |\n|---|---|---|---|---|\n"


class Status(unittest.TestCase):

    def git(self, *a):
        return subprocess.run(["git", "-C", self.root] + list(a), capture_output=True, text=True,
                              check=True).stdout.strip()

    def write(self, rel, text):
        p = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)

    def commit(self, msg):
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", msg)
        return self.git("rev-parse", "--short", "HEAD")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.git("init", "-q")
        self.write("firmware/targets/brd/platform.mk", "\n")
        self.write("firmware/targets/_template/platform.mk", "\n")
        self.write("firmware/common/mister/cores/x/core.tcl", "set a 1\nset core_name X_MiSTer\n")
        self.write("firmware/common/mister/patches/X_MiSTer/0001-a.patch", "Title: a\n+x\n")
        self.c1 = self.commit("one")

    def tearDown(self):
        self.tmp.cleanup()

    def core(self, rows):
        self.write("firmware/common/mister/cores/x/STATUS.md", "# x\n\n" + HEAD + rows)
        return status.load(self.root)

    def test_valid(self):
        cores, boards, errors, warnings = self.core(
            "| brd | timing | Timing | %s | 2026-10-30 | WNS +0.1 ns |\n| brd | saves | NOT RUN | | | |\n"
            "| brd | speed | HW | - | 2026-10-30 | before the history |\n" % self.c1)
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])
        self.assertEqual(cores["x"][("brd", "timing")]["ev"], "Timing")
        m = status.matrix(cores, boards)
        self.assertIn("| x | – | – | Tim | – | – | – | – | HW | – | – |", m)

    def test_errors(self):
        cases = {
            "| nob | timing | Timing | %s | 2026-10-30 | |\n" % self.c1: "unknown board",
            "| brd | timingx | Timing | %s | 2026-10-30 | |\n" % self.c1: "unknown stage",
            "| brd | timing | Synthesis | %s | 2026-10-30 | |\n" % self.c1: "unknown evidence",
            "| brd | timing | Timing | 1234567 | 2026-10-30 | |\n": "not found",
            "| brd | timing | Timing | %s | 30.10.2026 | |\n" % self.c1: "not YYYY-MM-DD",
            ("| brd | timing | Timing | %s | 2026-10-30 | |\n" % self.c1) * 2: "twice",
            "| _template | timing | Timing | %s | 2026-10-30 | |\n" % self.c1: "unknown board",
        }
        for rows, msg in cases.items():
            _, _, errors, _ = self.core(rows)
            self.assertTrue(any(msg in e for e in errors), (rows, msg, errors))

    def test_header(self):
        self.write("firmware/common/mister/cores/x/STATUS.md", "| Stage | Board | Evidence | Commit | Date |\n|---|---|---|---|---|\n")
        _, _, errors, _ = status.load(self.root)
        self.assertTrue(any("table header" in e for e in errors), errors)

    def test_stale_hw(self):
        self.write("firmware/common/mister/cores/x/core.tcl", "set a 2\nset core_name X_MiSTer\n")
        c2 = self.commit("profile change")
        _, _, errors, warnings = self.core("| brd | speed | HW | %s | 2026-10-30 | |\n" % self.c1)
        self.assertEqual(errors, [])
        self.assertTrue(any("older than profile change " + c2 in w for w in warnings), warnings)
        # a STATUS.md/README.md/hwtest.cfg change alone does not age the evidence
        self.commit("status")
        self.write("firmware/common/mister/cores/x/README.md", "x\n")
        self.commit("readme")
        self.write("firmware/common/mister/cores/x/hwtest.cfg", "rbf = x.rbf\n")
        self.commit("hwtest")
        # nor does a check of the OOC synthesis or a comment in the profile
        self.write("firmware/common/mister/cores/x/core.tcl", "set a 2\nset core_name X_MiSTer\n# why\n"
                   "set core_expect_bram 5\n")
        self.commit("expect")
        # nor does the move of its patches from patches/<checkout>/ into the profile
        self.git("mv", "firmware/common/mister/patches/X_MiSTer", "firmware/common/mister/cores/x/patches")
        self.commit("move")
        _, _, _, warnings = self.core("| brd | speed | HW | %s | 2026-10-30 | |\n" % c2)
        self.assertEqual(warnings, [])

    def test_board(self):
        self.write("firmware/targets/brd/STATUS.md", "# b\n\n" + BHEAD +
                   "| boot | HW | %s | 2026-10-30 | ok |\n| bootx | HW | %s | 2026-10-30 | |\n" % (self.c1, self.c1))
        _, boards, errors, _ = status.load(self.root)
        self.assertEqual(boards["brd"]["boot"]["ev"], "HW")
        self.assertTrue(any("unknown stage 'bootx'" in e for e in errors), errors)

    def test_update(self):
        cores, boards, errors, _ = self.core("| brd | timing | Timing | %s | 2026-10-30 | |\n" % self.c1)
        p = os.path.join(self.root, "R.md")
        with open(p, "w") as f:
            f.write("a\n%s\nold\n%s\nb\n" % (status.BEGIN, status.END))
        cwd = os.getcwd()
        os.chdir(self.root)
        try:
            self.assertEqual(status.main(["--update", p]), 0)
        finally:
            os.chdir(cwd)
        s = open(p).read()
        self.assertNotIn("old", s)
        self.assertTrue(s.startswith("a\n" + status.BEGIN) and s.endswith(status.END + "\nb\n"))
        self.assertIn("| x |", s)


if __name__ == "__main__":
    unittest.main(verbosity=1)
