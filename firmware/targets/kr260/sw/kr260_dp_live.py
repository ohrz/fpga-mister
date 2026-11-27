#!/usr/bin/env python3
#-----------------------------------------------------------------------------
# File       : kr260_dp_live.py
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-26
# Platform   : KR260 (Kria K26 SOM, Zynq UltraScale+ XCK26)
#-----------------------------------------------------------------------------
# Description:
# Switches the video layer of the PS DisplayPort (DPSUB) to the live input of
# the PL (kr260_dp_live, 1280x720@60 RGB 8 bpc from ascal) and back. "on" also
# switches the audio to the live audio input of the PL (kr260_dp_audio, 48 kHz,
# 2 channels, audio clock = dp_s_axis_audio_clk = clk_audio).
# Precondition: zynqmp-dpsub trained the link in the non-live mode with the
# same timing (kernel argument video=DP-1:1280x720@60e). The tool writes only
# the AV buffer manager and the blender, as the live mode of the driver does
# (drivers/gpu/drm/xlnx/zynqmp_disp.c of linux-xlnx 6.12).
#   kr260_dp_live.py status   print the registers and the counters of kr260_dp_audio
#   kr260_dp_live.py on       video layer = live input, graphics layer off, live audio
#                             (only if fb0 has 1280x720, else exit code 1 and no change)
#   kr260_dp_live.py off      video layer off, graphics layer from memory, audio off
#   kr260_dp_live.py audio    only the audio part of "on" (registers and mixer reset)
#   kr260_dp_live.py reset    only a reset of the audio mixer (see below)
#   kr260_dp_live.py tone on|off   1 kHz test tone of kr260_dp_audio (CTRL bit 3)
# The driver enables the audio only while an ALSA stream is open. Thus the tool
# writes the audio registers itself, after the relink (the modeset rewrites them).
# The live audio also needs the PS audio clock (dp_audio_ref, CLKACT in
# DP_AUDIO_REF_CTRL), although CLK_SRC selects the PL clock: without it the
# transmitter sends only zeros. The driver enables this clock only while an
# PCM is prepared. Thus "on" starts a background process that opens and
# prepares the PCM but does not start it (PID file /run/kr260_dp_audio_keep.pid),
# and "off" stops it. A PCM that plays (also silence) makes the picture stop for
# a moment about each second (user 2026-11-27): do not play through it.
# After each stop of the audio of the transmitter ("on", "audio"), a receiver can
# need a mixer reset ("reset") to get a clean stream again.
# Run as root (/dev/mem).
# After each change of the clock and timing source, the tool switches the main
# stream of the DP transmitter off and on. Without it, the transmitter keeps the
# frame position of the old source: the picture moves by a random number of
# lines and pixels, and the vertical blanking of the PL shows as a flat band.
# "on" first blanks and unblanks fb0. The driver then trains the link again. A
# restart of the sink can drop the link without a message, and the
# picture stays black until the next modeset.
#-----------------------------------------------------------------------------
import mmap, os, struct, sys, time

DP = 0xFD4A0000                     # DP transmitter
BLEND = 0xFD4AA000                  # V_BLEND
AVBUF = 0xFD4AB000                  # AV_BUF
AUD = 0xFD4AC000                    # audio mixer of the DPSUB
HPS = 0xA0000000                    # hps_bus_axi of mister_zynq (HPM0_FPD)

# AV_BUF registers (zynqmp_disp_regs.h)
OUTPUT = 0x070                      # [1:0] VID1 0 live 1 mem 2 pattern 3 none, [3:2] VID2 0 off 1 mem 2 live 3 none
CLK_SRC = 0x120                     # bit0 video clock from PS, bit1 audio clock from PS, bit2 internal timing
SRST = 0x124                        # bit1 video reset
VID_COMP_SF = 0x20C                 # 3 words
LIVE_VID_CONFIG = 0x224             # [2:0] bpc (1 = 8), [5:4] format (0 = RGB)
SF_8BIT = 0x10101
# AV_BUF OUTPUT audio fields: [5:4] AUD1 0 live (PL) 1 mem 2 pattern 3 off, bit 6 AUD2 (memory) on
AUD_MASK = 0x70
# audio mixer registers (zynqmp_disp_regs.h)
AUD_MIXER_VOLUME = 0x000            # 0x2000 = gain 1 for each channel
AUD_CH_STATUS0 = 0x008              # 6 words, IEC 60958 channel status
AUD_SOFT_RESET = 0xC00              # bit0
# DP transmitter registers
MAIN_STREAM_ENABLE = 0x084          # bit0
INTR_STATUS = 0x3A0                 # bit 12: live audio input does not match the audio sample rate
TX_AUDIO_CONTROL = 0x300            # bit0 enable
TX_AUDIO_CHANNELS = 0x304           # channels - 1
# hps_bus_axi registers
HPS_CTRL = 0x00C                    # write: CTRL (bit 0 quiesce, bits 7:3 board_ctrl)
HPS_BOARD_STATUS = 0x054            # aux word 17: bits 31:16 audio frames, 15:9 dropped frames
# blender registers
GLOBAL_ALPHA = 0x00C
LAYER_CONTROL0 = 0x018              # video layer: bit1 RGB, bit0 upsampling
IN1CSC_COEFF = 0x044                # 9 words, video layer
IN1CSC_OFFSET = 0x068               # 3 words

fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
regs = {b: mmap.mmap(fd, 0x1000, offset=b) for b in (DP, BLEND, AVBUF, AUD, HPS)}


def rd(base, off):
    return struct.unpack("<I", regs[base][off:off + 4])[0]


def wr(base, off, val):
    regs[base][off:off + 4] = struct.pack("<I", val)


def status():
    out = rd(AVBUF, OUTPUT)
    print("AV_BUF OUTPUT 0x%08x (VID1 %d, VID2 %d)" % (out, out & 3, (out >> 2) & 3))
    print("AV_BUF CLK_SRC 0x%08x  LIVE_VID_CONFIG 0x%08x  VID_COMP_SF %s" % (
        rd(AVBUF, CLK_SRC), rd(AVBUF, LIVE_VID_CONFIG),
        " ".join("0x%05x" % rd(AVBUF, VID_COMP_SF + 4 * i) for i in range(3))))
    print("BLEND LAYER_CONTROL0 0x%08x  GLOBAL_ALPHA 0x%08x  IN1CSC %s" % (
        rd(BLEND, LAYER_CONTROL0), rd(BLEND, GLOBAL_ALPHA),
        " ".join("%x" % rd(BLEND, IN1CSC_COEFF + 4 * i) for i in range(9))))
    bs0 = rd(HPS, HPS_BOARD_STATUS)
    time.sleep(1)
    bs1 = rd(HPS, HPS_BOARD_STATUS)                     # the counters cross clocks: values can jump once
    print("AUDIO AUD1 %d AUD2 %d  CLK_SRC audio from %s  TX_AUDIO_CONTROL %d  CHANNELS %d  VOLUME 0x%08x  "
          "underflow %d" % ((out >> 4) & 3, (out >> 6) & 1, "PS" if rd(AVBUF, CLK_SRC) & 2 else "PL",
                            rd(DP, TX_AUDIO_CONTROL), rd(DP, TX_AUDIO_CHANNELS) + 1, rd(AUD, AUD_MIXER_VOLUME),
                            (rd(DP, INTR_STATUS) >> 12) & 1))
    print("kr260_dp_audio frames %d -> %d in 1 s (48000 expected, modulo 65536), dropped %d" % (
        bs0 >> 16, bs1 >> 16, (bs1 >> 9) & 0x7F))


def restart_stream():
    # The transmitter aligns its frame to the new source only at a stream start.
    wr(DP, MAIN_STREAM_ENABLE, 0)
    time.sleep(0.05)
    wr(DP, MAIN_STREAM_ENABLE, 1)


def relink():
    # DPMS off and on through fbdev: the driver does a full modeset and link training.
    for v in ("1", "0"):
        with open("/sys/class/graphics/fb0/blank", "w") as b:
            b.write(v)
        time.sleep(0.5)


def mode_ok():
    # the live input has the fixed timing 1280x720@60, the mode of Linux must be the same
    try:
        size = open("/sys/class/graphics/fb0/virtual_size").read().strip()
    except OSError:
        size = "no fb0"
    if size != "1280,720":
        print("kr260_dp_live: the DP mode is %s, not 1280,720 (kernel argument video=DP-1:1280x720@60e). "
              "No change." % size)
        return False
    return True


def live_on():
    relink()
    wr(AVBUF, LIVE_VID_CONFIG, 0x1)                     # RGB, 8 bpc
    for i in range(3):
        wr(AVBUF, VID_COMP_SF + 4 * i, SF_8BIT)
    wr(BLEND, LAYER_CONTROL0, 0x2)                      # RGB, no upsampling
    # The graphics layer is over the video layer. With VID2 none it is black, so
    # the global alpha must be 0 (bit 0 enable, bits 8:1 alpha), else the picture is black.
    wr(BLEND, GLOBAL_ALPHA, 0x1)
    for i, c in enumerate((0x1000, 0, 0, 0, 0x1000, 0, 0, 0, 0x1000)):
        wr(BLEND, IN1CSC_COEFF + 4 * i, c)
    for i in range(3):
        wr(BLEND, IN1CSC_OFFSET + 4 * i, 0)
    # video clock and timing from the PL, the audio clock stays as it is
    wr(AVBUF, CLK_SRC, rd(AVBUF, CLK_SRC) & 0x2)
    out = rd(AVBUF, OUTPUT) & ~0xF
    wr(AVBUF, OUTPUT, out | 0x0 | (3 << 2))             # VID1 live, VID2 none
    wr(AVBUF, SRST, 0x2)                                # reset the video path once
    wr(AVBUF, SRST, 0x0)
    restart_stream()
    keep_start()
    audio_on()


