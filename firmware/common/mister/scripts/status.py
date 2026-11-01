#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Status matrix of the cores and boards
#  Project    : fpga-mister
#  File       : status.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-30
# ----------------------------------------------------------------------------------
#  Description: Reads firmware/common/mister/cores/<core>/STATUS.md and
#               firmware/targets/<board>/STATUS.md (one Markdown table each, columns
#               Board | Stage | Evidence | Commit | Date | Measurement / Remark; the
#               board files without the Board column; Commit "-" = evidence from before
#               the history of this repository) and
#                 status.py --check           validates them (make test): known boards and
#                                             stages, evidence keyword, commit exists, date,
#                                             no stage twice; warns when a HW row is older
#                                             than the last change of the core profile
#                                             (STATUS.md, README.md, hwtest.cfg, comments and
#                                             core_expect_* do not count)
#                 status.py                   prints the matrix (make status)
#                 status.py --update FILE     replaces the block between
#                                             <!-- status:begin --> and <!-- status:end -->
#               Exit code 1 on errors. Runs from anywhere inside the repository.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
import os, re, subprocess, sys

# stages of a core on a board, in order; meaning in doc/PORTING.md §3.0
CORE_STAGES = ["prepare", "ooc", "timing", "load", "picture", "audio", "input", "speed", "saves", "extras"]
# stages of a board
BOARD_STAGES = ["boot", "linux", "main", "video", "audio", "input", "sd", "net", "switch"]
# evidence, strongest first; the matrix shows the short form
EVIDENCE = {"HW": "HW", "Timing": "Tim", "OOC": "OOC", "Sim": "Sim", "Script": "Scr",
            "FAIL": "FAIL", "BLOCKED": "BLK", "NOT RUN": "–", "open": "–"}
NO_COMMIT = {"NOT RUN", "open", "BLOCKED"}         # rows without evidence need no commit
NOT_PROFILE = ["STATUS.md", "README.md", "hwtest.cfg"]  # files of cores/<core>/ outside the bitstream
# diff lines that do not change the bitstream: headers, blank and comment lines, checks of the
# OOC synthesis (core_expect_*)
NOT_BUILD = re.compile(r"^(diff |index |--- |\+\+\+ |@@|new file|deleted file|similarity index|rename (from|to) "
                       r"|[+-]\s*(#|--|//|$)"
                       r"|[+-]\s*set\s+core_expect_)")
BEGIN, END = "<!-- status:begin -->", "<!-- status:end -->"


def repo_root():
    return subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                          check=True).stdout.strip()


def parse_table(path):
    """Rows of the first Markdown table in path as lists of cells; header row first."""
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("|"):
                cells = [c.strip() for c in line.strip("|").split("|")]
                if all(re.fullmatch(r":?-+:?", c) for c in cells):
                    continue
                rows.append(cells)
            elif rows:
                break
    return rows


def commit_ok(root, c):
    return subprocess.run(["git", "-C", root, "rev-parse", "-q", "--verify", c + "^{commit}"],
                          capture_output=True).returncode == 0


def profile_changes_after(root, core, c):
    """Commits after c that changed the profile of core (not its STATUS.md, README.md,
    hwtest.cfg: they describe the core, the bitstream does not depend on them)."""
    d = "firmware/common/mister/cores/%s" % core
    paths = ["--", d] + [":(exclude)%s/%s" % (d, f) for f in NOT_PROFILE]
    # the core's patches lay in patches/<checkout>/ before they moved into the profile: with
    # both places in the path list git sees the move as a rename, not as new lines
    tcl = os.path.join(root, d, "core.tcl")
    m = re.search(r"^set\s+core_name\s+(\S+)", open(tcl).read(), re.M) if os.path.isfile(tcl) else None
    if m:
        paths.append("firmware/common/mister/patches/%s" % m.group(1))
    diff = subprocess.run(["git", "-C", root, "diff", "--unified=0", c, "HEAD"] + paths,
                          capture_output=True, text=True).stdout
    if not any(NOT_BUILD.match(line) is None for line in diff.splitlines()):
        return []
    r = subprocess.run(["git", "-C", root, "log", "--format=%h", "%s..HEAD" % c] + paths,
                       capture_output=True, text=True)
    return r.stdout.split()


