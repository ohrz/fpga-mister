# Status SNES (SNES_MiSTer)

Status per board and stage (stage meanings: `doc/PORTING.md` §3.0). Evidence: HW, Timing, OOC, Sim, Script,
FAIL, BLOCKED, NOT RUN, open. Add the result here after every measurement; `make test` checks the table, `make status`
shows the overview of all cores. Commit `-` means the evidence comes from the public repository ohrz/fpga-mister (its hashes do not exist here).

| Board | Stage | Evidence | Commit | Date | Measurement / Remark |
|---|---|---|---|---|---|
| zybo-z7-20 | prepare | Script | - | 2026-11-01 | 35 rules (28 of the profile, the rest generic and `sys/`) as expected, patches `0001`/`0002` (`make test`) |
| zybo-z7-20 | ooc | OOC | - | 2026-10-30 | `emu` 31,409 LUT, 97.5 BRAM tiles, 23 DSP (without SPC7110, BSRAM 128 KB) |
| zybo-z7-20 | timing | Timing | - | 2026-10-31 | `_snes_hdmi` with PAL pacer: WNS +0.714 ns, WHS +0.004 ns, 41,426 LUT (77.9 %), 120 BRAM tiles; `core.xdc` hits `core_buf` again (before: derived clock with half the period, −2.227 ns) |
| zybo-z7-20 | load | HW | - | 2026-11-05 | Release build of 2026-11-01, hwtest: PL configured, 90.0 MHz. Earlier: `make hwtest CORE=snes` PASS (`perf.py` measures 90.0 MHz master clock); earlier `load_core` with `.mgl` |
| zybo-z7-20 | picture | HW | - | 2026-11-05 | Release build of 2026-11-01, hwtest: Yoshi's Island intro on the HDMI output, checked by eye. Earlier: Yoshi's Island at the PAL clock, intro text correct on the HDMI output; earlier up to level 1-1, Lost Levels |
| zybo-z7-20 | audio | HW | - | 2026-11-05 | Release build of 2026-11-01, sound over HDMI. Earlier: Sound over HDMI (Yoshi's Island, Lost Levels) |
| zybo-z7-20 | input | HW | - | 2026-11-05 | Release build: `vpad.py` sequence of hwtest; uinput pad with the IDs of a DualSense: language selection with D-pad and Start, German intro follows. Earlier: Virtual gamepad (`tools/vpad.py`); keyboard after "Define joystick buttons" |
| zybo-z7-20 | speed | HW | - | 2026-11-05 | Release build of 2026-11-01, hwtest: 50.03 Hz over 30 s (target 50.007 ± 0.2 %), edges 94.583 % = 227/240. Earlier: **PAL clock**: hwtest PASS, Yoshi 50.07 Hz over 30 s (target 50.007 ± 0.2 %), edges 94.583 % = 227/240. Earlier at the NTSC clock: edges 95.43 %, Yoshi 50.48 Hz (target 50.46), Lost Levels 60.10 Hz (target 60.10); `G_CACHE_SPLIT` |
| zybo-z7-20 | saves | BLOCKED |  |  | Savestates need `DDRAM_*` on a stage C core (bridge on the gated clock missing, HP2 exists only for free-running clocks); BSRAM: "Save Backup RAM" wrote `saves/SNES/<game>.sav` (32 KB, release build, 2026-11-05), loading it back not checked (needs game progress; autosave is off by default) |
| zybo-z7-20 | extras | BLOCKED |  |  | MSU-1 needs `DDRAM_*` (as saves) and a DDR region not overlapping the SDRAM image (`doc/PORTING.md` §5); no SPC7110 |
| zcu106 | timing | Timing | - | 2026-11-07 | `zcu106_snes` WNS +2.169 ns, WHS +0.010 ns with the core clock buffers in the clock region of clk_core (before: cascade 4 regions away, WHS -0.377 ns on 365 endpoints) |
| zcu106 | load | HW | - | 2026-11-07 | hwtest: Yoshi's Island (E) over MGL |
| zcu106 | picture | HW | - | 2026-11-07 | picture over HDMI |
| zcu106 | audio | HW | - | 2026-11-07 | sound over HDMI |
| zcu106 | saves | FAIL | - | 2026-11-07 | hwtest: backup RAM saved with "Save Backup RAM" in the OSD and read back after loading the core again (Main served 32768 of 32768 bytes); savestates FAIL: "Save state"/"Load state" disabled in the OSD, no .ss (stage C without `DDRAM_*`) |
| zcu106 | speed | FAIL | - | 2026-11-07 | hwtest: 49.97 Hz over 30 s (nominal 50.007 ±0.2 %) but edges 94.476 % (pacer 94.583 %): stall 2.26 %, bucket full 0.16 %, 35.8 cycles per miss; Zybo 94.583 % |
