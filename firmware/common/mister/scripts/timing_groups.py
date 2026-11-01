#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Failing timing paths grouped by module
#  Project    : fpga-mister
#  File       : timing_groups.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-30
# ----------------------------------------------------------------------------------
#  Description: timing_groups.py <paths.csv> [<depth>] (default 2): reads the
#               failing endpoints of impl_at_clock.tcl and prints one line per
#               clock pair, start module and end module (hierarchy below emu and
#               n64top, <depth> levels), worst first: worst slack, endpoints,
#               logic levels, data path delay and net share of the worst path.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
import collections, csv, re, sys

depth = int(sys.argv[2]) if len(sys.argv) > 2 else 2


def module(pin):
    path = re.sub(r"^.*?/emu/(n64top/)?", "", pin)
    parts = [p for p in path.split("/")[:-1] if p]
    return "/".join(parts[:depth]) or path


rows = list(csv.DictReader(open(sys.argv[1]), delimiter=";"))
print("%d failing endpoints" % len(rows))
groups = collections.defaultdict(list)
for r in rows:
    groups[(r["group"], module(r["start"]), module(r["end"]))].append(r)
for (clocks, start, end), paths in sorted(groups.items(), key=lambda kv: min(float(r["slack"]) for r in kv[1])):
    w = min(paths, key=lambda r: float(r["slack"]))
    print("%7.3f %5d  %-24s %-36s -> %-36s lvl %2s dp %6.2f net %s %%"
          % (float(w["slack"]), len(paths), clocks, start[:36], end[:36], w["levels"], float(w["datapath"]), w["route_pct"]))
