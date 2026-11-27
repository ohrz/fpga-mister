# Status Menu (Menu_MiSTer)

Status per board and stage (stage meanings: `doc/PORTING.md` §3.0). Evidence: HW, Timing, OOC, Sim, Script,
FAIL, BLOCKED, NOT RUN, open. Add the result here after every measurement; `make test` checks the table, `make status`
shows the overview of all cores. Commit `-` means the evidence comes from the public repository ohrz/fpga-mister (its hashes do not exist here).

| Board | Stage | Evidence | Commit | Date | Measurement / Remark |
|---|---|---|---|---|---|
| zybo-z7-20 | prepare | Script | - | 2026-10-30 | Rules as expected (`make test`) |
| zybo-z7-20 | timing | Timing | - | 2026-10-30 | `_menu_hdmi` WNS +1.531 ns, WHS +0.029 ns, 11,395 LUT, 26.5 BRAM tiles |
| zybo-z7-20 | load | HW | - | 2026-11-05 | Release build of 2026-11-01, hwtest: PL configured, `perf.py` answers (84.8 MHz). Earlier: `load_core`, 3 switching rounds with MSX, STATUS 0 |
| zybo-z7-20 | picture | HW | - | 2026-11-05 | Release build of 2026-11-01, hwtest: menu over noise on the HDMI output, checked by eye. Earlier: Noise picture, `ascal` header format 01 (24 bpp) |
| zybo-z7-20 | input | HW | - | 2026-10-29 | OSD navigation with the keyboard, switch to MSX |
| zybo-z7-20 | speed | HW | - | 2026-11-05 | Release build of 2026-11-01, hwtest: edges 100.0 %. Earlier: 50.8–51.4 Hz over 5 s; `make hwtest` PASS (edges 100 %) |
| zcu106 | timing | Timing | - | 2026-11-07 | `zcu106_menu` WNS +3.954 ns, WHS +0.010 ns |
| zcu106 | load | HW | - | 2026-11-07 | fpga_manager under the NFS-root Linux; HDMI_CTL done (all 33 ROM entries, Si5324 locked), GTH up, FIFO running, no underflow (debug word `0x0C1D0821`) |
| zcu106 | picture | HW | - | 2026-11-07 | Menu with noise picture over HDMI after Main_MiSTer starts |
| kr260 | timing | Timing | - | 2026-11-26 | `kr260_menu` with the fan PWM: WNS +3.525 ns, WHS +0.011 ns, `clk_pix` 74.2500 MHz |
| kr260 | load | HW | - | 2026-11-26 | `fpga_manager` under the NFS-root Linux: ID 0x5A4D5354, GPI magic 0x5CA623A4. Main identifies `MENU`, STATUS 0 after 2.5 min, `ascal` writes the DDR |
| kr260 | picture | HW | - | 2026-11-27 | Screenshot of Main from the `ascal` buffer: menu noise with the gradient, 640x240, output 1280x720. DisplayPort live input (`kr260_dp_live.py on`): menu and OSD at 1280x720@59.99 through an active DP to HDMI adapter, OSD centered |
| kr260 | speed | HW | - | 2026-11-26 | `perf.py` with Main: core edges 100.000 %, master clock 84.7 to 85.3 MHz. Soak test 25 min with 5 loads (`sw/soak.py`): edges 100 % in 1500 of 1500 samples |
