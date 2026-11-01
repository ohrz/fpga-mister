#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Unit tests of the profile hints of perf.py
#  Project    : fpga-mister
#  File       : perf_test.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-30
# ----------------------------------------------------------------------------------
#  Description: perf.hints() on counter snapshots measured on the Zybo (window 2**27
#               master cycles; percentages measured on the hardware
#               turned back into counts) and on synthetic ones. Runs on the host:
#               python3 perf_test.py
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
import os, sys, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import perf  # noqa: E402

N = 2 ** 27


def snap(edges, stall, pacer, bucket, reads, misses, wfull=0.0, classes=None):
    """Counts of one window from percentages of the cycles; classes = (hi reads, hi misses,
    vict, vict_x, seq) as fractions of reads/misses, None for an 11-count design."""
    c = dict(cycles=N, edges=int(N * edges / 100), stall=int(N * stall / 100), pacer_wait=int(N * pacer / 100),
             bucket_full=int(N * bucket / 100), misses=misses, reads=reads, miss_cycles=misses * 28,
             drain_cycles=misses, wfifo_full=int(N * wfull / 100), writes=0)
    if classes is not None:
        hr, hm, v, vx, sq = classes
        c.update(reads_hi=int(reads * hr), misses_hi=int(misses * hm), miss_vict=int(misses * v),
                 miss_vict_x=int(misses * vx), miss_seq=int(misses * sq))
    return c


class Hints(unittest.TestCase):

    def test_snes_rom_wram_conflict(self):
        # Yoshi's Island title, 16 KB cache without split (HW 2026-10-30)
        h = perf.hints(snap(79.443, 20.441, 0.116, 21.150, 3401401, 931521, classes=(0.197, 0.5, 0.992, 0.987, 0.001)))
        self.assertEqual(len(h), 1)
        self.assertIn("G_CACHE_SPLIT 1", h[0])

    def test_snes_split_full_speed(self):
        # same scene with G_CACHE_SPLIT 1: 95.39 % edges, bucket full 0.105 %
        self.assertEqual(perf.hints(snap(95.388, 1.081, 3.531, 0.105, 7799292, 50701,
                                         classes=(0.228, 0.25, 0.56, 0.0, 0.143))), [])

    def test_msx_bucket_too_small(self):
        # Kings Valley 2 before G_PACE_BUCKET 1024: stall 0.8 %, bucket full 0.33 %, 11 counts
        h = perf.hints(snap(95.12, 0.8, 3.75, 0.33, 6000000, 2400))
        self.assertEqual(len(h), 1)
        self.assertIn("G_PACE_BUCKET", h[0])

    def test_msx_full_speed(self):
        # Kings Valley 2 today: 95.455 % edges, bucket never full
        self.assertEqual(perf.hints(snap(95.455, 0.052, 4.493, 0.0, 6366019, 2408,
                                         classes=(0.0, 0.0, 0.963, 0.0, 0.053))), [])

    def test_col_high_without_classes(self):
        # synthetic case: misses everywhere, 11-count design
        h = perf.hints(snap(85.0, 11.0, 0.5, 11.0, 5000000, 500000))
        self.assertTrue(any("G_CACHE_COL_HIGH" in x for x in h), h)

    def test_col_high_no_pattern(self):
        h = perf.hints(snap(85.0, 11.0, 0.5, 11.0, 5000000, 500000, classes=(0.2, 0.2, 0.1, 0.0, 0.1)))
        self.assertTrue(any("G_CACHE_COL_HIGH" in x for x in h), h)

    def test_conflict_same_half(self):
        h = perf.hints(snap(85.0, 11.0, 0.5, 11.0, 5000000, 500000, classes=(0.2, 0.2, 0.8, 0.1, 0.05)))
        self.assertTrue(any("conflict" in x for x in h), h)

    def test_streaming(self):
        h = perf.hints(snap(85.0, 11.0, 0.5, 11.0, 5000000, 500000, classes=(0.2, 0.2, 0.2, 0.0, 0.7)))
        self.assertTrue(any("prefetch" in x for x in h), h)

    def test_write_fifo_full(self):
        h = perf.hints(snap(85.0, 11.0, 0.5, 11.0, 5000000, 1000, wfull=5.0, classes=(0.2, 0.2, 0.2, 0.0, 0.1)))
        self.assertTrue(any("write FIFO" in x for x in h), h)

    def test_free_clock_no_hint(self):
        # N64 (G_FREE_CLK): an edge every cycle, no stage C traffic
        c = snap(100.0, 0.0, 0.0, 0.0, 0, 0, classes=(0.0, 0.0, 0.0, 0.0, 0.0))
        self.assertTrue(perf.free_clock(c))
        self.assertEqual(perf.hints(c), [])

    def test_gated_clock_is_not_free(self):
        # a stage C core at 1/1 with a short stall is not taken for a free one
        c = snap(99.9, 0.1, 0.0, 0.0, 1000, 10, classes=(0.0, 0.0, 0.0, 0.0, 0.0))
        self.assertFalse(perf.free_clock(c))


if __name__ == "__main__":
    unittest.main(verbosity=1)
