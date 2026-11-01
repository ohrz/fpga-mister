#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Frame rate of the running core
#  Project    : fpga-mister
#  File       : fps.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-29
# ----------------------------------------------------------------------------------
#  Description: Runs on the board (root): fps.py [<seconds>] (default 10). Polls the
#               headers of the three ascal buffers in the reserved DDR (/dev/mem,
#               0x20000000 + n * RAMSIZE; byte 5 holds the frame counter in bits 7:5) at
#               about 2 kHz. ascal counts every input frame; the counter of the header
#               that changed last is the newest frame, its step since the previous one
#               is the number of frames. RAMSIZE is 8 MB, 2 MB with MISTER_SMALL_VBUF
#               (SNES): 2 MB when the headers there match buffer 0, else 8 MB.
#               15 s give about +-0.07 Hz.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
import mmap, os, sys, time

dur = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)


def header(offset):
    return mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x20000000 + offset)


# a buffer header: type 1, format, header size (bytes 0-3) and image size (6-9) as in buffer 0
b0 = header(0)
small = [header(n * 0x200000) for n in (1, 2)]
if all(b[0:4] == b0[0:4] and b[6:10] == b0[6:10] for b in small):
    size, bufs = 2, [b0] + small
else:
    size, bufs = 8, [b0] + [header(n * 0x800000) for n in (1, 2)]

last = [b[5] >> 5 for b in bufs]
newest = last[0]
frames = 0
t0 = time.time()
while time.time() - t0 < dur:
    for i, b in enumerate(bufs):
        c = b[5] >> 5
        if c != last[i]:
            last[i] = c
            frames += (c - newest) % 8
            newest = c
    time.sleep(0.0005)
t = time.time() - t0
print("frames %d in %.2f s: %.2f Hz (buffers %d MB apart)" % (frames, t, frames / t, size))
