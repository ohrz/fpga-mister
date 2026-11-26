#!/usr/bin/env python3
# ----------------------------------------------------------------------------------
#  Title      : Si5324 divider settings and HDMI_CTL init sequence of the ZCU106
#  Project    : fpga-mister
#  File       : si5324_regs.py
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-11-07
# ----------------------------------------------------------------------------------
#  Description: Reproduces what the Linux drivers do on the HDMI_CTL I2C bus of the
#               ZCU106 when the Si5324 (0x68, U108) runs from its 114.285 MHz crystal
#               (free run, parent xtal) and CKOUT1 is set to one rate, and the DP159
#               (0x5E, U94) is programmed for HDMI 1.4 (<= 3.4 Gb/s):
#                 linux-xlnx drivers/clk/si5324drv.c   si5324_calcfreqsettings() and
#                                                      helpers, bit-exact (36.28 fixed
#                                                      point, same search order)
#                 linux-xlnx drivers/clk/clk-si5324.c  si5324_initialize(),
#                                                      si5324_pll_reparent(XTAL),
#                                                      si5324_clkout_set_rate()
#                 hdmi-modules misc/dp159.c            probe ID check, dp159_program()
#               The result is an op list (write, read-modify-write, update_bits, read
#               check, delay) that zcu106_hdmi_ctl.vhd runs as its ROM, and the bus trace
#               the testbench expects (against a register model with the reset values).
#
#                 si5324_regs.py [--fout HZ] [--fin HZ]   divider search, register table,
#                                                         exact output frequency
#                 si5324_regs.py --vhdl-rom               VHDL constant of the ROM
#                 si5324_regs.py --vhdl-expect            VHDL constant of the expected
#                                                         bus trace (testbench)
#                 si5324_regs.py --write-vhdl             replaces both blocks in
#                                                         hdl/zcu106_hdmi_ctl.vhd and
#                                                         tb/zcu106_hdmi_ctl_tb.vhd
#                 si5324_regs.py --selftest               constraint checks, known rates,
#                                                         VHDL blocks up to date
#               Exit code 1 on errors.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------

import argparse
import pathlib
import sys
from fractions import Fraction

# ---------------------------------------------------------------- driver constants
# si5324drv.h (limits of the search; stricter than the data sheet in N1_HS >= 6 and
# f3 >= 10 kHz)
FOSC_MIN = 4850000000
FOSC_MAX = 5670000000
F3_MIN = 10000
F3_MAX = 2000000
FOUT_MIN = 2000
FOUT_MAX = 945000000
N1_HS_MIN = 6
N1_HS_MAX = 11
NC_LS_MIN = 1
NC_LS_MAX = 0x100000
N2_HS_MIN = 4
N2_HS_MAX = 11
N2_LS_MIN = 2
N2_LS_MAX = 0x100000
N3_MIN = 1
N3_MAX = 0x080000
SHIFT = 28
U64 = (1 << 64) - 1

XTAL_HZ = 114285000         # SI5324_REF_CLOCK / SI5324_XTAL_FREQ, measured on the board
FOUT_HZ = 148500000         # 720p60 / 1080p60 TMDS reference (GTH CPLL x20)
BWSEL = 6                   # si5324_calcfreqsettings(): fixed, "How must the bandwidth..."

# data sheet ranges (Si5324 / Si53xx reference manual), checked in addition
DS_N1_HS = range(4, 12)
DS_F3 = (2000, 2000000)

SI5324 = 0x68
DP159 = 0x5E

ROOT = pathlib.Path(__file__).resolve().parent.parent
VHDL_DUT = ROOT / "hdl" / "zcu106_hdmi_ctl.vhd"
VHDL_TB = ROOT / "tb" / "zcu106_hdmi_ctl_tb.vhd"


