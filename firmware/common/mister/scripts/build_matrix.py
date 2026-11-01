#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Build of all board x core designs into the status matrix
#  Project    : fpga-mister
#  File       : build_matrix.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-30
# ----------------------------------------------------------------------------------
#  Description: build_matrix.py [--board B]... [--core C]... [--video hdmi|dvi]
#                               [--mem 24G] [--jobs N] [--update] [--dry-run]
#                               [--report-only [--commit C]]
#               (make build-matrix, the nightly build; doc/PORTING.md §3.6)
#               For every board (firmware/targets/<board>, not _*) and every core of
#               it (the designs of MISTER_CORES in its platform.mk plus every core
#               whose STATUS.md has a "timing" row for the board that is not
#               BLOCKED) it runs
#                 PLATFORM=<board> FLOW=vivado CORE=<core> VIDEO=<video> make create build
#               inside systemd-run --user --scope -p MemoryMax=<mem> -p MemorySwapMax=0,
#               one design after the other, then reads the routed reports of impl_1
#               (WNS, TNS, WHS, routing errors, LUT, FF, BRAM tiles, DSP) and writes
#               firmware/build/logs/build_matrix/<stamp>/ (one .log per design,
#               results.json, results.md with the proposed STATUS.md rows). The
#               "timing" row is Timing when the build ran through, the routing is
#               complete and WNS, WHS >= 0, otherwise FAIL. --update writes the rows
#               into cores/<core>/STATUS.md (commit it yourself).
#               The commit of a row is HEAD at the start; the build refuses a tree
#               with changes under firmware/ or Makefiles/ (the bitstream would not
#               belong to a commit). --report-only builds nothing and reads the
#               reports that are there (commit from the stamp a build of this script
#               left in the project, or --commit). --dry-run prints the commands.
#               Needs the Xilinx environment for a build (settings64.sh).
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
import datetime, json, os, re, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import status  # noqa: E402

STAMP = "build_matrix.commit"                       # in hw/<design>/: commit the project was built from


# --------------------------------------------------------------------------- reports

def parse_timing(text):
    """WNS, TNS, WHS, THS (ns) of the Design Timing Summary of report_timing_summary;
    None when the table is missing."""
    m = re.search(r"\|\s*Design Timing Summary.*?\n\s*WNS\(ns\).*?\n\s*-+.*?\n\s*(\S+)\s+(\S+)\s+\S+\s+\S+"
                  r"\s+(\S+)\s+(\S+)", text, re.S)
    if not m:
        return None
    try:
        wns, tns, whs, ths = (float(x) for x in m.groups())
    except ValueError:                              # "inf" for a design without paths
        return None
    return dict(wns=wns, tns=tns, whs=whs, ths=ths,
                met="All user specified timing constraints are met." in text)


def parse_route(text):
    """Nets with routing errors of report_route_status (None when the line is missing)."""
    m = re.search(r"# of nets with routing errors\.*\s*:\s*(\d+)", text)
    return int(m.group(1)) if m else None


def parse_util(text):
    """LUT, FF, BRAM tiles, DSP of report_utilization (placed)."""
    def cell(name):
        m = re.search(r"^\|\s*%s\s*\|\s*([\d.]+)\s*\|" % re.escape(name), text, re.M)
        return float(m.group(1)) if m else None
    lut, ff, bram, dsp = cell("Slice LUTs"), cell("Slice Registers"), cell("Block RAM Tile"), cell("DSPs")
    return dict(lut=None if lut is None else int(lut), ff=None if ff is None else int(ff), bram=bram,
                dsp=None if dsp is None else int(dsp))


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def evaluate(impl, build_ok=True):
    """Result of one design from its impl_1 directory: dict with ok, reason and the values."""
    r = dict(ok=False, reason="", wns=None, tns=None, whs=None, lut=None, ff=None, bram=None, dsp=None)
    if not build_ok:
        r["reason"] = "build failed"
        return r
    t = read(os.path.join(impl, "design_1_wrapper_timing_summary_routed.rpt"))
    if t is None:
        r["reason"] = "no routed timing report"
        return r
    timing = parse_timing(t)
    if timing is None:
        r["reason"] = "no Design Timing Summary"
        return r
    r.update(wns=timing["wns"], tns=timing["tns"], whs=timing["whs"])
    u = read(os.path.join(impl, "design_1_wrapper_utilization_placed.rpt"))
    if u is not None:
        r.update(parse_util(u))
    errors = parse_route(read(os.path.join(impl, "design_1_wrapper_route_status.rpt")) or "")
    if errors is None:
        r["reason"] = "no route status"
    elif errors:
        r["reason"] = "%d nets with routing errors" % errors
    elif timing["wns"] < 0 or timing["whs"] < 0 or not timing["met"]:
        r["reason"] = "timing not met"
    else:
        r["ok"] = True
    return r