def load(root):
    """(cores, boards, errors, warnings): cores[core][(board, stage)] = row dict,
    boards[board][stage] = row dict."""
    errors, warnings = [], []
    tdir = os.path.join(root, "firmware/targets")
    known_boards = sorted(b for b in os.listdir(tdir)
                          if not b.startswith("_") and os.path.isfile(os.path.join(tdir, b, "platform.mk")))
    cdir = os.path.join(root, "firmware/common/mister/cores")
    cores, boards = {}, {}

    def check_row(where, stage, stages, ev, commit, date):
        if stage not in stages:
            errors.append("%s: unknown stage '%s' (%s)" % (where, stage, ", ".join(stages)))
        if ev not in EVIDENCE:
            errors.append("%s: unknown evidence '%s' (%s)" % (where, ev, ", ".join(EVIDENCE)))
        if ev not in NO_COMMIT:
            if commit != "-" and (not re.fullmatch(r"[0-9a-f]{7,40}", commit) or not commit_ok(root, commit)):
                errors.append("%s: commit '%s' not found" % (where, commit))
            if not re.fullmatch(r"\d{4}-\d\d-\d\d", date):
                errors.append("%s: date '%s' not YYYY-MM-DD" % (where, date))

    for core in sorted(os.listdir(cdir)):
        p = os.path.join(cdir, core, "STATUS.md")
        if core.startswith("_") or not os.path.isfile(p):
            continue
        rel = os.path.relpath(p, root)
        rows = parse_table(p)
        if not rows or [c.lower() for c in rows[0][:5]] != ["board", "stage", "evidence", "commit", "date"]:
            errors.append("%s: table header must be Board | Stage | Evidence | Commit | Date | ..." % rel)
            continue
        cores[core] = {}
        for i, r in enumerate(rows[1:], 2):
            r += [""] * (6 - len(r))
            board, stage, ev, commit, date, note = r[:6]
            where = "%s row %d" % (rel, i)
            if board not in known_boards:
                errors.append("%s: unknown board '%s' (%s)" % (where, board, ", ".join(known_boards)))
            check_row(where, stage, CORE_STAGES, ev, commit, date)
            if (board, stage) in cores[core]:
                errors.append("%s: %s/%s twice" % (where, board, stage))
            cores[core][(board, stage)] = dict(ev=ev, commit=commit, date=date, note=note)
            if ev == "HW" and commit != "-" and commit_ok(root, commit):
                later = profile_changes_after(root, core, commit)
                if later:
                    warnings.append("%s: %s/%s HW evidence %s is older than profile change %s"
                                    % (rel, board, stage, commit, later[0]))

    for board in known_boards:
        p = os.path.join(tdir, board, "STATUS.md")
        if not os.path.isfile(p):
            continue
        rel = os.path.relpath(p, root)
        rows = parse_table(p)
        if not rows or [c.lower() for c in rows[0][:4]] != ["stage", "evidence", "commit", "date"]:
            errors.append("%s: table header must be Stage | Evidence | Commit | Date | ..." % rel)
            continue
        boards[board] = {}
        for i, r in enumerate(rows[1:], 2):
            r += [""] * (5 - len(r))
            stage, ev, commit, date, note = r[:5]
            where = "%s row %d" % (rel, i)
            check_row(where, stage, BOARD_STAGES, ev, commit, date)
            if stage in boards[board]:
                errors.append("%s: stage %s twice" % (where, stage))
            boards[board][stage] = dict(ev=ev, commit=commit, date=date, note=note)
    return cores, boards, errors, warnings


def matrix(cores, boards):
    """Markdown tables: one per board, cores x stages, then the board stages."""
    out = []
    names = sorted({b for c in cores.values() for (b, _) in c} | set(boards))
    for board in names:
        out.append("**%s**" % board)
        out.append("")
        out.append("| Core | " + " | ".join(CORE_STAGES) + " |")
        out.append("|---|" + "---|" * len(CORE_STAGES))
        for core in sorted(cores):
            if not any(b == board for (b, _) in cores[core]):
                continue
            cells = [EVIDENCE[cores[core][(board, s)]["ev"]] if (board, s) in cores[core] else "–"
                     for s in CORE_STAGES]
            out.append("| %s | %s |" % (core, " | ".join(cells)))
        if board in boards:
            out.append("")
            out.append("| Board | " + " | ".join(BOARD_STAGES) + " |")
            out.append("|---|" + "---|" * len(BOARD_STAGES))
            out.append("| %s | %s |" % (board, " | ".join(EVIDENCE[boards[board][s]["ev"]] if s in boards[board]
                                                            else "–" for s in BOARD_STAGES)))
        out.append("")
    out.append("HW = measured on the hardware, Tim = timing after route, OOC = out-of-context synthesis, "
               "Sim = testbench, Scr = script (rules, checks), BLK = blocked, – = open. Details and measured "
               "values: `firmware/common/mister/cores/<core>/STATUS.md`, `firmware/targets/<board>/STATUS.md`; "
               "generated by `make status`.")
    return "\n".join(out) + "\n"


def main(argv):
    root = repo_root()
    cores, boards, errors, warnings = load(root)
    for w in warnings:
        print("status.py: warning: " + w)
    for e in errors:
        print("status.py: error: " + e)
    if errors:
        return 1
    if "--check" in argv:
        print("status.py: %d cores, %d boards, %d rows OK" % (len(cores), len(boards),
              sum(len(c) for c in cores.values()) + sum(len(b) for b in boards.values())))
        return 0
    text = matrix(cores, boards)
    if "--update" in argv:
        path = argv[argv.index("--update") + 1]
        with open(path, encoding="utf-8") as f:
            s = f.read()
        if s.count(BEGIN) != 1 or s.count(END) != 1:
            print("status.py: error: %s needs one %s ... %s block" % (path, BEGIN, END))
            return 1
        a, rest = s.split(BEGIN)
        _, b = rest.split(END)
        new = a + BEGIN + "\n" + text + END + b
        if new != s:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
            print("status.py: %s updated" % path)
        return 0
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
