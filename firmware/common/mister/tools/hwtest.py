#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Hardware test of a core on the board
#  Project    : fpga-mister
#  File       : hwtest.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-30
# ----------------------------------------------------------------------------------
#  Description: Runs on the host: hwtest.py <core> [--board <ip>] [--platform <p>] [--commit <c>]
#               (make hwtest CORE=<core> [PLATFORM=<p>], board address from lab.mk)
#               Loads the core with a game as described in
#               firmware/common/mister/cores/<core>/hwtest.cfg, plays its input
#               sequence and checks against nominal values:
#                 load     PL configured, hps_bus_axi answers (perf.py runs)
#                 speed    frame rate (fps.py) within fps_tol % of fps, core edges
#                          (perf.py) at least the pacer share G_PACE_NUM/G_PACE_DEN of
#                          the profile (pacer = alt: G_PACE_NUM_ALT/G_PACE_DEN_ALT; no
#                          G_PACE_* or G_FREE_CLK 1: 100 %) minus 0.1 points, no perf.py
#                          hint
#               and prints PASS/FAIL per check plus STATUS.md rows to paste (commit =
#               --commit, default HEAD: the commit the bitstream on the card was built
#               from). Picture and sound are judged on the HDMI output and are not part
#               of the script. Needs ssh root@<board>; copies fps.py, perf.py, vpad.py,
#               vkbd.py to /tmp on the board and writes the .mgl there, nothing on the
#               card. Exit code 1 when a check fails.
#
#               hwtest.cfg: "key = value" lines, "#" starts a comment line:
#                 rbf       core file relative to /media/fat (_Console/SNES.rbf)
#                 game      optional: file relative to /media/fat/games/<games dir>
#                 games     games directory (default: core name in upper case)
#                 index     file index of the OSD entry in the .mgl (default 0; the
#                           number of "F<n>"/"FS<n>"/"S<n>" in CONF_STR, N64: 1)
#                 type      .mgl file type (default f: loaded file "F"; s: mounted
#                           image "S", PSX CD: S1)
#                 wait      seconds after load_core (default 15)
#                 pad       optional: vpad.py sequence (START 3 A ...)
#                 text      optional: keyboard input, vkbd.py text (\n = Enter)
#                 settle    seconds after the input (default 5)
#                 fps       nominal frame rate in Hz (empty: no frame rate check)
#                 fps_tol   tolerance in percent (default 0.2)
#                 measure   seconds of fps.py (default 30)
#                 pacer     main/alt: pacer ratio the game runs at (default main;
#                           alt for a PAL game on SNES, MISTER_ZYNQ_PACE_ALT)
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
import datetime, os, re, shlex, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORES = os.path.normpath(os.path.join(HERE, "..", "cores"))


def read_cfg(path):
    cfg = {}
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                raise ValueError("%s:%d: no 'key = value'" % (path, n))
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    return cfg


def mgl_text(rbf, game, index="0", ftype="f"):
    """.mgl that loads rbf (path without .rbf) with game at OSD file index index, as a
    loaded file (ftype f) or a mounted image (ftype s)."""
    if ftype not in ("f", "s"):
        raise ValueError("hwtest.cfg: type must be f or s, not %r" % ftype)
    return ('<mistergamedescription>\n\t<rbf>%s</rbf>\n\t<file delay="2" type="%s" index="%s" path="%s"/>\n'
            '</mistergamedescription>\n' % (rbf, ftype, index, game))


def pacer_share(core, pacer="main"):
    """Core edges per master cycle the pacer allows, in percent: G_PACE_NUM / G_PACE_DEN of
    the profile (pacer "alt": G_PACE_NUM_ALT / G_PACE_DEN_ALT); 100 without them (mister_zynq
    defaults 1/1) and with G_FREE_CLK 1 (an edge every cycle)."""
    s = open(os.path.join(CORES, core, "core.tcl"), encoding="utf-8").read()

    def generic(name):
        m = re.search(r"^\s*%s\s+(\d+)" % name, s, re.M)
        return int(m.group(1)) if m else None

    if generic("G_FREE_CLK") == 1:
        return 100.0
    suffix = {"main": "", "alt": "_ALT"}[pacer]
    num, den = generic("G_PACE_NUM" + suffix), generic("G_PACE_DEN" + suffix)
    if pacer == "alt" and (num is None or den is None):
        raise ValueError("%s: pacer = alt without G_PACE_NUM_ALT/G_PACE_DEN_ALT in core.tcl" % core)
    return 100.0 * (num or 1) / (den or 1)