# --------------------------------------------------------------------------- STATUS.md rows

def num(x, signed=False):
    """Number as in STATUS.md: decimal point, comma between thousands; signed: ns with three
    decimals and a sign."""
    if signed:
        s = "%+.3f" % x
    elif float(x).is_integer():
        s = "{:,}".format(int(x))
    else:
        s = "%g" % x
    return s.replace("-", "\u2212")


def row(board, design, commit, date, r):
    """The STATUS.md row of stage timing for one result."""
    vals = []
    if r["wns"] is not None:
        vals.append("WNS %s ns, WHS %s ns" % (num(r["wns"], True), num(r["whs"], True)))
    if r["lut"] is not None:
        vals.append("%s LUT, %s BRAM tiles" % (num(r["lut"]), num(r["bram"])))
    note = "`%s` %s" % (design, ", ".join(vals)) if vals else "`%s`" % design
    if not r["ok"]:
        note += " – %s" % r["reason"]
    note += " (build_matrix)"
    return "| %s | timing | %s | %s | %s | %s |" % (board, "Timing" if r["ok"] else "FAIL", commit, date, note)


def update_status(path, board, new_row):
    """Replace the timing row of board in the STATUS.md table at path, or insert it in stage
    order; returns True when the file changed."""
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    order = status.CORE_STAGES
    rank = order.index("timing")
    first = last = found = None
    for i, line in enumerate(lines):
        if not line.startswith("|"):
            if first is not None:
                break
            continue
        if first is None:
            first = i
        last = i
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) > 1 and cells[0] == board and cells[1] == "timing":
            found = i
    if first is None:
        raise ValueError("%s: no table" % path)
    if found is not None:
        if lines[found] == new_row:
            return False
        lines[found] = new_row
    else:
        at = last + 1                                   # after the last row, or before a later stage
        for i in range(first + 2, last + 1):
            cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
            if cells[0] == board and cells[1] in order and order.index(cells[1]) > rank:
                at = i
                break
        lines.insert(at, new_row)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return True


# --------------------------------------------------------------------------- the matrix

def boards_and_cores(root, only_boards=(), only_cores=()):
    """[(board, core)] of the build: MISTER_CORES of platform.mk plus cores with a timing row
    for the board (not BLOCKED)."""
    tdir = os.path.join(root, "firmware/targets")
    cdir = os.path.join(root, "firmware/common/mister/cores")
    out = []
    for board in sorted(os.listdir(tdir)):
        mk = os.path.join(tdir, board, "platform.mk")
        if board.startswith("_") or not os.path.isfile(mk) or (only_boards and board not in only_boards):
            continue
        cores = set()
        with open(mk, encoding="utf-8") as f:
            for line in f:
                if re.match(r"\s*MISTER_CORES\s*[:?+]?=", line):
                    cores |= set(re.findall(re.escape(board) + r"_([a-z0-9]+)", line))
        for core in os.listdir(cdir):
            p = os.path.join(cdir, core, "STATUS.md")
            if core.startswith("_") or not os.path.isfile(p):
                continue
            for cells in status.parse_table(p)[1:]:
                if len(cells) > 2 and cells[0] == board and cells[1] == "timing" and cells[2] != "BLOCKED":
                    cores.add(core)
        out += [(board, c) for c in sorted(cores)
                if os.path.isfile(os.path.join(cdir, c, "core.tcl")) and (not only_cores or c in only_cores)]
    return out


def design_name(board, core, video):
    return "%s_%s%s" % (board, core, "_hdmi" if video == "hdmi" else "")


def vivado_ver(root, board):
    x = os.environ.get("XILINX_VIVADO", "")
    m = re.search(r"/(\d{4}\.\d)(/|$)", x)
    if m:
        return m.group(1)
    vers = [d for d in os.listdir(os.path.join(root, "firmware/build", board))
            if re.fullmatch(r"\d{4}\.\d", d)] if os.path.isdir(os.path.join(root, "firmware/build", board)) else []
    return sorted(vers)[-1] if vers else "2025.2"


def git(root, *a):
    return subprocess.run(["git", "-C", root] + list(a), capture_output=True, text=True).stdout.strip()


