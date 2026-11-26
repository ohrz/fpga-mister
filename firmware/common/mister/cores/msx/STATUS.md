# Status MSX (MSX_MiSTer)

Status per board and stage (stage meanings: `doc/PORTING.md` §3.0). Evidence: HW, Timing, OOC, Sim, Script,
FAIL, BLOCKED, NOT RUN, open. Add the result here after every measurement; `make test` checks the table, `make status`
shows the overview of all cores. Commit `-` means the evidence comes from the public repository ohrz/fpga-mister (its hashes do not exist here).

| Board | Stage | Evidence | Commit | Date | Measurement / Remark |
|---|---|---|---|---|---|
| zybo-z7-20 | prepare | Script | - | 2026-10-30 | 9 rules as expected, patch `0001`, `sys_top_zynq.sv` (`make test`) |
| zybo-z7-20 | ooc | OOC | - | 2026-10-28 | `emsx_top` 6,374 LUT, 10.5 BRAM36 |
| zybo-z7-20 | timing | Timing | - | 2026-10-30 | `_msx_hdmi` WNS +0.127 ns, WHS +0.051 ns, 18,572 LUT, 68 BRAM tiles |
| zybo-z7-20 | load | HW | - | 2026-11-05 | Release build of 2026-11-01, hwtest: PL configured, 90.0 MHz. Earlier: `load_core` and boot from `BOOT.bin` (older build); MSX-DOS prompt |
| zybo-z7-20 | picture | HW | - | 2026-11-05 | Release build of 2026-11-01, hwtest: Kings Valley 2 Konami logo on the HDMI output, checked by eye. Earlier: Kings Valley 2, `ascal` 24 bpp |
| zybo-z7-20 | audio | HW | - | 2026-11-05 | Release build of 2026-11-01, sound over HDMI. Earlier: Title music over HDMI |
| zybo-z7-20 | input | HW | - | 2026-10-30 | USB keyboard; virtual keyboard over uinput (`tools/vkbd.py`) |
| zybo-z7-20 | speed | HW | - | 2026-11-05 | Release build of 2026-11-01, hwtest: 59.97 Hz over 30 s (target 59.92 ± 0.2 %), edges 95.455 % = pacer target. Earlier: 59.90 Hz over 30 s (target 59.92), edges 95.455 % = pacer target, misses 0.04 %; `make hwtest` PASS (59.93 Hz) |
| zybo-z7-20 | saves | HW | - | 2026-10-31 | Writing to `boot.vhd` (Nextor, FAT16): `echo … > SAVE.TXT` in MSX-DOS, core reloaded, `type save.txt` shows the text; 49 bytes of the image on the card changed, `mtype` on a copy returns the 26 bytes |
| zybo-z7-20 | extras | HW | - | 2026-10-29 | Game switching via "Mount *.VHD" |
| zcu106 | timing | Timing | - | 2026-11-07 | `zcu106_msx` WNS +2.231 ns, WHS +0.010 ns |
| zcu106 | load | HW | - | 2026-11-07 | hwtest: Kings Valley 2 from MSX-DOS (`romload`), master 89.8 MHz measured |
| zcu106 | picture | HW | - | 2026-11-07 | picture over HDMI |
| zcu106 | audio | HW | - | 2026-11-07 | sound over HDMI |
| zcu106 | input | HW | - | 2026-11-07 | virtual keyboard: `dir` in MSX-DOS |
| zcu106 | speed | HW | - | 2026-11-07 | hwtest: 59.97 Hz over 30 s (nominal 59.92 ±0.2 %), edges 95.455 % (pacer 95.455 %) |
