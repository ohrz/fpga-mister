#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Virtual keyboard for Main_MiSTer
#  Project    : fpga-mister
#  File       : vkbd.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-28
# ----------------------------------------------------------------------------------
#  Description: Runs on the board (root): creates a USB keyboard over /dev/uinput (no
#               extra modules), waits until Main_MiSTer has opened it, sends keys, removes
#               it again. Core resets without a person at the board:
#                 vkbd.py reset       LCtrl+LAlt+RAlt  (user_io kbd_reset, warm reset)
#                 vkbd.py coldreset   LCtrl+LShift+LAlt+RAlt
#                 vkbd.py keys F12 DOWN ENTER ...   (names in KEY)
#                 vkbd.py text 'romload game.rom /r\n'  (US layout: letters, digits,
#                                     space, . , / - = ; and \n for Enter)
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
import fcntl, os, struct, sys, time

UI_SET_EVBIT, UI_SET_KEYBIT, UI_DEV_CREATE, UI_DEV_DESTROY = 0x40045564, 0x40045565, 0x5501, 0x5502
EV_SYN, EV_KEY = 0, 1
KEY = dict(ESC=1, ENTER=28, LEFTCTRL=29, LEFTSHIFT=42, LEFTALT=56, SPACE=57, F12=88, RIGHTALT=100,
           UP=103, LEFT=105, RIGHT=106, DOWN=108)
# characters of "text" on the US layout: Linux key code (upper case: with left shift)
CHAR = {c: 2 + i for i, c in enumerate("1234567890-=")}
CHAR.update({c: 16 + i for i, c in enumerate("qwertyuiop")})
CHAR.update({c: 30 + i for i, c in enumerate("asdfghjkl;")})
CHAR.update({c: 44 + i for i, c in enumerate("zxcvbnm,./")})
CHAR.update({" ": KEY["SPACE"], "\n": KEY["ENTER"]})


def text_codes(s):
    """key code lists of the characters of s (\\n in the argument = Enter)."""
    out = []
    for c in s.replace("\\n", "\n"):
        if c.lower() not in CHAR:
            sys.exit("vkbd: character %r not on the US layout of vkbd.py" % c)
        code = CHAR[c.lower()]
        out.append([KEY["LEFTSHIFT"], code] if c.isupper() else [code])
    return out


def ev(fd, t, c, v):
    os.write(fd, struct.pack("llHHi", 0, 0, t, c, v))

def press(fd, codes, hold=0.15):
    for c in codes:
        ev(fd, EV_KEY, c, 1); ev(fd, EV_SYN, 0, 0); time.sleep(0.02)
    time.sleep(hold)
    for c in reversed(codes):
        ev(fd, EV_KEY, c, 0); ev(fd, EV_SYN, 0, 0); time.sleep(0.02)

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
for k in range(1, 256):
    fcntl.ioctl(fd, UI_SET_KEYBIT, k)
dev = struct.pack("80sHHHHi", b"mister-vkbd", 3, 0x1209, 0x0001, 1, 0) + b"\0" * (4 * 64 * 4)
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(2.0)                                   # Main notices the new device (inotify) and opens it
cmd = sys.argv[1] if len(sys.argv) > 1 else "reset"
if cmd == "reset":
    press(fd, [KEY["LEFTCTRL"], KEY["LEFTALT"], KEY["RIGHTALT"]])
elif cmd == "coldreset":
    press(fd, [KEY["LEFTCTRL"], KEY["LEFTSHIFT"], KEY["LEFTALT"], KEY["RIGHTALT"]])
elif cmd == "keys":
    for name in sys.argv[2:]:
        press(fd, [KEY[name]]); time.sleep(0.3)
elif cmd == "text":
    for codes in text_codes(" ".join(sys.argv[2:])):
        press(fd, codes, hold=0.05); time.sleep(0.08)
time.sleep(0.5)
fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
print("vkbd:", " ".join(sys.argv[1:]) or "reset")