def parse_fps(out):
    m = re.search(r"frames \d+ in [\d.]+ s: ([\d.]+) Hz", out)
    return float(m.group(1)) if m else None


def parse_perf(out):
    """(edges percent, hints) of the last window in perf.py output."""
    edges = [float(x) for x in re.findall(r"core edges ([\d.]+) %", out)]
    hints = re.findall(r"hint: (.*)", out)
    return (edges[-1] if edges else None), hints


def main(argv):
    if not argv or argv[0].startswith("-"):
        sys.exit("usage: hwtest.py <core> [--board <ip>] [--platform <p>] [--commit <c>]")
    core = argv[0]
    board = argv[argv.index("--board") + 1] if "--board" in argv else "192.168.1.20"
    platform = argv[argv.index("--platform") + 1] if "--platform" in argv else "zybo-z7-20"
    commit = argv[argv.index("--commit") + 1] if "--commit" in argv else "HEAD"
    cfg = read_cfg(os.path.join(CORES, core, "hwtest.cfg"))
    ssh = ["ssh", "-o", "BatchMode=yes", "root@" + board]

    def sh(cmd, timeout=300):
        r = subprocess.run(ssh + [cmd], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout + r.stderr

    results = []                                    # (check, ok, value)
    subprocess.run(["scp", "-q"] + [os.path.join(HERE, t) for t in ("fps.py", "perf.py", "vpad.py", "vkbd.py")]
                   + ["root@%s:/tmp/" % board], check=True)

    # load
    target = "/media/fat/" + cfg["rbf"]
    if cfg.get("game"):
        games = cfg.get("games", core.upper())
        rbf = os.path.splitext(cfg["rbf"])[0]
        mgl = mgl_text(rbf, cfg["game"], cfg.get("index", "0"), cfg.get("type", "f"))
        rc, out = sh("test -f " + shlex.quote("/media/fat/games/%s/%s" % (games, cfg["game"])))
        if rc:
            sys.exit("hwtest: game file missing on the card: games/%s/%s" % (games, cfg["game"]))
        subprocess.run(ssh + ["cat > /tmp/hwtest.mgl"], input=mgl, text=True, check=True)
        target = "/tmp/hwtest.mgl"
    sh("echo load_core %s > /dev/MiSTer_cmd; sleep %s" % (target, cfg.get("wait", "15")))
    rc, out = sh("python3 /tmp/perf.py 1")
    results.append(("load", rc == 0 and "core edges" in out, out.strip().splitlines()[0] if out.strip() else "-"))

    # input
    if cfg.get("pad"):
        sh("python3 /tmp/vpad.py " + cfg["pad"], timeout=600)
    if cfg.get("text"):
        sh("python3 /tmp/vkbd.py text " + shlex.quote(cfg["text"]), timeout=600)
    sh("sleep " + cfg.get("settle", "5"))

    # speed: fps.py and perf.py over the same time
    sec = cfg.get("measure", "30")
    rc, out = sh("cd /tmp; python3 fps.py %s & sleep 2; python3 perf.py 1; wait" % sec, timeout=int(sec) + 120)
    hz = parse_fps(out)
    edges, hints = parse_perf(out)
    share = pacer_share(core, cfg.get("pacer", "main"))
    ok = edges is not None and edges >= share - 0.1 and not hints
    val = "edges %s %% (pacer %.3f %%)" % (edges, share) + ("; " + "; ".join(hints) if hints else "")
    if cfg.get("fps"):
        nom, tol = float(cfg["fps"]), float(cfg.get("fps_tol", "0.2"))
        ok = ok and hz is not None and abs(hz - nom) <= nom * tol / 100
        val = "%s Hz over %s s (nominal %s ±%s %%), " % (hz, sec, cfg["fps"], cfg.get("fps_tol", "0.2")) + val
    results.append(("speed", ok, val))

    # report
    head = subprocess.run(["git", "-C", HERE, "rev-parse", "--short", commit], capture_output=True,
                          text=True).stdout.strip()
    today = datetime.date.today().isoformat()
    print("hwtest %s on %s:" % (core, board))
    for name, ok, val in results:
        print("  %-8s %s  %s" % (name, "PASS" if ok else "FAIL", val))
    print("STATUS.md rows (commit %s: the bitstream must be built from it):" % head)
    for name, ok, val in results:
        print("| %s | %s | %s | %s | %s | hwtest: %s |" % (platform, name, "HW" if ok else "FAIL", head, today,
                                                                     val.split(" (/")[0]))
    return 0 if all(ok for _, ok, _ in results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
