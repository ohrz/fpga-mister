# Status Menu (Menu_MiSTer)

Status per board and stage (stage meanings: `doc/PORTING.md` §3.0). Evidence: HW, Timing, OOC, Sim, Script,
FAIL, BLOCKED, NOT RUN, open. Add the result here after every measurement; `make test` checks the table, `make status`
shows the overview of all cores. Commit `-` means the evidence predates the public history of this repository.

| Board | Stage | Evidence | Commit | Date | Measurement / Remark |
|---|---|---|---|---|---|
| zybo-z7-20 | prepare | Script | - | 2026-10-30 | Rules as expected (`make test`) |
| zybo-z7-20 | timing | Timing | - | 2026-10-30 | `_menu_hdmi` WNS +1.531 ns, WHS +0.029 ns, 11,395 LUT, 26.5 BRAM tiles |
| zybo-z7-20 | load | HW | - | 2026-10-30 | `load_core`, 3 switching rounds with MSX, STATUS 0 |
| zybo-z7-20 | picture | HW | - | 2026-10-30 | Noise picture, `ascal` header format 01 (24 bpp) |
| zybo-z7-20 | input | HW | - | 2026-10-29 | OSD navigation with the keyboard, switch to MSX |
| zybo-z7-20 | speed | HW | - | 2026-10-30 | 50.8–51.4 Hz over 5 s; `make hwtest` PASS (edges 100 %) |
