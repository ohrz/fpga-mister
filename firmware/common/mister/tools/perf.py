#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Stage C event counters of the running core
#  Project    : fpga-mister
#  File       : perf.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-29
# ----------------------------------------------------------------------------------
#  Description: Runs on the board (root): perf.py [<windows>] (default 1). Reads the
#               snapshot of perf_counters in mister_zynq (aux words of hps_bus_axi at
#               0x40000010: seq and 11 or 16 counts over a window of master cycles)
#               once per window and prints what the core lost and why. "hits" counts
#               every read once (a miss after its line fetch), so the miss rate is
#               misses / reads. Designs since the miss classes have 16 counts (reads
#               and misses in the upper half of the SDRAM image, misses on the line
#               the last fetch replaced, of them replaced from the other half, misses
#               on the line after the previous miss). Older designs decode 6 address
#               bits, 0x40.. mirror 0x00.. there: ID at 0x48 means 11 counts.
#               Only for designs with the counters: in older designs 0x10.. mirror
#               GPO/GPI/ID/STATUS.
#               GP0 is only touched when fpga_manager reports a configured PL and the
#               ID register answers (an access to an unconfigured PL hangs the bus).
#               Each window ends with hints for the core profile (hints(), rules of
#               measurements on the hardware; tested in perf_test.py).
#               The master clock rate is measured from the time between two window
#               ends (the window is a fixed number of master cycles; MSX/SNES 90 MHz,
#               menu 85, N64 50): perf.py waits for one extra window.  A core on a
#               free-running clock (G_FREE_CLK, stage D: an edge every cycle, no stage C
#               reads) gets no hints: its counters say nothing about its speed.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
import mmap, os, sys, time

NAMES = ["cycles", "edges", "stall", "pacer_wait", "bucket_full", "misses", "reads",
         "miss_cycles", "drain_cycles", "wfifo_full", "writes",
         "reads_hi", "misses_hi", "miss_vict", "miss_vict_x", "miss_seq"]


def hints(c):
    """Profile hints from one snapshot (dict of NAMES); a list of strings, empty when the
    core loses no edges.  Lost edges = cycles with a full token bucket: the core is behind
    the pacer and cannot catch up."""
    n = c["cycles"] or 1
    if free_clock(c):
        return []
    lost = c["bucket_full"] / n
    if lost < 0.002:                                 # < 0.2 %: the core keeps its rate
        return []
    out = []
    stall = c["stall"] / n
    reads, misses = c["reads"] or 1, c["misses"]
    rate = misses / reads
    if stall < 0.01:
        # runs of misses stall longer than the bucket saves, although the mean is small
        out.append("edges lost at a small stall (%.2f %%): G_PACE_BUCKET larger" % (100 * stall))
        return out
    if c["wfifo_full"] / n > 0.001:
        out.append("write FIFO full %.2f %% of the cycles: writes outrun HP0" % (100 * c["wfifo_full"] / n))
    if "miss_seq" in c and misses:
        vict, vict_x, seq = c["miss_vict"] / misses, c["miss_vict_x"] / misses, c["miss_seq"] / misses
        if vict_x > 0.5:
            out.append("%.0f %% of the misses on lines replaced from the other address half: "
                       "G_CACHE_SPLIT 1" % (100 * vict_x))
        elif vict > 0.5:
            out.append("%.0f %% of the misses on the line the last fetch replaced: conflict misses, "
                       "more G_CACHE_INDEX_BITS or a second way" % (100 * vict))
        elif seq > 0.5:
            out.append("%.0f %% of the misses on the next line: streaming, a prefetch of the next "
                       "line would help (not implemented)" % (100 * seq))
        elif rate > 0.04:
            out.append("%.1f %% misses without a pattern: check G_CACHE_COL_HIGH (a cache line must "
                       "hold neighbouring words of the core), then the cache size" % (100 * rate))
    elif rate > 0.04:
        out.append("%.1f %% misses (design without miss classes): check G_CACHE_COL_HIGH and "
                   "the cache size" % (100 * rate))
    if not out:
        out.append("edges lost (%.2f %%) at %.2f %% stall and %.2f %% misses: no rule matches"
                   % (100 * lost, 100 * stall, 100 * rate))
    return out