def audio_on():
    # live audio of the PL: AUD1 = PL, AUD2 off, audio clock from the PL, 2 channels, 48 kHz status
    wr(DP, TX_AUDIO_CONTROL, 0)
    wr(AVBUF, OUTPUT, (rd(AVBUF, OUTPUT) & ~AUD_MASK) | (0 << 4))
    wr(AVBUF, CLK_SRC, rd(AVBUF, CLK_SRC) & ~0x2)
    wr(AUD, AUD_MIXER_VOLUME, 0x20002000)
    for i in range(6):
        wr(AUD, AUD_CH_STATUS0 + 4 * i, 0x02000000 if i == 0 else 0)   # byte 3 = 0x02: 48 kHz
    wr(AUD, AUD_SOFT_RESET, 1)
    wr(AUD, AUD_SOFT_RESET, 0)
    wr(DP, TX_AUDIO_CHANNELS, 1)
    wr(DP, TX_AUDIO_CONTROL, 1)


def audio_off():
    # back to the state of the driver: audio from memory, audio clock from the PS, transmitter off
    wr(DP, TX_AUDIO_CONTROL, 0)
    wr(AVBUF, OUTPUT, (rd(AVBUF, OUTPUT) & ~AUD_MASK) | (1 << 4) | 0x40)
    wr(AVBUF, CLK_SRC, rd(AVBUF, CLK_SRC) | 0x2)


KEEP_PID = "/run/kr260_dp_audio_keep.pid"


def keep_running():
    try:
        pid = int(open(KEEP_PID).read())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return 0


def keep_start():
    # a prepared PCM keeps dp_audio_ref on (libasound through ctypes, the RootFS has no alsa-utils)
    if keep_running():
        return
    pid = os.fork()
    if pid:
        with open(KEEP_PID, "w") as p:
            p.write("%d\n" % pid)
        time.sleep(1.0)                                 # the driver sets up its audio path
        return
    os.setsid()
    null = os.open(os.devnull, os.O_RDWR)              # free the pipes of the caller
    for fd in (0, 1, 2):
        os.dup2(null, fd)
    import ctypes
    a = ctypes.CDLL("libasound.so.2")
    pcm = ctypes.c_void_p()
    if a.snd_pcm_open(ctypes.byref(pcm), b"hw:0,0", 0, 0) < 0 or \
            a.snd_pcm_set_params(pcm, 2, 3, 2, 48000, 1, 200000) < 0 or \
            a.snd_pcm_prepare(pcm) < 0:                 # S16_LE, interleaved, 2 ch, 48 kHz
        os._exit(1)
    while True:
        time.sleep(3600)


def keep_stop():
    pid = keep_running()
    if pid:
        os.kill(pid, 15)
    if os.path.exists(KEEP_PID):
        os.remove(KEEP_PID)


def live_off():
    audio_off()
    keep_stop()
    out = rd(AVBUF, OUTPUT) & ~0xF
    wr(AVBUF, OUTPUT, out | 0x3 | (1 << 2))             # VID1 none, VID2 memory
    wr(BLEND, GLOBAL_ALPHA, 0x1FF)                      # graphics layer opaque, as the driver sets it
    wr(AVBUF, CLK_SRC, rd(AVBUF, CLK_SRC) | 0x5)        # PS clock, internal timing
    wr(AVBUF, SRST, 0x2)
    wr(AVBUF, SRST, 0x0)
    restart_stream()


cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
if cmd == "on":
    if not mode_ok():
        sys.exit(1)
    live_on()
elif cmd == "off":
    live_off()
elif cmd == "audio":
    audio_on()
elif cmd == "reset":
    wr(AUD, AUD_SOFT_RESET, 1)
    wr(AUD, AUD_SOFT_RESET, 0)
elif cmd == "tone" and len(sys.argv) > 2 and sys.argv[2] in ("on", "off"):
    wr(HPS, HPS_CTRL, 0x08 if sys.argv[2] == "on" else 0x00)   # bit 0 (quiesce) stays 0
elif cmd != "status":
    sys.exit("usage: kr260_dp_live.py status|on|off|audio|reset|tone on|off")
status()
