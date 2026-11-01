# Status SNES (SNES_MiSTer)

Status per board and stage (stage meanings: `doc/PORTING.md` §3.0). Evidence: HW, Timing, OOC, Sim, Script,
FAIL, BLOCKED, NOT RUN, open. Add the result here after every measurement; `make test` checks the table, `make status`
shows the overview of all cores. Commit `-` means the evidence predates the public history of this repository.

| Board | Stage | Evidence | Commit | Date | Measurement / Remark |
|---|---|---|---|---|---|
| zybo-z7-20 | prepare | Script | fb47109 | 2026-11-01 | 35 rules (28 of the profile, the rest generic and `sys/`) as expected, patches `0001`/`0002` (`make test`) |
| zybo-z7-20 | ooc | OOC | - | 2026-10-30 | `emu` 31,409 LUT, 97.5 BRAM tiles, 23 DSP (without SPC7110, BSRAM 128 KB) |
| zybo-z7-20 | timing | Timing | - | 2026-10-31 | `_snes_hdmi` with PAL pacer: WNS +0.714 ns, WHS +0.004 ns, 41,426 LUT (77.9 %), 120 BRAM tiles; `core.xdc` hits `core_buf` again (before: derived clock with half the period, −2.227 ns) |
| zybo-z7-20 | load | HW | - | 2026-10-31 | `make hwtest CORE=snes` PASS (`perf.py` measures 90.0 MHz master clock); earlier `load_core` with `.mgl` |
| zybo-z7-20 | picture | HW | - | 2026-10-31 | Yoshi's Island at the PAL clock, intro text correct on the HDMI output; earlier up to level 1-1, Lost Levels |
| zybo-z7-20 | audio | HW | - | 2026-10-31 | Sound over HDMI (Yoshi's Island, Lost Levels) |
| zybo-z7-20 | input | HW | - | 2026-10-30 | Virtual gamepad (`tools/vpad.py`); keyboard after "Define joystick buttons" |
| zybo-z7-20 | speed | HW | - | 2026-10-31 | **PAL clock**: hwtest PASS, Yoshi 50.07 Hz over 30 s (target 50.007 ± 0.2 %), edges 94.583 % = 227/240. Earlier at the NTSC clock: edges 95.43 %, Yoshi 50.48 Hz (target 50.46), Lost Levels 60.10 Hz (target 60.10); `G_CACHE_SPLIT` |
| zybo-z7-20 | saves | BLOCKED | | | Savestates need `DDRAM_*` on a stage C core (bridge on the gated clock missing, HP2 exists only for free-running clocks); BSRAM saving to the card not checked |
| zybo-z7-20 | extras | BLOCKED | | | MSU-1 needs `DDRAM_*` (as saves) and a DDR region not overlapping the SDRAM image (`doc/PORTING.md` §5); no SPC7110 |
