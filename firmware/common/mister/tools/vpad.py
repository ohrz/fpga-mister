#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Virtual gamepad for Main_MiSTer
#  Project    : fpga-mister
#  File       : vpad.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-30
# ----------------------------------------------------------------------------------
#  Description: Runs on the board (root): creates a gamepad over /dev/uinput, waits
#               until Main_MiSTer has opened it, plays a sequence, removes it again.
#               Main has no mapping for it and uses its default (def_mmap: BTN_SOUTH =
#               B, BTN_EAST = A, BTN_NORTH = X, BTN_WEST = Y, TL/TR, SELECT, START,
#               d-pad as BTN_DPAD_*), so console cores get a joystick without a person
#               at the board; the keyboard joystick emulation has no default keys.
#                 vpad.py START 3 START A 1.5 RIGHT:2
#               NAME taps a button (0.15 s), NAME:S holds it S seconds, a number waits.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
import fcntl, os, struct, sys, time

UI_SET_EVBIT, UI_SET_KEYBIT, UI_DEV_CREATE, UI_DEV_DESTROY = 0x40045564, 0x40045565, 0x5501, 0x5502
EV_SYN, EV_KEY = 0, 1
BTN = dict(B=0x130, A=0x131, X=0x133, Y=0x134, L=0x136, R=0x137, SELECT=0x13A, START=0x13B, MODE=0x13C,
           UP=0x220, DOWN=0x221, LEFT=0x222, RIGHT=0x223)


def ev(fd, t, c, v):
    os.write(fd, struct.pack("llHHi", 0, 0, t, c, v))


def hold(fd, code, seconds):
    ev(fd, EV_KEY, code, 1); ev(fd, EV_SYN, 0, 0)
    time.sleep(seconds)
    ev(fd, EV_KEY, code, 0); ev(fd, EV_SYN, 0, 0)


steps = sys.argv[1:]
for s in steps:                                   # check the whole sequence before creating the pad
    name = s.split(":")[0]
    if name not in BTN and not name.replace(".", "", 1).isdigit():
        sys.exit(f"vpad: unknown step {s} (buttons: {' '.join(BTN)})")

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
for c in BTN.values():
    fcntl.ioctl(fd, UI_SET_KEYBIT, c)
dev = struct.pack("80sHHHHi", b"mister-vpad", 3, 0x1209, 0x0002, 1, 0) + b"\0" * (4 * 64 * 4)
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(2.0)                                   # Main notices the new device (inotify) and opens it
for s in steps:
    name, _, sec = s.partition(":")
    if name in BTN:
        hold(fd, BTN[name], float(sec) if sec else 0.15)
        time.sleep(0.2)
    else:
        time.sleep(float(name))
time.sleep(0.5)
fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
print("vpad:", " ".join(steps))
