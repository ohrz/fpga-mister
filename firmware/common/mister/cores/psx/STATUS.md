# Status PSX (PSX_MiSTer)

Status per board and stage (stage meanings: `doc/PORTING.md` §3.0). Evidence: HW, Timing, OOC, Sim, Script,
FAIL, BLOCKED, NOT RUN, open. Add the result here after every measurement; `make test` checks the table, `make status`
shows the overview of all cores. Commit `-` means the evidence comes from the public repository ohrz/fpga-mister (its hashes do not exist here).

Profile: stage D (as N64), savestates/SNAC/cheats/fast forward off, EXE loading on.

| Board | Stage | Evidence | Commit | Date | Measurement / Remark |
|---|---|---|---|---|---|
| zybo-z7-20 | prepare | Script | - | 2026-10-31 | `prepare_sources.py` with `rules.py`: all rules with the expected count (`declarations_first` 279 in `PSX.sv`, 10 in `rtl/hps_ext.v`); elaboration of `emu` (`--rtl`) without errors, 8-6901/8-8895 only left in `sys/` |
| zybo-z7-20 | ooc | OOC | - | 2026-10-31 | `emu` with profile and placeholder for `sdram.vhd` (56 LUT): 37,028 LUT (69.6 %), 24,003 FF, 97.5 BRAM tiles (80 RAMB36 + 35 RAMB18), 98 DSP; WNS after synthesis `clk_2x` −7.088 ns (38 endpoints: 31 `gpu_poly` `vt` → `targetTiming`, later fixed by a patch; 7 `gpu` `vramState` → `reqVRAMwrap` −0.460 ns), `clk_1x` +8.137, `clk_3x` +4.235, `clk_vid` +11.478 ns, between the core clocks ≥ +0.491 ns; no paths `clk_3x` ↔ `clk_vid`. With `rtl/savestates.vhd` 42,289 LUT, 98.5 BRAM tiles; without EXE loading 36,850 LUT (EXE loading costs 178 LUT) |
| zybo-z7-20 | timing | Timing | - | 2026-10-31 | `zybo-z7-20_psx_hdmi`: WNS +0.216 ns, WHS +0.022 ns, 43,296 LUT (81.4 %), 114 BRAM tiles. Without the false-path rule on `pll2/pal_s_reg[0]` −4.825 ns (1 endpoint `isPal` → synchronizer, stopped by the build guard); without patch and bridge change −5.947 ns |
| zybo-z7-20 | load | HW | - | 2026-11-05 | Release build of 2026-11-01, hwtest: PL configured, 49.9 MHz, one start. Earlier: 20 of 20 starts (Crash 3 EU, CUE, alternately from the menu and from the PSX core: `load_core`, after 35 s exception vector 0x80 set in main RAM). Before, 25–50 % hung: (1) the HP2 bridge waited for the W beat of a withdrawn write command; (2) then still 1 in 4 to 1 in 7: the first CPU fetch at the asynchronous LOCKED edge was only half accepted, `sdram.vhd` without reset hung forever (fixed with a synchronizer) |
| zybo-z7-20 | picture | HW | - | 2026-11-05 | Release build of 2026-11-01, hwtest: Crash 3 intro on the HDMI output, checked by eye. Earlier: Crash 3 without flicker at the left edge (user: "no errors, not even the triangles"), GT2 (intro, BIOS logo, MDEC video) correct. Before, the background at x 0..511 was missing on the left: in `gpu_poly` PREPARELINE, `to_integer(xStart) > drawingAreaRight` evaluates TRUE in Vivado for negative left edges (netlist simulation), patch `0002`. Build: WNS +0.280 ns, WHS +0.049 ns, 43,181 LUT. Noisy textures after a ~6 h session disappeared after `reboot` (old and new build) |
| zybo-z7-20 | audio | HW | - | 2026-11-05 | Release build of 2026-11-01, sound over HDMI. Earlier: Sound over HDMI: Crash 3, GT2 intro (CD-XA) |
| zybo-z7-20 | input | HW | - | 2026-10-31 | DualSense over Bluetooth (CSR dongle, `tools/pair-ds5.sh`) in Gran Turismo 2: controls work (user) |
| zybo-z7-20 | speed | HW | - | 2026-11-05 | Release build of 2026-11-01, hwtest: 49.77 Hz over 30 s (target 49.748 ± 0.2 %), edges 100 %. Earlier: PAL video clock directly from `isPal`: hwtest Crash 3 49.73 Hz over 30 s (target 49.748 ± 0.2 %) PASS, edges 100 %; GT2 intro interlaced 50.07 Hz over 30 s, 50.00 Hz over 10 s (target 49.987). Before: NTSC clock despite "Region EU" (50.13–50.22 / 50.43 Hz), ILA showed `cfg_block` with the sequence last written for NTSC |
| zybo-z7-20 | saves | HW | - | 2026-10-31 | F12 opens the OSD and saves the memory card ("Save to SDCard: On Open OSD"): OSD "Memcard Status: saved", `saves/PSX/<game>.sav` 131,072 bytes, game continues with audio. Before, saving hung after 3 of 128 blocks: `avl_axi_bridge` delivered read data before accepting long read commands, `memcard.vhd` lost beats (fixed) |
| zybo-z7-20 | extras | NOT RUN |  |  |  |
| zcu106 | timing | Timing | - | 2026-11-07 | `zcu106_psx` WNS +4.446 ns, WHS +0.010 ns |
| zcu106 | load | HW | - | 2026-11-07 | hwtest: CD image (cue) over MGL |
| zcu106 | picture | HW | - | 2026-11-07 | picture over HDMI |
| zcu106 | audio | HW | - | 2026-11-07 | sound over HDMI |
| zcu106 | speed | HW | - | 2026-11-07 | hwtest: 49.73 Hz over 30 s (nominal 49.748 ±0.2 %), edges 100.0 % |
| zcu106 | saves | BLOCKED | - | 2026-11-07 | hwtest stopped by the start hang (2 of 4 loads: Main stuck sending the BIOS, the core does not take the word) |
| kr260 | timing | Timing | - | 2026-11-27 | `kr260_psx` (compact clocks, `pll2_us.vhd`): WNS +2.860 ns, WHS +0.010 ns, `check_timing` 0, 50,081 LUT (57.7 %), 84.5 BRAM tiles, 4 of 4 MMCM. Video 53.683 MHz (NTSC) and 53.208 MHz (PAL), audio 24.573 MHz |
| kr260 | load | HW | - | 2026-11-27 | Core change from the menu through `load_core` (`/tmp/CORENAME` PSX), BIOS menu on the DisplayPort. A PAL game starts from its CUE through an MGL (CD as `S1`, index 1) |
| kr260 | picture | HW | - | 2026-11-27 | BIOS menu and game demo in 3D with textures at 1280x720@59.99 through the DisplayPort live input, checked by eye |
| kr260 | audio | HW | - | 2026-11-27 | The DPSUB takes 48000 frames/s (counter of `kr260_dp_audio`, `clk_audio` of the compact clocks). Game sound through the DisplayPort: RMS −12 dBFS, right channel without sample steps above 8000 |
| kr260 | speed | HW | - | 2026-11-27 | `fps.py 40`: 49.77 Hz (PAL, target 49.748 ± 0.2 %) |