def opt(argv, name, default=None, many=False):
    vals = [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == name]
    return vals if many else (vals[-1] if vals else default)


def main(argv):
    root = status.repo_root()
    video = opt(argv, "--video", "hdmi")
    mem, jobs = opt(argv, "--mem", "24G"), opt(argv, "--jobs", "16")
    dry, report_only, update = "--dry-run" in argv, "--report-only" in argv, "--update" in argv
    pairs = boards_and_cores(root, opt(argv, "--board", many=True), opt(argv, "--core", many=True))
    if not pairs:
        print("build_matrix.py: nothing to build")
        return 1
    commit = git(root, "rev-parse", "--short", "HEAD")
    if not report_only and not dry:
        dirty = git(root, "status", "--porcelain", "--", "firmware", "Makefiles", "Makefile")
        if dirty:
            print("build_matrix.py: error: changes under firmware/ or Makefiles/, the bitstreams would "
                  "belong to no commit:\n" + dirty)
            return 1
        if not os.environ.get("XILINX_VIVADO"):
            print("build_matrix.py: error: no Xilinx environment (source <Xilinx>/<ver>/Vivado/settings64.sh)")
            return 1
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    logdir = os.path.join(root, "firmware/build/logs/build_matrix", stamp)
    if not dry:
        os.makedirs(logdir, exist_ok=True)
    today = datetime.date.today().isoformat()
    results, rows = [], []
    setup_done = set()
    for board, core in pairs:
        design = design_name(board, core, video)
        hw = os.path.join(root, "firmware/build", board, vivado_ver(root, board), "hw")
        impl = os.path.join(hw, design, design + ".runs", "impl_1")
        build_ok, used = True, commit
        if not report_only:
            env = "PLATFORM=%s FLOW=vivado CORE=%s VIDEO=%s VIVADO_JOBS=%s" % (board, core, video, jobs)
            scope = ["systemd-run", "--user", "--scope", "--quiet", "-p", "MemoryMax=" + mem,
                     "-p", "MemorySwapMax=0"]
            cmds = []
            if board not in setup_done:
                cmds.append(scope + ["make", "-C", root, "PLATFORM=" + board, "FLOW=vivado", "setup"])
                setup_done.add(board)
            cmds.append(scope + ["make", "-C", root] + env.split() + ["create", "build"])
            if dry:
                for c in cmds:
                    print(" ".join(c))
                continue
            log = os.path.join(logdir, design + ".log")
            print("build_matrix.py: %s (log %s)" % (design, os.path.relpath(log, root)), flush=True)
            with open(log, "w") as f:
                for c in cmds:
                    f.write("$ %s\n" % " ".join(c))
                    f.flush()
                    if subprocess.run(c, stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL).returncode:
                        build_ok = False
                        break
            if os.path.isdir(os.path.join(hw, design)):
                with open(os.path.join(hw, design, STAMP), "w") as f:
                    f.write(commit + "\n")
        else:
            used = opt(argv, "--commit") or (read(os.path.join(hw, design, STAMP)) or "").strip() or None
            if not os.path.isdir(impl):
                print("build_matrix.py: %s: no impl_1 run, skipped" % design)
                continue
        r = evaluate(impl, build_ok)
        r.update(board=board, core=core, design=design, commit=used, date=today)
        results.append(r)
        line = row(board, design, used or "?", today, r)
        rows.append((core, board, line, used))
        print("  %-28s %s  %s" % (design, "PASS" if r["ok"] else "FAIL", line.split("|")[-2].strip()), flush=True)
    if dry:
        return 0
    with open(os.path.join(logdir, "results.json"), "w") as f:
        json.dump(results, f, indent=1)
    with open(os.path.join(logdir, "results.md"), "w") as f:
        f.write("# build_matrix %s (commit %s)\n\n" % (stamp, commit))
        for core, _, line, _ in rows:
            f.write("cores/%s/STATUS.md\n%s\n\n" % (core, line))
    print("build_matrix.py: results in %s" % os.path.relpath(logdir, root))
    if update:
        for core, board, line, used in rows:
            if not used:
                print("build_matrix.py: %s: commit unknown, not written (--commit)" % core)
                continue
            p = os.path.join(root, "firmware/common/mister/cores", core, "STATUS.md")
            if update_status(p, board, line):
                print("build_matrix.py: %s updated" % os.path.relpath(p, root))
    return 0 if all(r["ok"] for r in results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