def free_clock(c):
    """A core on the free master clock (G_FREE_CLK): an edge every cycle and no stage C reads."""
    return c["edges"] == c["cycles"] and c["reads"] == 0 and c["stall"] == 0


def report(seq, c, master_hz):
    n = c["cycles"] or 1
    t = n / master_hz
    pct = lambda k: 100.0 * c[k] / n
    print("seq %d: window %d cycles (%.2f s at %.1f MHz, measured)" % (seq, n, t, master_hz / 1e6))
    print("  core edges %.3f %% of the master clock (%.3f MHz), stall %.3f %%, pacer wait %.3f %%, "
          "bucket full %.3f %%" % (pct("edges"), c["edges"] / t / 1e6, pct("stall"), pct("pacer_wait"),
                                   pct("bucket_full")))
    if free_clock(c):
        print("  free-running core clock (G_FREE_CLK, stage D): an edge every master cycle, "
              "no stage C reads; the core's own memory waits are not counted here")
        return
    m = c["misses"] or 1
    r = c["reads"] or 1
    print("  reads: %d, misses %d (%.2f %%), %.1f cycles per miss, of them %.1f draining the write FIFO"
          % (c["reads"], c["misses"], 100.0 * c["misses"] / r, c["miss_cycles"] / m, c["drain_cycles"] / m))
    if "miss_seq" in c:
        lo_r, lo_m = c["reads"] - c["reads_hi"], c["misses"] - c["misses_hi"]
        print("  lower half: %d reads, %.2f %% misses; upper half: %d reads, %.2f %% misses"
              % (lo_r, 100.0 * lo_m / max(1, lo_r), c["reads_hi"], 100.0 * c["misses_hi"] / max(1, c["reads_hi"])))
        print("  misses on the replaced line %.1f %% (replaced from the other half %.1f %%), "
              "on the next line %.1f %%" % (100.0 * c["miss_vict"] / m, 100.0 * c["miss_vict_x"] / m,
                                            100.0 * c["miss_seq"] / m))
    print("  writes: %d (%.0f per s), write FIFO full %.3f %%" % (c["writes"], c["writes"] / t, pct("wfifo_full")))
    for h in hints(c):
        print("  hint: " + h)


def main():
    global NAMES
    if open("/sys/class/fpga_manager/fpga0/state").read().strip() != "operating":
        sys.exit("perf.py: PL not configured")
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    mem = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x40000000)
    reg = memoryview(mem).cast("I")                 # 32-bit loads
    if reg[2] != 0x5A4D5354:
        sys.exit("perf.py: no hps_bus_axi at 0x40000000")
    if reg[18] == 0x5A4D5354:                       # 0x48 mirrors ID: 6 address bits, 11 counts
        NAMES = NAMES[:11]

    def snapshot():
        while True:
            seq = reg[4]
            c = [reg[5 + i] for i in range(len(NAMES))]
            if reg[4] == seq:
                return seq, dict(zip(NAMES, c))
            time.sleep(0.01)

    def next_window(last):
        """The next snapshot after seq last and the time it appeared (polled every 10 ms)."""
        while True:
            seq, c = snapshot()
            if seq != last:
                return seq, c, time.monotonic()
            time.sleep(0.01)

    windows = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    last, _, t_last = next_window(snapshot()[0])     # a window end to time the next one from
    for _ in range(windows):
        seq, c, t = next_window(last)
        report(seq, c, c["cycles"] * (seq - last) / (t - t_last))
        last, t_last = seq, t


if __name__ == "__main__":
    main()
