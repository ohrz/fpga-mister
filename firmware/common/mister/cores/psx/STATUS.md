# Status PSX (PSX_MiSTer)

Status per board and stage (stage meanings: `doc/PORTING.md` §3.0). Evidence: HW, Timing, OOC, Sim, Script,
FAIL, BLOCKED, NOT RUN, open. Add the result here after every measurement; `make test` checks the table, `make status`
shows the overview of all cores. Commit `-` means the evidence predates the public history of this repository.

Profile: stage D (as N64), savestates/SNAC/cheats/fast forward off, EXE loading on.

| Board | Stage | Evidence | Commit | Date | Measurement / Remark |
|---|---|---|---|---|---|
| zybo-z7-20 | prepare | Script | - | 2026-10-31 | `prepare_sources.py` with `rules.py`: all rules with the expected count (`declarations_first` 279 in `PSX.sv`, 10 in `rtl/hps_ext.v`); elaboration of `emu` (`--rtl`) without errors, 8-6901/8-8895 only left in `sys/` |
| zybo-z7-20 | ooc | OOC | - | 2026-10-31 | `emu` with profile and placeholder for `sdram.vhd` (56 LUT): 37,028 LUT (69.6 %), 24,003 FF, 97.5 BRAM tiles (80 RAMB36 + 35 RAMB18), 98 DSP; WNS after synthesis `clk_2x` −7.088 ns (38 endpoints: 31 `gpu_poly` `vt` → `targetTiming`, later fixed by a patch; 7 `gpu` `vramState` → `reqVRAMwrap` −0.460 ns), `clk_1x` +8.137, `clk_3x` +4.235, `clk_vid` +11.478 ns, between the core clocks ≥ +0.491 ns; no paths `clk_3x` ↔ `clk_vid`. With `rtl/savestates.vhd` 42,289 LUT, 98.5 BRAM tiles; without EXE loading 36,850 LUT (EXE loading costs 178 LUT) |
| zybo-z7-20 | timing | Timing | - | 2026-10-31 | `zybo-z7-20_psx_hdmi`: WNS +0.216 ns, WHS +0.022 ns, 43,296 LUT (81.4 %), 114 BRAM tiles. Without the false-path rule on `pll2/pal_s_reg[0]` −4.825 ns (1 endpoint `isPal` → synchronizer, stopped by the build guard); without patch and bridge change −5.947 ns |
| zybo-z7-20 | load | HW | - | 2026-10-31 | 20 of 20 starts (Crash 3 EU, CUE, alternately from the menu and from the PSX core: `load_core`, after 35 s exception vector 0x80 set in main RAM). Before, 25–50 % hung: (1) the HP2 bridge waited for the W beat of a withdrawn write command; (2) then still 1 in 4 to 1 in 7: the first CPU fetch at the asynchronous LOCKED edge was only half accepted, `sdram.vhd` without reset hung forever (fixed with a synchronizer) |
| zybo-z7-20 | picture | HW | - | 2026-10-31 | Crash 3 without flicker at the left edge (user: "no errors, not even the triangles"), GT2 (intro, BIOS logo, MDEC video) correct. Before, the background at x 0..511 was missing on the left: in `gpu_poly` PREPARELINE, `to_integer(xStart) > drawingAreaRight` evaluates TRUE in Vivado for negative left edges (netlist simulation), patch `0002`. Build: WNS +0.280 ns, WHS +0.049 ns, 43,181 LUT. Noisy textures after a ~6 h session disappeared after `reboot` (old and new build) |
| zybo-z7-20 | audio | HW | - | 2026-10-31 | Sound over HDMI: Crash 3, GT2 intro (CD-XA) |
| zybo-z7-20 | input | HW | - | 2026-10-31 | DualSense over Bluetooth (CSR dongle, `tools/pair-ds5.sh`) in Gran Turismo 2: controls work (user) |
| zybo-z7-20 | speed | HW | - | 2026-10-31 | PAL video clock directly from `isPal`: hwtest Crash 3 49.73 Hz over 30 s (target 49.748 ± 0.2 %) PASS, edges 100 %; GT2 intro interlaced 50.07 Hz over 30 s, 50.00 Hz over 10 s (target 49.987). Before: NTSC clock despite "Region EU" (50.13–50.22 / 50.43 Hz), ILA showed `cfg_block` with the sequence last written for NTSC |
| zybo-z7-20 | saves | HW | - | 2026-10-31 | F12 opens the OSD and saves the memory card ("Save to SDCard: On Open OSD"): OSD "Memcard Status: saved", `saves/PSX/<game>.sav` 131,072 bytes, game continues with audio. Before, saving hung after 3 of 128 blocks: `avl_axi_bridge` delivered read data before accepting long read commands, `memcard.vhd` lost beats (fixed) |
| zybo-z7-20 | extras | NOT RUN | | | |
