# Status MSX (MSX_MiSTer)

Status per board and stage (stage meanings: `doc/PORTING.md` §3.0). Evidence: HW, Timing, OOC, Sim, Script,
FAIL, BLOCKED, NOT RUN, open. Add the result here after every measurement; `make test` checks the table, `make status`
shows the overview of all cores. Commit `-` means the evidence predates the public history of this repository.

| Board | Stage | Evidence | Commit | Date | Measurement / Remark |
|---|---|---|---|---|---|
| zybo-z7-20 | prepare | Script | - | 2026-10-30 | 9 rules as expected, patch `0001`, `sys_top_zynq.sv` (`make test`) |
| zybo-z7-20 | ooc | OOC | - | 2026-10-28 | `emsx_top` 6,374 LUT, 10.5 BRAM36 |
| zybo-z7-20 | timing | Timing | - | 2026-10-30 | `_msx_hdmi` WNS +0.127 ns, WHS +0.051 ns, 18,572 LUT, 68 BRAM tiles |
| zybo-z7-20 | load | HW | - | 2026-10-30 | `load_core` and boot from `BOOT.bin` (older build); MSX-DOS prompt |
| zybo-z7-20 | picture | HW | - | 2026-10-30 | Kings Valley 2, `ascal` 24 bpp |
| zybo-z7-20 | audio | HW | - | 2026-10-30 | Title music over HDMI |
| zybo-z7-20 | input | HW | - | 2026-10-30 | USB keyboard; virtual keyboard over uinput (`tools/vkbd.py`) |
| zybo-z7-20 | speed | HW | - | 2026-10-30 | 59.90 Hz over 30 s (target 59.92), edges 95.455 % = pacer target, misses 0.04 %; `make hwtest` PASS (59.93 Hz) |
| zybo-z7-20 | saves | HW | - | 2026-10-31 | Writing to `boot.vhd` (Nextor, FAT16): `echo … > SAVE.TXT` in MSX-DOS, core reloaded, `type save.txt` shows the text; 49 bytes of the image on the card changed, `mtype` on a copy returns the 26 bytes |
| zybo-z7-20 | extras | HW | - | 2026-10-29 | Game switching via "Mount *.VHD" |
