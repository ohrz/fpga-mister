#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Game speed of the N64 core (Super Mario 64 E)
#  Project    : fpga-mister
#  File       : n64speed.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-30
# ----------------------------------------------------------------------------------
#  Description: Runs on the board (root) while SM64 E runs: n64speed.py [<seconds>]
#               (default 20). Reads two big-endian counters of the game in the RDRAM
#               (DDRAM at 0x3000_0000 + RDRAM address, /dev/mem) at the start and the
#               end: the VI counter at 0x802F9730 (one per VI interrupt, 50/s with the
#               PAL video clock, independent of the core clocks) and the game frame
#               counter at 0x802F9784 (one per game frame; found by scanning for
#               steady counters). SM64 PAL targets one game frame every two
#               VI interrupts (25/s); speed = game frames / (VI interrupts / 2). The
#               game waits for a VI interrupt after each frame, so the value is
#               quantized per frame (2, 3, 4 ... VIs) and depends on the scene: a
#               measure of the game as played, not of the clock ratio. Light scenes
#               (title screen) reach 100 % at full speed on the original.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
import mmap, os, struct, sys, time

VI_COUNT = 0x802F9730
GAME_FRAMES = 0x802F9784
VI_PER_FRAME = 2                     # SM64 PAL: 25 game frames per 50 VI interrupts

dur = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
ram = mmap.mmap(fd, 0x800000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x30000000)


def read(addr):
    off = addr & 0x7FFFFF
    return struct.unpack(">I", ram[off:off + 4])[0]


t0, vi0, gf0 = time.monotonic(), read(VI_COUNT), read(GAME_FRAMES)
time.sleep(dur)
t1, vi1, gf1 = time.monotonic(), read(VI_COUNT), read(GAME_FRAMES)
dt, dvi, dgf = t1 - t0, (vi1 - vi0) & 0xFFFFFFFF, (gf1 - gf0) & 0xFFFFFFFF
if dvi == 0:
    sys.exit("VI counter does not move: SM64 E not running?")
print("%.1f s: VI %.2f/s, game frames %.2f/s, %.2f VI per frame, speed %.1f %%"
      % (dt, dvi / dt, dgf / dt, dvi / max(dgf, 1), 100.0 * dgf * VI_PER_FRAME / dvi))