# ---------------------------------------------------------------- si5324drv.c
def rate_approx(f, md):
    """si5324_rate_approx(): best rational num/denom of f (x.28 fixed point), denom < md."""
    h = [0, 1, 0]
    k = [1, 0, 0]
    n = 1
    if md <= 1:
        return f >> 28, 1
    n <<= 28
    for _ in range(28):
        if (f & 1) == 0:
            n >>= 1
            f >>= 1
        else:
            break
    d = f
    i = 0
    while i < 64:
        a = d // n if n else 0
        if i and not a:
            break
        x = d
        d = n
        m = x % n
        n = m
        x = a
        if k[1] * a + k[0] >= md:
            x = (md - k[0]) // k[1]
            if x * 2 >= a or k[1] >= md:
                i = 65
            else:
                break
        h[2] = x * h[1] + h[0]
        h[0] = h[1]
        h[1] = h[2]
        k[2] = x * k[1] + k[0]
        k[0] = k[1]
        k[1] = k[2]
        i += 1
    return h[1] & 0xFFFFFFFF, k[1] & 0xFFFFFFFF


class Settings:
    pass


def find_n2ls(s):
    n2_ls_div_n3 = s.fosc // (s.fin >> SHIFT) // s.n2_hs // 2
    s.n2_ls, s.n31 = rate_approx(n2_ls_div_n3, s.n31_max)
    s.n2_ls *= 2
    if s.n2_ls < s.n2_ls_min:
        mult = -(-s.n2_ls_min // s.n2_ls)
        s.n2_ls *= mult
        s.n31 *= mult
    if s.n31 < s.n31_min:
        mult = -(-s.n31_min // s.n31)
        s.n2_ls *= mult
        s.n31 *= mult
    if not s.n2_ls_min <= s.n2_ls <= s.n2_ls_max:
        return 0
    if not s.n31_min <= s.n31 <= s.n31_max:
        return 0
    f3 = s.fin // s.n31
    fosc = f3 * s.n2_hs * s.n2_ls
    fout = fosc // (s.n1_hs * s.nc1_ls)
    # u64 difference, abs() of the kernel casts to signed long long
    delta = (fout - s.fout) & U64
    if delta >= 1 << 63:
        delta -= 1 << 64
    if not (F3_MIN << SHIFT) <= f3 <= (F3_MAX << SHIFT):
        return 0
    if not (FOSC_MIN << SHIFT) <= fosc <= (FOSC_MAX << SHIFT):
        return 0
    if not (FOUT_MIN << SHIFT) <= fout <= (FOUT_MAX << SHIFT):
        return 0
    if abs(delta) < s.best_delta_fout:
        s.best = (s.n1_hs, s.nc1_ls, s.n2_hs, s.n2_ls, s.n31)
        s.best_fout = fout
        s.best_delta_fout = abs(delta)
        if delta == 0:
            return 1
    return 0


def find_n2(s):
    result = 0
    for n2_hs in range(N2_HS_MAX, N2_HS_MIN - 1, -1):
        s.n2_hs = n2_hs
        s.n2_ls_min = max(s.fosc // ((F3_MAX * n2_hs) << SHIFT), N2_LS_MIN)
        s.n2_ls_max = min(s.fosc // ((F3_MIN * n2_hs) << SHIFT), N2_LS_MAX)
        result = find_n2ls(s)
        if result:
            break
    return result


def calc_ncls_limits(s):
    s.nc1_ls_min = max(s.n1_hs_min // s.n1_hs, NC_LS_MIN)
    if s.nc1_ls_min > 1 and (s.nc1_ls_min & 1):
        s.nc1_ls_min += 1
    s.nc1_ls_max = min(s.n1_hs_max // s.n1_hs, NC_LS_MAX)
    if s.nc1_ls_max & 1:
        s.nc1_ls_max -= 1
    if s.nc1_ls_max * s.n1_hs < s.n1_hs_min or s.nc1_ls_min * s.n1_hs > s.n1_hs_max:
        return -1
    return 0


def find_ncls(s):
    result = 0
    fosc_1 = s.fout * s.n1_hs
    s.nc1_ls = s.nc1_ls_min
    while s.nc1_ls <= s.nc1_ls_max:
        s.fosc = fosc_1 * s.nc1_ls
        result = find_n2(s)
        if result:
            break
        s.nc1_ls += 1 if s.nc1_ls == 1 else 2
    return result


def calcfreqsettings(fin_hz, fout_hz):
    """si5324_calcfreqsettings(): returns dict of dividers (real values) or None."""
    s = Settings()
    s.fin = fin_hz << SHIFT
    s.fout = fout_hz << SHIFT
    s.best_delta_fout = s.fout
    s.best = None
    s.n1_hs_min = max(FOSC_MIN // fout_hz, N1_HS_MIN * NC_LS_MIN)
    s.n1_hs_max = min(FOSC_MAX // fout_hz, N1_HS_MAX * NC_LS_MAX)
    s.n31_min = max(fin_hz // F3_MAX, N3_MIN)
    s.n31_max = min(fin_hz // F3_MIN, N3_MAX)
    for n1_hs in range(N1_HS_MAX, N1_HS_MIN - 1, -1):
        s.n1_hs = n1_hs
        if calc_ncls_limits(s):
            continue
        if find_ncls(s):
            break
    if s.best_delta_fout == s.fout or s.best is None:
        return None
    n1_hs, nc1_ls, n2_hs, n2_ls, n3 = s.best
    return dict(n1_hs=n1_hs, nc1_ls=nc1_ls, n2_hs=n2_hs, n2_ls=n2_ls, n3=n3,
                driver_hz=s.best_fout >> SHIFT, bwsel=BWSEL)


def exact(fin_hz, d):
    """Exact frequencies of a divider set (rational)."""
    f3 = Fraction(fin_hz, d["n3"])
    fosc = f3 * d["n2_hs"] * d["n2_ls"]
    fout = fosc / (d["n1_hs"] * d["nc1_ls"])
    return f3, fosc, fout


def check_constraints(fin_hz, fout_hz, d, tol=0.003):
    """List of (text, ok) for the data sheet and driver rules."""
    f3, fosc, fout = exact(fin_hz, d)
    err = float(fout / fout_hz - 1)
    c = []
    c.append((f"f3 = fin/N3 = {float(f3):.3f} Hz in data sheet range 2 kHz..2 MHz",
              DS_F3[0] <= f3 <= DS_F3[1]))
    c.append((f"f3 in driver range 10 kHz..2 MHz", F3_MIN <= f3 <= F3_MAX))
    c.append((f"fosc = f3*N2_HS*N2_LS = {float(fosc) / 1e9:.9f} GHz in 4.85..5.67 GHz",
              FOSC_MIN <= fosc <= FOSC_MAX))
    c.append((f"N1_HS = {d['n1_hs']} in 4..11 (driver 6..11)",
              d["n1_hs"] in DS_N1_HS and N1_HS_MIN <= d["n1_hs"] <= N1_HS_MAX))
    c.append((f"NC1_LS = {d['nc1_ls']} is 1 or even, <= 2^20",
              (d["nc1_ls"] == 1 or d["nc1_ls"] % 2 == 0) and 1 <= d["nc1_ls"] <= NC_LS_MAX))
    c.append((f"N2_HS = {d['n2_hs']} in 4..11", N2_HS_MIN <= d["n2_hs"] <= N2_HS_MAX))
    c.append((f"N2_LS = {d['n2_ls']} even, 2..2^20",
              d["n2_ls"] % 2 == 0 and N2_LS_MIN <= d["n2_ls"] <= N2_LS_MAX))
    c.append((f"N32 = {d['n3']} in 1..2^19", N3_MIN <= d["n3"] <= N3_MAX))
    c.append((f"fout = {float(fout):.6f} Hz, error {err * 1e6:+.1f} ppm within +-{tol * 100:.1f} %",
              abs(err) <= tol))
    return c


# ---------------------------------------------------------------- op list
# op: (kind, dev, reg, mask, val, comment)
#   WR   write val
#   RMW  read, write (old & ~mask) | (val & mask) always      (reg_read + reg_write)
#   UPD  read, write (old & ~mask) | (val & mask) if changed  (regmap_update_bits)
#   CHK  read, (old & mask) must equal val, else the attempt fails
#   DLY  wait val milliseconds
def op_list(fin_hz=XTAL_HZ, fout_hz=FOUT_HZ):
    d = calcfreqsettings(fin_hz, fout_hz)
    if d is None:
        raise SystemExit(f"no Si5324 setting for {fout_hz} Hz from {fin_hz} Hz")
    n1 = d["n1_hs"] - 4
    nc = d["nc1_ls"] - 1
    n2h = d["n2_hs"] - 4
    n2l = d["n2_ls"] - 1
    n3 = d["n3"] - 1
    S = SI5324
    ops = [
        # si5324_initialize() without its first step, the device reset RST_REG = 1: the
        # chip resets on that data byte and does not ACK it (ZCU106 2026-11-07; the driver
        # goes on regardless), and the RST pin pulse right before is the same reset
        ("RMW", S, 0, 0x40, 0x40, "FREE_RUN=1"),
        ("RMW", S, 3, 0x10, 0x10, "SQ_ICAL=1"),
        ("WR", S, 4, 0xFF, 0x12, "AUTOSEL_REG=00 manual, HST_DEL"),
        ("WR", S, 6, 0xFF, 0x0F, "SFOUT2=001 (off), SFOUT1=111 (LVDS)"),
        ("RMW", S, 10, 0x08, 0x08, "DSBL2_REG=1: CKOUT2 disabled"),
        ("RMW", S, 11, 0x02, 0x02, "PD_CK2=1"),
        ("WR", S, 19, 0xFF, 0x23, "FOS/VALTIME, LOCKT=011 (13.3 ms)"),
        ("RMW", S, 21, 0xFF, 0xFC, "CKSEL_PIN=0, CK1_ACTV_PIN=0 (read, value ignored)"),
        ("RMW", S, 137, 0x01, 0x01, "FASTLOCK=1"),
        # si5324_pll_reparent(SI5324_PLL_SRC_XTAL)
        ("UPD", S, 0, 0x40, 0x40, "FREE_RUN=1 (reparent xtal)"),
        ("UPD", S, 11, 0x03, 0x01, "PD_CK1=1, PD_CK2=0 (xtal is the CKIN2 path)"),
        ("UPD", S, 3, 0xC0, 0x40, "CKSEL_REG=01: CKIN2 (= xtal in free run)"),
        # si5324_clkout_set_rate()
        ("WR", S, 0, 0xFF, 0x54, "SI5324_FREE_RUN_EN"),
        ("WR", S, 2, 0xFF, (d["bwsel"] << 4) | 2, f"BWSEL_REG={d['bwsel']}"),
        ("WR", S, 11, 0xFF, 0x41, "SI5324_PD_CK1_DIS"),
        ("WR", S, 25, 0xFF, n1 << 5, f"N1_HS={d['n1_hs']}"),
        ("WR", S, 31, 0xFF, (nc >> 16) & 0x0F, f"NC1_LS={d['nc1_ls']} [19:16]"),
        ("WR", S, 32, 0xFF, (nc >> 8) & 0xFF, "NC1_LS [15:8]"),
        ("WR", S, 33, 0xFF, nc & 0xFF, "NC1_LS [7:0]"),
        ("WR", S, 40, 0xFF, (n2h << 5) | ((n2l >> 16) & 0x0F), f"N2_HS={d['n2_hs']}, N2_LS={d['n2_ls']} [19:16]"),
        ("WR", S, 41, 0xFF, (n2l >> 8) & 0xFF, "N2_LS [15:8]"),
        ("WR", S, 42, 0xFF, n2l & 0xFF, "N2_LS [7:0]"),
        ("WR", S, 46, 0xFF, (n3 >> 16) & 0x07, f"N32={d['n3']} [18:16]"),
        ("WR", S, 47, 0xFF, (n3 >> 8) & 0xFF, "N32 [15:8]"),
        ("WR", S, 48, 0xFF, n3 & 0xFF, "N32 [7:0]"),
        ("WR", S, 136, 0xFF, 0x40, "ICAL=1: start calibration"),
        # dp159.c: probe ID check, dp159_program(rate <= 3400 Mb/s)
        ("CHK", DP159, 0, 0xFF, ord("D"), "ID 'D'"),
        ("CHK", DP159, 1, 0xFF, ord("P"), "ID 'P'"),
        ("WR", DP159, 0x09, 0xFF, 0x06, "dp159_program"),
        ("WR", DP159, 0x0B, 0xFF, 0x80, "SLEW_CTL=10, TX_TERM_CTL=00"),
        ("WR", DP159, 0x0C, 0xFF, 0x48, "VSWING +14 %, HDMI_TWPST1=00"),
        ("WR", DP159, 0x0D, 0xFF, 0x00, ""),
        ("WR", DP159, 0x0A, 0xFF, 0x35, "redriver/retimer crossover 1.0 Gb/s"),
    ]
    return ops, d


# ---------------------------------------------------------------- register model
# Reset values of the Si5324 registers the sequence touches (Si53xx family reference
# manual, register map).  Only the testbench trace depends on them: the VHDL reads the
# real values (RMW/UPD) like the driver.
SI5324_RESET = {0: 0x14, 2: 0x42, 3: 0x05, 4: 0x92, 6: 0x2D, 10: 0x00, 11: 0x40,
                19: 0x2C, 21: 0xFF, 136: 0x00, 137: 0x00}
DP159_RESET = {0: ord("D"), 1: ord("P")}


def trace(ops):
    """Bus trace of the op list against the register model: list of (kind, dev, reg, val)."""
    regs = {SI5324: dict(SI5324_RESET), DP159: dict(DP159_RESET)}
    out = []
    for kind, dev, reg, mask, val, _ in ops:
        if kind == "DLY":
            continue
        r = regs[dev]
        if kind == "WR":
            new, write = val, True
        else:
            old = r.get(reg, 0)
            out.append(("R", dev, reg, old))
            if kind == "CHK":
                if old & mask != val:
                    raise SystemExit(f"model: check {dev:#x}/{reg} fails")
                continue
            new = (old & ~mask & 0xFF) | (val & mask)
            write = kind == "RMW" or new != old
        if not write:
            continue
        out.append(("W", dev, reg, new))
        if dev == SI5324 and reg == 136:
            if new & 0x80:          # RST_REG: all registers to reset values, self-clearing
                regs[SI5324] = dict(SI5324_RESET)
                continue
            new &= ~0x40            # ICAL self-clearing
        r[reg] = new
    return out


# ---------------------------------------------------------------- output
def cmd_line(args):
    parts = ["si5324_regs.py"]
    if args.fin != XTAL_HZ:
        parts.append(f"--fin {args.fin}")
    if args.fout != FOUT_HZ:
        parts.append(f"--fout {args.fout}")
    return " ".join(parts)


def vhdl_rom(ops, gen):
    lines = [f"  -- generated by: {gen} --vhdl-rom (do not edit, --write-vhdl replaces it)",
             f"  constant C_ROM : t_rom(0 to {len(ops) - 1}) := ("]
    for i, (kind, dev, reg, mask, val, com) in enumerate(ops):
        sep = "," if i < len(ops) - 1 else " "
        lines.append(f"    (OP_{kind:<3}, x\"{dev:02X}\", x\"{reg:02X}\", x\"{mask:02X}\", x\"{val:02X}\"){sep}"
                     f"  -- {i:2d} {com}".rstrip())
    lines.append("  );")
    return "\n".join(lines)


def vhdl_expect(tr, gen):
    lines = [f"  -- generated by: {gen} --vhdl-expect (do not edit, --write-vhdl replaces it)",
             f"  constant C_EXPECT : t_expect(0 to {len(tr) - 1}) := ("]
    for i, (kind, dev, reg, val) in enumerate(tr):
        sep = "," if i < len(tr) - 1 else " "
        lines.append(f"    ('{kind}', x\"{dev:02X}\", x\"{reg:02X}\", x\"{val:02X}\"){sep}  -- {i:2d}")
    lines.append("  );")
    return "\n".join(lines)


def replace_block(path, tag, body):
    begin = f"  -- BEGIN {tag}"
    end = f"  -- END {tag}"
    text = path.read_text()
    a = text.index(begin) + len(begin) + 1
    b = text.index(end)
    return text[:a] + body + "\n" + text[b:], text[a:b] == body + "\n"


def print_table(args, ops, d):
    f3, fosc, fout = exact(args.fin, d)
    print(f"Si5324 fin = {args.fin} Hz (crystal, free run via the CKIN2 path / N32), "
          f"fout CKOUT1 requested {args.fout} Hz")
    print(f"  N1_HS = {d['n1_hs']}, NC1_LS = {d['nc1_ls']}, N2_HS = {d['n2_hs']}, "
          f"N2_LS = {d['n2_ls']}, N32 = {d['n3']}, BWSEL = {d['bwsel']}")
    print(f"  fout = fin * N2_HS * N2_LS / (N32 * N1_HS * NC1_LS) = {fout} Hz = {float(fout):.6f} Hz")
    print(f"  driver reports {d['driver_hz']} Hz (36.28 fixed point, truncated)")
    print(f"  error {float(fout / args.fout - 1) * 1e6:+.3f} ppm")
    ok = True
    for text, good in check_constraints(args.fin, args.fout, d):
        print(f"  [{'ok' if good else 'FAIL'}] {text}")
        ok &= good
    print("ops (ROM of zcu106_hdmi_ctl):")
    for i, (kind, dev, reg, mask, val, com) in enumerate(ops):
        if kind == "DLY":
            print(f"  {i:2d} DLY {val} ms  {com}")
        else:
            print(f"  {i:2d} {kind:<3} dev 0x{dev:02X} reg {reg:3d} (0x{reg:02X}) mask 0x{mask:02X} "
                  f"val 0x{val:02X}  {com}")
    print("bus trace against the reset values of the register model:")
    for kind, dev, reg, val in trace(ops):
        print(f"  {kind} 0x{dev:02X} reg {reg:3d} = 0x{val:02X}")
    return ok


def selftest():
    fails = 0

    def check(cond, text):
        nonlocal fails
        print(f"{'PASS' if cond else 'FAIL'}: {text}")
        fails += 0 if cond else 1

    # rational approximation against brute force on a few fractions
    for num, den, md in ((3, 7, 100), (355, 113, 1000), (1, 3, 2), (2346, 11429, 11428)):
        f = (num << SHIFT) // den
        n, k = rate_approx(f, md)
        check(1 <= k < md + 1 and abs(Fraction(n, k) - Fraction(f, 1 << SHIFT)) <= Fraction(1, k * k) + Fraction(1, 1 << 27),
              f"rate_approx({num}/{den}, md {md}) = {n}/{k}")
    # the default and further video rates: all rules met, within 0.3 %
    rates = (FOUT_HZ, 25175000, 27000000, 74250000, 154000000, 241500000, 297000000)
    for r in rates:
        d = calcfreqsettings(XTAL_HZ, r)
        check(d is not None, f"{r} Hz: setting found")
        if d is None:
            continue
        for text, good in check_constraints(XTAL_HZ, r, d):
            if not good:
                check(False, f"{r} Hz: {text}")
        check(all(g for _, g in check_constraints(XTAL_HZ, r, d)), f"{r} Hz: all constraints")
    # rates the board ran with under the Linux HDMI TX driver: the driver asks for
    # htotal * vtotal * 60 (2080*1235*60, 2720*1481*60), the Si5324 driver hits them
    for r, want in ((154128000, 154128000), (241699200, 241699200)):
        d = calcfreqsettings(XTAL_HZ, r)
        got = d and float(exact(XTAL_HZ, d)[2])
        check(d is not None and abs(got - want) < 1, f"{r} Hz -> {got:.3f} Hz (expected: {want} Hz)")
    # the default is exact: 114.285 MHz / 7619 = 15 kHz
    ops, d = op_list()
    check(exact(XTAL_HZ, d)[2] == FOUT_HZ and (d["n1_hs"], d["nc1_ls"], d["n2_hs"], d["n2_ls"], d["n3"]) ==
          (9, 4, 11, 32400, 7619), "148.5 MHz: N1_HS 9, NC1_LS 4, N2_HS 11, N2_LS 32400, N32 7619, exact")
    # register encodings of the default
    byreg = {(o[1], o[2]): o[4] for o in ops if o[0] == "WR"}
    n2l = d["n2_ls"] - 1
    check(byreg[(SI5324, 25)] >> 5 == d["n1_hs"] - 4, "reg 25 encodes N1_HS-4")
    check(((byreg[(SI5324, 31)] << 16) | (byreg[(SI5324, 32)] << 8) | byreg[(SI5324, 33)]) == d["nc1_ls"] - 1,
          "regs 31..33 encode NC1_LS-1")
    check(byreg[(SI5324, 40)] >> 5 == d["n2_hs"] - 4 and
          (((byreg[(SI5324, 40)] & 0xF) << 16) | (byreg[(SI5324, 41)] << 8) | byreg[(SI5324, 42)]) == n2l,
          "regs 40..42 encode N2_HS-4, N2_LS-1")
    check(((byreg[(SI5324, 46)] << 16) | (byreg[(SI5324, 47)] << 8) | byreg[(SI5324, 48)]) == d["n3"] - 1,
          "regs 46..48 encode N32-1")
    check(byreg[(SI5324, 2)] == 0x62, "reg 2 = BWSEL 6 << 4 | 2 (driver)")
    # every op fits the ROM fields, the delays fit 8 bits
    check(all(0 <= v <= 255 for o in ops for v in o[2:5]), "ROM fields are bytes")
    # the VHDL blocks are those of the default
    gen = "si5324_regs.py"
    for path, tag, body in ((VHDL_DUT, "si5324_regs.py --vhdl-rom", vhdl_rom(ops, gen)),
                            (VHDL_TB, "si5324_regs.py --vhdl-expect", vhdl_expect(trace(ops), gen))):
        if path.exists():
            _, same = replace_block(path, tag, body)
            check(same, f"{path.name}: block up to date")
        else:
            check(False, f"{path.name}: missing")
    print(f"selftest: {'PASS' if not fails else 'FAIL'} ({fails} failures)")
    return 0 if not fails else 1


def main():
    p = argparse.ArgumentParser(description=__doc__ or "Si5324 settings")
    p.add_argument("--fin", type=int, default=XTAL_HZ, help="crystal frequency in Hz")
    p.add_argument("--fout", type=int, default=FOUT_HZ, help="CKOUT1 frequency in Hz")
    p.add_argument("--vhdl-rom", action="store_true", help="print the VHDL ROM constant")
    p.add_argument("--vhdl-expect", action="store_true", help="print the VHDL expected trace")
    p.add_argument("--write-vhdl", action="store_true", help="replace the blocks in the VHDL files")
    p.add_argument("--selftest", action="store_true", help="run the checks")
    args = p.parse_args()
    if args.selftest:
        return selftest()
    ops, d = op_list(args.fin, args.fout)
    gen = cmd_line(args)
    if args.vhdl_rom:
        print(vhdl_rom(ops, gen))
        return 0
    if args.vhdl_expect:
        print(vhdl_expect(trace(ops), gen))
        return 0
    if args.write_vhdl:
        for path, tag, body in ((VHDL_DUT, "si5324_regs.py --vhdl-rom", vhdl_rom(ops, gen)),
                                (VHDL_TB, "si5324_regs.py --vhdl-expect", vhdl_expect(trace(ops), gen))):
            text, same = replace_block(path, tag, body)
            if not same:
                path.write_text(text)
            print(f"{path}: {'unchanged' if same else 'updated'}")
        return 0
    return 0 if print_table(args, ops, d) else 1


if __name__ == "__main__":
    sys.exit(main())
