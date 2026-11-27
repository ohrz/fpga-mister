#!/usr/bin/env python3
# File: soak.py, Author: Konstantin Schmidt (mr_pleasant@gmx.de), Company: OHRZ, Created: 2026-11-26
# soak.py <bit.bin> <rounds> <seconds>: per round load the PL, start Main, check every second:
# ID, STATUS, core edges, stage C reads, ascal writes (HP2), Main alive. Log to /home/fpga/soak.log.
import mmap, os, struct, time, subprocess, sys, shutil, glob
LOG = open("/home/fpga/soak.log", "a", buffering=1)
def log(s): LOG.write(time.strftime("%H:%M:%S ") + s + "\n")
f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
def rd(a):
    m = mmap.mmap(f, 0x1000, offset=a & ~0xFFF); v = struct.unpack("<I", m[a & 0xFFF:(a & 0xFFF) + 4])[0]; m.close(); return v
def clr(p):
    m = mmap.mmap(f, 0x1000, offset=p); m[:] = b"\0" * 0x1000; m.close()
def nz(p):
    m = mmap.mmap(f, 0x1000, offset=p); d = m[:]; m.close(); return sum(1 for i in range(0, 0x1000, 4) if d[i:i+4] != b"\0\0\0\0")
def temp():
    t = 0
    for g in glob.glob("/sys/class/hwmon/hwmon*/temp*_input"):
        try: t = max(t, int(open(g).read()))
        except Exception: pass
    return t / 1000.0
def active(u): return subprocess.run(["systemctl", "is-active", "--quiet", u]).returncode == 0
bit, rounds, secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
FULL = 134217728
tot = dict(samples=0, bad_id=0, bad_status=0, low_edges=0, reads=0, max_miss=0, ascal_dead=0, main_dead=0)
log("start %s rounds %d x %d s" % (bit, rounds, secs))
for r in range(rounds):
    subprocess.run(["systemctl", "stop", "mister.service", "mister-soak"], stderr=subprocess.DEVNULL); time.sleep(1)
    shutil.copy(bit, "/lib/firmware/kr260_test.bit.bin")
    open("/sys/class/fpga_manager/fpga0/flags", "w").write("0\n")
    open("/sys/class/fpga_manager/fpga0/firmware", "w").write("kr260_test.bit.bin\n")
    time.sleep(2)
    log("round %d load: state %s ID 0x%08x GPI 0x%08x STATUS 0x%x board_status 0x%x" % (r + 1,
        open("/sys/class/fpga_manager/fpga0/state").read().strip(), rd(0xA0000008), rd(0xA0000004), rd(0xA000000C), rd(0xA0000054)))
    subprocess.run(["systemctl", "start", "usr-lib-firmware-mister.mount"], stderr=subprocess.DEVNULL)
    subprocess.run(["systemd-run", "--unit=mister-soak", "--working-directory=/media/fat", "-p", "ExitType=cgroup",
                    "-p", "StandardOutput=file:/tmp/mister-soak.log", "-p", "StandardError=file:/tmp/mister-soak.log",
                    "stdbuf", "-o0", "-e0", "/media/fat/MiSTer"], stdout=subprocess.DEVNULL)
    time.sleep(5)
    rr = dict(bad_id=0, bad_status=0, low_edges=0, reads=0, max_miss=0, ascal_dead=0, main_dead=0)
    for t in range(secs):
        if t % 10 == 0: clr(0x20000000)
        time.sleep(1)
        idv, st = rd(0xA0000008), rd(0xA000000C)
        a = [rd(0xA0000010 + 4 * i) for i in range(9)]
        tot["samples"] += 1
        bad = []
        if idv != 0x5A4D5354: rr["bad_id"] += 1; bad.append("ID 0x%08x" % idv)
        if st != 0: rr["bad_status"] += 1; bad.append("STATUS 0x%x" % st)
        if a[2] < FULL * 99 // 100: rr["low_edges"] += 1; bad.append("edges %d" % a[2])
        rr["reads"] += a[7]; rr["max_miss"] = max(rr["max_miss"], a[8])
        if t % 10 == 9 and nz(0x20000000) == 0: rr["ascal_dead"] += 1; bad.append("ascal page empty")
        if not active("mister-soak"): rr["main_dead"] += 1; bad.append("Main not active")
        if bad: log("round %d %4d s: %s" % (r + 1, t + 1, ", ".join(bad)))
        if t % 60 == 59:
            log("round %d %4d s: %.1f C, STATUS 0x%x, edges %d, reads %d, miss_cycles %d" % (r + 1, t + 1, temp(), st, a[2], a[7], a[8]))
    for k in rr:
        tot[k] = max(tot[k], rr[k]) if k == "max_miss" else tot[k] + rr[k]
    log("round %d end: %s" % (r + 1, rr))
log("TOTAL %s" % tot)
d = subprocess.run(["dmesg", "--level=err,warn"], capture_output=True, text=True).stdout.splitlines()
log("dmesg err/warn lines: %d, last: %s" % (len(d), d[-3:] if d else []))
log("Main log tail: %s" % open("/tmp/mister-soak.log", errors="replace").read()[-400:].replace("\n", " | "))
log("RESULT %s" % ("PASS" if tot["bad_id"] + tot["bad_status"] + tot["low_edges"] + tot["ascal_dead"] + tot["main_dead"] == 0 else "FAIL"))
