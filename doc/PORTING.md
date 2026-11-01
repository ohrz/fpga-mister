# Porting: bringing another MiSTer core to a Zynq board

Guide for the next core (e.g. NES, Gameboy, TurboGrafx16, §5.3) and the next board. It describes **what is already verified and reused
unchanged**, the order in which a core is ported, and where each change belongs. How the building blocks work
internally is described in `doc/ARCHITECTURE.md`; directories and conventions in `firmware/common/mister/README.md`.

Principle: **The core and `sys/` stay unchanged.** The port only replaces what does not exist on the Zynq
(Cyclone V hard blocks, Quartus PLLs, Intel megafunctions, SDRAM chip), using building blocks that are the same for
every core. Whatever a core needs is described in a **profile** (`firmware/common/mister/cores/<core>/`), not in the
shared code.

## 1. Layers

```
Core (emu, unchanged)              ← profile: exclusions, replacement files (PLL), rules, macros
  sys/ of the core (unchanged)     ← prepare_sources.py: SYS_RULES, sys_top.v → sys_top_zynq.sv (hard blocks as ports)
    mister_zynq (VHDL, module reference, board- and core-neutral; generics from the profile)
      hps_bus_axi, stage C SDRAM chain, avl_axi_bridge, core_clock_stall, perf_counters
        board block design (generator Tcl <p>_mister.tcl): PS, MMCMs, HDMI (rgb2dvi / hdmi_out from firmware/common/ip/hdmi-tx), codec, pins
```

A new core touches only the top layer (its profile). A new board touches only the bottom layer (§7). Everything in between is reused; if it does change, then for all cores and with a testbench.

## 2. Toolkit: what is verified

Evidence: **Sim** = GHDL testbench with mutation test (`make test`), **Timing** = Vivado after route,
**HW** = running on the Zybo Z7-20 with at least one core.

| Replaces (DE10-Nano / Quartus) | Building block (file) | Use in a new core | Evidence | Limits |
|---|---|---|---|---|
| HPS GPO/GPI (`h2f_gp`) | `hdl/hps_bus_axi.vhd` in `mister_zynq` | automatic | Sim, HW | – |
| SDRAM chip on `SDRAM_*` | stage C: `sdram_emu` → `sdram_region` → `sdram_bram` / `sdram_cache` → `avl_axi_bridge` → HP0 | generics in the profile (§3.4) | Sim (unit and system test `sdram_stagec_tb`), Timing, HW (MSX 59.92 Hz = nominal) | one SDRAM (no `SDRAM2_*`); controller issuing commands on the rising edge; burst 1/2/4/8 |
| Core clock from the Quartus PLL | `core_clock_stall` (BUFGCE + pacer) in `mister_zynq` + replacement `pll.vhd` in the profile | pattern `cores/_template/pll.vhd` with `hdl/clk_pulse_div.vhd` (§3.3) | Sim, Timing, HW (MSX 1/4 divider, menu 1/1) | integer divisors of the fastest clock, phase 0 |
| Falling edge of a derived clock | mid clock `clk_mid` of `hdl/clk_pulse_div.vhd` (`G_MID` = `G_DIV`/2) + rules `falling_edge_to`, `add_port`, `connect_port` in `rules.py` | §3.3 | Sim (`clk_pulse_div_tb`, 7 mutants), rules: unit tests (16 mutants), Gameboy dry run; OOC probe; SNES (own chain, patch) HW | `G_DIV` even (odd: half a master period early); check every consumer of the shifted signals |
| `sysmem` `vbuf` (frame buffer of `ascal`) | `avl_axi_bridge` → HP1 | automatic | Sim, HW | `ascal` with 64 bit (`N_DW` 64); Avalon bursts of 1…255 beats are split into AXI3 bursts ≤ 16 beats without crossing 4 KB (Sim) |
| SDRAM controller with handshake (stage D) | replacement file in the profile with Avalon master → emu port `COREMEM_*` (rules) → `ZYNQ_coremem_*` → `avl_axi_bridge` → HP3 | profile `G_COREMEM 1`, `MISTER_ZYNQ_COREMEM`, `G_FREE_CLK 1` (§3.3); pattern `cores/n64/sdram.vhd` + `rules.py` | Sim (`n64_sdram_tb` against a model of the original, 10/11 mutants; `mister_zynq_free_tb` HP3, 5 mutants), block design validated, RTL elaboration N64 | one replacement per core; one beat per access, no cache |
| Picture without `ascal` (direct video) | `MISTER_DEBUG_NOHDMI`: `HDMI_TX_*` on `CLK_VIDEO` from the VGA branch, DE of the picture (`prepare_sources.py`), `video_pll` (PLLE2) → `vid_clk`/`vid_clk_ser` → transmitter | profile `G_DIRECT_VIDEO 1`, `G_DV_CLKIN_PS`, `G_DV_MULT` (§3.4); the core must deliver 31 kHz (N64: `video_mixer` with scandoubler via rule) | Sim (`video_pll_tb` 7/8 mutants, the survivor is the timeout reset: the PLL model locks even without it; `mister_zynq_free_tb` 4 mutants), RTL elaboration and block design N64 | no CEA mode (N64 1547 × 525 at 48.68 MHz, VIC 0): sink untested; frame rate = that of the core |
| `sysmem` `ram1` (`DDRAM_*` of the core) | `avl_axi_bridge` on `DDRAM_CLK` → `m_axi_ddram` → HP2 | profile `G_DDRAM 1` (§3.4) | Sim (`mister_zynq_tb`: burst across 4 KB, byte enables, quiesce, 3 mutants), block design validated (MSX with forced `G_DDRAM`) | free-running `DDRAM_CLK` only (stage D); open with a gated core clock (stage C); error responses from HP2 untested |
| PLL reprogramming `pll_cfg_hdmi` | `mister_zynq` only acknowledges | automatic | HW | fixed pixel clock 74.25 MHz: `video_mode=0` (720p60) |
| `pll_audio` | MMCM `clk_core` (24.5734 MHz) | automatic | HW | −110 ppm |
| `audio_out` → I2S → codec | SSM2603 via `ssm2603.service` | automatic | HW (headphones) | 48 kHz, 16 bit (`hdmi_audio_96k=0`) |
| HDMI TX (ADV7513 on the DE10) | `rgb2dvi` (DVI) or `hdmi_out` (HDMI with audio; `firmware/common/ip/hdmi-tx`) | `VIDEO=dvi|hdmi` (argument of the board generator) | `hdmi_out`: Sim (symbol level), Timing, HW (picture + audio on the HDMI output) | 7 series (OSERDESE2, TMDS_33 direct); fixed 720p60 (VIC 4), 48 kHz stereo |
| `altsyncram` | `hdl/intel/altsyncram.vhd` | automatic (same name) | Sim, HW (`sys/sd_card.sv`) | subset: dual port/single port, unregistered, mixed widths; **no** byte enables, clock enables, init files, output registers (an assertion aborts) |
| `altddio_out` | `hdl/intel/altddio_out.vhd` | automatic | Sim | behavioural (LUT); on a pin use ODDR in the top level |
| Core switch without bus hang | quiesce (`hps_bus_axi` CTRL/STATUS + Main patch 0004) | automatic | HW | – |
| `ascal` downscaler bottleneck | macro `MISTER_ZYNQ_NO_DOWNSCALE` | in the profile, if the picture is never larger than 720p | Timing, HW | – |
| Area at the LUT limit | macros `MISTER_ZYNQ_SIMPLE_AUDIO` (`hdl/audio_i2s_simple.vhd` instead of `audio_out`: core audio directly as I2S to HDMI and codec, 48 kHz, without filter/volume/S/PDIF, ~1.6k LUT less), `MISTER_ZYNQ_NO_AUDIO` (no audio) and `MISTER_ZYNQ_NO_DIRECT_VIDEO` (`direct_video` = 0: no VGA OSD and no direct video path) | in the profile (`core_defines`) | Sim (`audio_i2s_simple_tb` against `i2s_rx`), Timing, HW (N64) | no audio filter/OSD volume, or no `direct_video=1` |

Tools: `scripts/core_survey.py` (inventory, §3.1), `scripts/synth_core_ooc.tcl` (OOC synthesis); on the board
`tools/fps.py` (frame rate), `tools/perf.py` (stage C counters), `tools/vkbd.py` (keyboard), `tools/vpad.py` (gamepad),
`tools/grab_frame.sh` (input picture of `ascal`), `tools/pair-ds5.sh` (Bluetooth controller).

## 3. Porting a core, step by step

Every step has a checkable result; only continue once it is there.

### 3.0 Stages

The stages are the rows of `cores/<core>/STATUS.md` and the columns of the matrix in `README.md` (`make status`,
`scripts/status.py`). Every row names its evidence (HW, Timing, OOC, Sim, Script, FAIL, BLOCKED, NOT RUN, open), the
commit and the date of the measurement.

| Stage | Reached when | Section |
|---|---|---|
| `prepare` | `prepare_sources.py` passes on the pinned checkout with the profile's rules (every expected count) and patches; checked by `make test` | §3.1, §3.2 |
| `ooc` | out-of-context synthesis of the core (`synth_core_ooc.tcl`): size and BRAM count against the target FPGA | §3.6 |
| `timing` | the whole design `<board>_<core>[_hdmi]` routed with all constraints met (FAIL: built, but WNS/WHS negative) | §3.6 |
| `load` | the bitstream loads on the board (`load_core`), the ID register answers, the core starts | §3.7 steps 1–2 |
| `picture` | correct picture on HDMI | §3.7 step 3 |
| `audio` | sound over HDMI and/or the headphone output | §3.7 step 5 |
| `input` | keyboard, gamepad or Bluetooth controller work in the core and in the OSD | §3.7 step 6 |
| `speed` | frame rate as the original within ±0.2 %, or a documented deviation (menu) (`tools/fps.py`, `make hwtest`) | §3.7 step 4 |
| `saves` | save data (backup RAM, memory cards, disk images) written to the SD card and read back | – |
| `extras` | core-specific features (MSX game switching, SNES MSU-1, …) | core `README.md` |

The board stages of `firmware/targets/<board>/STATUS.md` are listed in §7.

### 3.1 Checkout and inventory

1. Line in `firmware/common/checkouts.txt` (name, URL, branch, **fixed commit**), `make setup` of a flow.
2. Inventory (read-only, changes nothing):

       firmware/common/mister/scripts/core_survey.py _Checkouts/<Core>_MiSTer _Checkouts/Template_MiSTer

   The report lists files, Intel megafunctions (with the replacement file or "missing"), PLL outputs, used `emu`
   ports (used vs. only tied off, `.*` instances), `.qsf` macros, suspicious constructs with file:line, and the
   distance of `sys/` from the template. Verified on MSX and the menu: it finds exactly the places their profiles
   handle (except type errors such as the vector width in `t80.vhd`, which only Vivado reports). Verified on SNES and
   PSX against a manual inventory (§5.1): every megafunction, `pll_cfg`, library `mem`, bursts > 16 beats found.
   Not detected: procedurally assigned `output` nets (Vivado `Synth 8-2577`) and the detailed settings of a
   megafunction (clock enable, `init_file` value): read the instance.
3. Assess before building:
   - **Missing megafunction** (table §2, "missing"): new replacement in `hdl/intel/` with testbench (same name,
     generics, ports; reject unsupported settings with an assertion). Never rewrite it inside the core.
   - **`DDRAM_*` used, `SDRAM2_*` used**: gap (§5), close it first.
   - **Size**: OOC synthesis (§3.6) against the target FPGA. XC7Z020: 53,200 LUT, 140 BRAM36, 220 DSP. The frame
     (`sys/` with `ascal`, OSD, `audio_out`) + stage C + HDMI already occupy 11,200 LUT, 26 BRAM36 and 35 DSP
     (`zybo-z7-20_menu_hdmi` after place, menu core tiny); the MSX design 18,500 LUT, 67.5 BRAM36 (32 of them for the
     VRAM region). That leaves about 40,000 LUT and 110 BRAM36 for the core, minus BRAM regions.

**Lint** (section 7 of the report): finds from the source, with file:line, what otherwise only timing or hardware
shows. With `--profile cores/<core>` (without it: the profile with a matching `core_name`) it counts what the profile
already handles; `--strict` exits with code 1 on errors.

| Check | Error | Warning / info |
|---|---|---|
| falling edge (`falling_edge`, `negedge`, `not CLK` on a clock port), traced through the instances up to the PLL output | on a derived clock, file not touched by the profile | profile touches the file (patch or word in `rules.py`), clock unknown / fastest clock: info |
| core clocks from the PLL | – | more than 3: BUFGCE cascade |
| `.sdc` path exceptions vs. those in `core.xdc` | – | more in the `.sdc`; `create_generated_clock -invert` |
| Intel primitives | without replacement | replacement in `hdl/intel/`, via `core_add` or only in excluded files: info; only in touched files: warning |
| unconnected VHDL inputs with default in Verilog instances | – | count (info), `prepare_sources.py` connects them |

Status: SNES without profile 13 errors, exactly the places found during the port; with profile 0 errors, 12
warnings. MSX and menu 0/0. The BRAM tiles of the first successful OOC synthesis go into the profile as
`set core_expect_bram <n>`; `synth_core_ooc.tcl --profile cores/<core>/core.tcl` (or `--expect-bram <n>`) aborts on
a deviation of more than 10 %: silently removed RAMs.

### 3.2 Making the sources readable for Vivado

Vivado reports only the first failing file per run; the OOC synthesis of the core (§3.6) iterates quickly.
Every change belongs in exactly one place, in this order:

| Case | Location | Example |
|---|---|---|
| Intel building block | replacement in `hdl/intel/` (for all cores) | `altsyncram`, `altddio_out` |
| whole module unsuitable (PLL, `lcell` ring, SDRAM controller in stage D) | replacement file in the profile: `core_exclude` + `core_add`, same module name and same ports | `cores/msx/pll.vhd`, `cores/menu/lfsr.vhd` |
| mechanical Quartus/Vivado difference (syntax, visibility, port kind), countable | rule in `cores/<core>/rules.py` with expected hit count | `t80-ioq-mask`, `sdram-dq-*` |
| the same difference in `sys/` | `SYS_RULES` in `prepare_sources.py` (for all cores) | `sys-hps-io-ps2-scope` |
| behavioural change | patch `cores/<core>/patches/NNNN-<topic>.patch` with header (Main_MiSTer: `patches/Main_MiSTer/`); new logic as a separate VHDL file in the profile with testbench, the patch only wires it in | Main_MiSTer 0001–0004; MSX_MiSTer 0001 + `cores/msx/scc_rom_hide.vhd` |
| unused file that Vivado does not parse | `core_exclude` | MSX `*/VM2413/*` |

Known differences (all solved with a rule or replacement):
- VHDL `label : work.ent` without `entity` → generic rule `vhdl-direct-instantiation` (runs for every core;
  name it in the profile with an expected count).
- VHDL `when … else null;` → `vhdl_null_waveform`, only after checking every occurrence (the latch becomes 0).
- Vectors of unequal length in logic operations → `literal` rule at that place.
- Verilog `inout reg`, outputs assigned in `always` without `reg`, declarations inside `generate` used outside →
  rule.
- `lcell` rings (combinational loops) → clocked replacement file.
- Verilog string passed to a VHDL `boolean` (`"false"` becomes `true`) → 0/1; `prepare_sources.py` checks this for
  `ascal`.
- `.qsf` macros (`VERILOG_MACRO`) → `core_defines`; they can change `sys/` (menu: `MENU_CORE`).
- `` `include `` targets → `mister_core_add` adds them as Verilog headers (automatic).
- Automatic in `prepare_sources.py` (every core, count in the log): port names from Verilog to VHDL entities in their
  spelling; unconnected VHDL inputs with default are connected to the default (otherwise Vivado ties them to 0);
  entities of a VHDL file ordered before their use; Intel libraries and megafunction instances mapped to the
  replacements in `work`; `.mif` → `.mem` with absolute path.
- Use before declaration (Verilog) → `declarations_first` in the profile, per file with expected count.

Every rule gets its **expected hit count**: if the upstream code changes, `prepare_sources.py` aborts instead of
silently building something else. `make test` (step 7) checks all profiles against their pin.

### 3.3 Clocks: replacing the core PLL

Pattern (MSX, menu; verified on HW): the top level drives the **gated master clock** onto `CLK_50M`; the replacement
`pll.vhd` outputs it as the fastest core clock and generates every slower clock as a BUFGCE on the same clock with a
counter in the same domain (`cores/_template/pll.vhd`, one `create_generated_clock` line per derived clock in
`core.xdc`, `cores/_template/core.xdc`). This keeps the phase relation of all core clocks identical after every
stall. Each BUFGCE is one stage of a BUFG cascade starting at `core_buf` (which hangs on an MMCM output without BUFG);
a stage needs an adjacent BUFGCTRL site. `core_buf` can drive two clocks directly, each of them one more
(SNES: four BUFGs, placed). Falling edges of a derived clock have only 5.6 ns: a mid clock built from the master
pulses at which the original clock falls replaces them (SNES `clk_sys_mid`, patch 0002; generically `clk_pulse_div`
with rules, below).
If the core has an `.sdc`, transfer its `set_max_delay`/`set_false_path` to `core.xdc` (converted to the master
period).

Choosing the master clock:
1. Fastest core clock *f*<sub>nom</sub> (from §3.1, PLL outputs). Master clock *f*<sub>m</sub> a few percent
   above it, so that *f*<sub>nom</sub>/*f*<sub>m</sub> = `G_PACE_NUM/G_PACE_DEN` is a small exact fraction
   (MSX: 85.909 MHz = 90.0 MHz · 21/22).
2. Set `core_master_mhz`, run `make create` and read the line `INFO: clk_core clk_out2 …`: the Clocking Wizard
   shares one VCO between audio (24.576 MHz, fractional only on CLKOUT0), master clock and 50 MHz, and does not always
   hit the requested value (menu: 85 → 84.79 MHz). The fraction applies to the **actual** value.
3. Margin = 1 − NUM/DEN must cover the stall time caused by cache misses (MSX: 4.5 % margin, 0.8 % stall).
   `G_PACE_BUCKET` 1024 if sequences of misses stall the core for longer. Measure with `tools/perf.py`.
   If the core switches its clock at runtime (`pll_cfg`, SNES PAL), there is a second ratio
   `G_PACE_NUM_ALT/G_PACE_DEN_ALT` for the same master clock (SNES PAL 85.125 MHz = 90 MHz · 227/240, −6 ppm);
   the profile's replacement `pll_cfg` reports the choice via the `emu` port `ZYNQ_PACE_ALT` (§5).
4. Timing: the master clock is the core's clock; the core must meet it (OOC synthesis with the master clock).

If the pattern does not fit:
- **Non-integer ratios** between core clocks (e.g. 33.8688 and 53.69 MHz) → two separate master clocks cannot stay
  phase-locked with a common stall; options: all clocks as edge sequences of a common faster master with a pacer per
  clock (new building block, Sim first), or stage D (controller replacement, no stalling).
- **Phase-shifted outputs** (usually only `SDRAM_CLK`): disappear with the pin emulator; check others individually.
- **Free-running core clocks (stage D, `G_FREE_CLK 1`)**, if the core waits for its memories via handshake (N64):
  `mister_zynq` itself drives `clk_master` (free-running, BUFG) onto `CLK_50M`, without pacer, BUFGCE and stage C;
  `SDRAM_*` stays unconnected, HP0 idle. The replacement `pll.vhd` then puts an MMCM on `CLK_50M`
  (`core_master_mhz` = input clock of the original PLL, N64: 50.0, `cores/n64/pll.vhd`). Its outputs are derived
  clocks of `clk_master` and therefore fall into its asynchronous group in the board constraints; an MMCM on `clk_50`
  instead would be synchronous to the frame. The core's memories then go via stage D (controller replacement,
  `G_COREMEM`, §3.4) and `G_DDRAM`. Sim: `mister_zynq_free_tb` (5 mutants).
  The core then runs from PL configuration onwards, even before its MMCM locks (`pll_reset` initially holds it in
  reset for 1.3 ms). A replacement controller that evaluates `locked`/`init` must synchronise it to its own clock and
  must not rely on a reset that does not exist: PSX `sdram.vhd` accepted only half of the first CPU fetch on the
  asynchronous LOCKED edge and hung forever without a reset; N64 `sdram.vhd` synchronises in the same way.
- **Falling edges of a derived clock** (lint error "derived clock" from `core_survey.py`): the high time is that of
  the master clock (5.6 ns at 90 MHz). Building block: `clk_pulse_div` with `G_MID => G_DIV/2` in the replacement
  `pll` provides the mid clock (the master pulse at which the DE10 clock falls) as an additional port `outclk_<n>`;
  `rules.py` wires it and moves the edges, each rule with an expected count:
  ```python
  ("mid-net",   "Gameboy.sv", literal("wire clk_sys, clk_ram;", "wire clk_sys, clk_ram;\nwire clk_sys_mid;"), 1),
  ("mid-pll",   "Gameboy.sv", literal("\t.outclk_1(clk_sys),\n", "\t.outclk_1(clk_sys),\n\t.outclk_2(clk_sys_mid),\n"), 1),
  ("mid-gb",    "Gameboy.sv", connect_port("gb", "clk_sys_mid", "clk_sys_mid"), 1),
  ("mid-port",  "rtl/gb.v",   add_port("gb", "input clk_sys_mid"), 1),
  ("mid-edges", "rtl/gb.v",   falling_edge_to("clk_sys", "clk_sys_mid"), 1),
  ```
  `falling_edge_to(clock, mid)`: Verilog `negedge clock` and `.p(~clock)`, VHDL `falling_edge(clock)` (with
  sensitivity list) and `=> not clock`; `add_port(module, decl)` (Verilog ANSI/non-ANSI, VHDL entity);
  `connect_port(module, port, net)` (named connections of every instance). The order of all edges remains that of
  the DE10, also when stalling. All falling edges of the same clock must be moved, also in other files and on RAM
  ports (`clock => not CLK`, SNES CX4: write on the falling edge with enable from `CE`); whatever stays on the clock
  keeps 5.6 ns. After the change run the lint again (`core_survey.py --profile`).
  Gameboy (pin `f6796f3`) as dry run: 11 rules, each count 1. Generated clocks: header of `clk_pulse_div.vhd`,
  pattern `*div_buf/O` (the generate label is part of the name). A logic divider with 50 % duty cycle instead of a
  mid clock needs no rules, but costs ~3 ns of skew between master and derived clock.
- **PLL reprogramming** by the core (`altera_pll_reconfig`, PAL/NTSC switching): gap (§5).

### 3.4 SDRAM: deriving the profile generics from the core's controller

| Generic | Source | MSX / menu |
|---|---|---|
| `G_SD_BANK_BITS`/`ROW`/`COL` | address widths of the controller (`SDRAM_BA`, row = `SDRAM_A`, column from the READ/WRITE command) | 2/13/9 |
| `G_SD_RD_ADJ` | edge at which the controller captures DQ: CL+1 → 0 (the normal case with `SDRAM_CLK` = inverted clock) | 0 / 0 |
| `G_B0_*` | region with dense, latency-critical access (video RAM) → BRAM: mask/value on the flat word address bank·row·column, `G_B0_SEL` the address bits, `G_B0_BITS` word address width (0 = no region) | MSX VRAM 128 KB / – |
| `G_CACHE_COL_HIGH` | 1 if the controller maps low CPU address bits to the **row** (otherwise the cache never hits) | 1 / 0 |
| `G_CACHE_LINE_LOG2`, `G_CACHE_INDEX_BITS` | line 2^n · 8 bytes, 2^m lines (16 KB default) | 2, 9 |
| `G_CACHE_SPLIT` | 1 if `tools/perf.py` shows many misses on lines evicted by a line from the other address half (two memories of the core with the same low address bits, SNES ROM/WRAM): top address bit = top index bit | 1 / 0 |
| `G_FREE_CLK` | 1: core on the free-running `clk_master`, without stage C (§3.3, free-running core clocks); `G_SD_*`, `G_B0_*`, `G_CACHE_*`, `G_PACE_*` then have no effect | 0 / 0 |
| `G_COREMEM` | 1 if a replacement SDRAM controller (stage D) brings out its Avalon master as emu port `COREMEM_*`: `avl_axi_bridge` on its clock → `m_axi_coremem` → HP3 (`mister_coremem`), image at `G_SDRAM_BASE`; also `core_defines` `MISTER_ZYNQ_COREMEM=1` | 0 / 0 |
| `G_DIRECT_VIDEO` | 1 with `core_defines` `MISTER_DEBUG_NOHDMI=1` (without `ascal`): transmitter on the core's video clock; `G_DV_CLKIN_PS` = period of `CLK_VIDEO` in ps, `G_DV_MULT` = VCO / `CLK_VIDEO` (multiple of 5, VCO 800–1600 MHz); the generator connects the transmitter to `mister/vid_clk*` (`mister_direct_video`) | 0 / 0 |
| `G_DDRAM` | 1 if the core uses `DDRAM_*`: `avl_axi_bridge` on the core's `DDRAM_CLK` → `m_axi_ddram`, the board generator connects HP2 (`mister_ddram`). Only if `DDRAM_CLK` is free-running (stage D), not with a gated stage C core clock | 0 / 0 |
| `G_SDRAM_BASE` | location of the SDRAM image in DDR: 0x38000000, in the upper area reserved for the PL (device tree `mister@1ff00000`, 0x1FF00000–0x3FFFFFFF; it also holds the `ascal` buffers from 0x20000000) | default (128 MB space) |

Checks: read the controller's commands (ACT/READ/WRITE/PRE/REF/MRS, burst, CL from the mode register — the emulator
takes CL from the MRS); write down the address mapping (in the profile header, as for MSX); `sdram_stagec_tb` covers
the behaviour for any controller of this kind. The first hardware metric is the frame rate (= nominal?).

### 3.5 Creating the profile

1. `cp -r firmware/common/mister/cores/_template firmware/common/mister/cores/<core>`, replace all `<…>`, back every
   number with file:line of the source (header comment). Everything belonging to a core lives in this directory:
   `README.md` (entry point), `STATUS.md` (evidence per board and stage, `make status`), profile, replacement files,
   `patches/` (patches of the core checkout; `prepare_sources.py --patch-dirs` shows the mapping), `hwtest.cfg`.
2. No design wrapper needed: `<p>_mister.tcl` generates the design for every profile,
   `PLATFORM=<p> FLOW=vivado CORE=<core> [VIDEO=hdmi] make create build` (project `<p>_<core>[_hdmi]`).
3. For the MiSTer package: entry `<p>_<core>$(ZYBO_DESIGN_SUFFIX):<Corename>` in `MISTER_CORES` of the board profile
   (`.rbf` name = the name under which Main looks for the core in `_Computer/` or its folder).
4. `make test`: step 7 checks profile and rules against the pin.

### 3.6 Synthesis, build, timing

    # the core (top emu) with the retained parts of sys/ and the replacement files, for fast iteration
    # (the sources are prepared by make create or by prepare_sources.py with the profile's rules.py):
    M=firmware/common/mister
    vivado -mode batch -source $M/scripts/synth_core_ooc.tcl -tclargs \
      --qip firmware/build/src/<Core>_MiSTer/files.qip --qip firmware/build/src/<Core>_MiSTer/sys/sys.qip \
      --top emu --out firmware/build/ooc/<core> \
      --exclude '*/rtl/pll*' --exclude '*/sys/pll*' --exclude '*/sys_top.v' --exclude '*/sysmem.sv' \
      --exclude '*/f2sdram_safe_terminator.sv' \
      --add $M/hdl/intel/altsyncram.vhd --add $M/hdl/intel/altddio_out.vhd --add $M/cores/<core>/pll.vhd
    # the whole design:
    PLATFORM=zybo-z7-20 FLOW=vivado TOPLEVEL=zybo-z7-20_<core> make create build

Run Vivado only inside `systemd-run --user --scope -p MemoryMax=… -p MemorySwapMax=0`. Read: critical warnings
(the PSU warnings about the DQS delay come from the board preset), WNS/WHS, the clock list of `make create`,
generic values of a VHDL entity in the synth DCP (`get_cells`). The critical path is usually the core itself or the
`ascal` input on `CLK_VIDEO` (then `MISTER_ZYNQ_NO_DOWNSCALE`, if the picture is never larger than 720p).

All designs at once (overnight, `scripts/build_matrix.py`): `make build-matrix [BOARDS=…] [CORES=…] [UPDATE=1]`
builds, per board, the cores from `MISTER_CORES` and every core whose `STATUS.md` has a `timing` row for the board
(not BLOCKED; a new core is added with a row `| <board> | timing | NOT RUN | | | |`, columns Board | Stage | Evidence
| Commit | Date | Measurement / Remark), as `_hdmi` designs one after another, each in
`systemd-run … MemoryMax=24G` (`MEM=`). Afterwards it reads the `impl_1` reports (WNS, WHS, routing errors, LUT,
BRAM tiles) and writes logs, `results.json` and the proposed `timing` rows to
`firmware/build/logs/build_matrix/<time>/`. `UPDATE=1` enters the rows into `STATUS.md` (evidence Timing or FAIL;
Commit = HEAD at start, the tree under `firmware/` must be clean; `-` where there is no git history; commit by hand).
`REPORT_ONLY=1` evaluates existing builds, `DRY_RUN=1` shows the invocations.

A run without errors does not prove that everything was built: Vivado silently removes logic with unconnected or
constant inputs (SNES: VRAM, ARAM, BSRAM and SA1). After the first OOC synthesis, therefore count the BRAM per
instance in the checkpoint (`get_cells -hier -filter {REF_NAME =~ RAMB*}`) and compare with the inventory, likewise
the LUT of the large modules (`report_utilization -hierarchical`). If something is missing, preserve the instance
with `DONT_TOUCH` and query the drivers of its pins.

### 3.7 Hardware bring-up

Order (each stage with evidence, tools §2):
1. Load without changing the SD card: `.bit.bin` to `/tmp` on the board, `mount --bind` over
   `/media/fat/_Computer/<Core>.rbf`, `load_core` via `/dev/MiSTer_cmd` (write the content with `cat >`, not `mv`).
2. ID register 0x40000008 = `0x5A4D5354`, STATUS 0x4000000C = 0 (`devmem2`).
3. Picture: on the HDMI output, or `tools/grab_frame.sh` (input buffer of `ascal`).
4. Frame rate against the nominal value of the original: `tools/fps.py 60` (at least 60 s, shorter windows are
   coarsely quantised). If it deviates:
   `tools/perf.py` (stall share, misses, bucket full) → `G_PACE_*`, `G_CACHE_*`, regions.
5. Audio: HDMI (HDMI design) and headphones.
6. Input: keyboard/gamepad or `tools/vkbd.py keys F12` (OSD), loading media via the OSD, core switch menu ↔ core
   (quiesce).
7. Once the core is on the card: create `cores/<core>/hwtest.cfg` (game, input sequence for `vpad.py` or
   `vkbd.py text`, expected frame rate) and run `make hwtest CORE=<core> COMMIT=<build commit>` (`tools/hwtest.py`):
   it loads the core with the game, plays back the input and checks load and speed (frame rate
   ±0.2 %, edges ≥ pacer share, no warning from `perf.py`); the printed rows go into `STATUS.md`. Repeat after every
   change to the frame or the profile.
8. Only then install permanently on the card (`FLOW=mister make package`, `VIDEO_TX`), keeping a backup of the old
   files.

### 3.8 Wrap-up

- Profile header with all values and sources; add the core to `doc/ARCHITECTURE.md` §3.6 (table of profiles).
- Record new findings (rules, pitfalls, measurements) in the core's `README.md`/`STATUS.md` and, if they apply to
  other cores, in `doc/PORTING.md`.
- New shared building blocks only with testbench and mutation test; state the evidence levels separately.
- Replacements for Intel IP (`hdl/intel/`): additionally synthesise each parameter set that a core uses individually
  in Vivado and check the mapping (RAMB instead of LUT/FF, DSP): GHDL accepts templates that Vivado rejects
  (`altsyncram` with unequal port widths, `Synth 8-2913`).

## 4. Maintaining rules, patches and replacement files

- Rules are tied to the **pin** (expected hit count). New pin of a checkout: `make test` shows every deviating count;
  adapt or remove the rule, never change the count without looking at the place.
- Patches (`cores/<core>/patches/NNNN-<topic>.patch`, Main_MiSTer `patches/Main_MiSTer/`) have a header before the
  diff (Title, Project with pin, Author, Company, Created, Description: *why*). They are applied in sort order;
  `make test` (step 5) applies them to an export of the pin and checks that the copy made by `prepare_sources.py`
  contains them. New pin: rebase the patches, adjust the Project line.
- Replacement files state in their header **which file** they replace, which properties of the original they keep
  (name, ports, clocks, behaviour), and under which conditions that holds.
- `_Checkouts/` is never modified; builds use `firmware/build/src/<checkout>` (regenerated by `prepare_sources.py` on
  every `make create`).

## 5. Open gaps for the next cores

Status 2026-11-01. The column "SNES/PSX" refers to §5.1.

| Gap | Affects | SNES/PSX | Proposal |
|---|---|---|---|
| `DDRAM_*` (`sysmem` `ram1`) with gated core clock | menu console, many arcade cores, savestates (stage C cores) | SNES: MSU-1, savestates; PSX: **mandatory** (VRAM) | HP2 with free-running `DDRAM_CLK` exists (`G_DDRAM`, §3.4). Still missing for stage C: bridge on the master clock with `ce`, or CDC FIFO from the gated to a free-running clock |
| DDR allocation: SDRAM image `G_SDRAM_BASE` 0x3800_0000 lies inside the cores' DDR window (0x2000_0000–0x3FFF_FFFF, physically addressed as on the DE10) | every core with `DDRAM_*` | SNES MSU 0x2060_0000–0x3F7F_FFFF: **overlap**; PSX only 0x3000_0000–0x306F_FFFF and savestates 0x3E00_0000–0x3EFF_FFFF, image (24 MB) from 0x3800_0000 free | move the image below 0x2000_0000 (extend the device tree reservation downwards by 32 MB, Linux loses 32 MB) or a free area per core in the profile |
| second SDRAM (`SDRAM2_*`, `MISTER_DUAL_SDRAM`) | cores with two SDRAM chips | PSX only in the DualSDRAM build (SPU) | standard build without; otherwise a second `sdram_emu` instance with its own region/cache, shared stall |
| PLL reprogramming by the core (`pll_cfg` in `emu`, Altera register values) | cores with PAL/NTSC or clock switching | SNES done (PAL, HW); PSX done for NTSC/PAL (`cores/psx/pll_cfg.vhd`), fast forward off | replacement `pll_cfg` in the profile decodes the written K value (SNES `cores/snes/pll_cfg.vhd`) and sets `reconfig_to_pll[0]`; a rule brings it out as `emu` port `ZYNQ_PACE_ALT` (`MISTER_ZYNQ_PACE_ALT`), `core_clock_stall` then uses `G_PACE_NUM_ALT/G_PACE_DEN_ALT`. Two fixed ratios; more (PSX fast-forward) would need registers |
| clocks that are not integer divisors of the fastest clock | cores with e.g. 1×/2×/3× | PSX 33.87/67.74/101.61 MHz (phase lock required) | master clock = LCM (6 × 33.8688 = 203.2 MHz) with dividers 2/3/6; timing at -1 open |
| falling edge of derived clocks (`falling_edge`, `clock0 => not CLK`) | cores with half-clock logic | SNES solved (`clk_sys_mid`, patch 0002); generic: `clk_pulse_div` + rules (§3.3); PSX unchecked | mid clock in the replacement `pll`, rules instead of a patch; per core only after checking every consumer (CE on falling edge) |
| missing megafunctions | per core (`core_survey.py` "missing") | SNES: `altdpram`, `lpm_mult` done, `dcfifo` as profile replacement (`msu_fifo`); `scfifo`, `lpm_divide` only in the SPC7110 (disabled); PSX: `altdpram` | replacement in `hdl/intel/` with testbench (FIFO with show-ahead, pipelined divider) |
| VHDL library other than `work` | cores with `library x;` | PSX `mem` (37 bindings, mixed with `work.`) | solved per profile: rules `library mem;` → comment, `mem.` → `work.` (N64 `cores/n64/rules.py`, 32 + 47 hits); `core_survey.py` reports a library without a rule as a lint error |
| VHDL-2008 according to `.qsf` (`VHDL_INPUT_VERSION`) | cores with 2008 syntax | PSX | done: `set core_vhdl_std 2008` in the profile, `mister_core_add` sets the file type of the VHDL files of the core `.qip`, `synth_core_ooc.tcl` reads them as VHDL 2008 with `--profile` or `--vhdl2008` (N64) |
| `MISTER_FB` (ascal reads the core's frame buffer from DDR) | cores with their own frame memory | PSX | ascal path via HP1 exists, `FB_*` path untested |
| fixed video mode 720p60 | all (`video_mode=0`) | – | Clocking Wizard with DRP, `hdmi-tx` with VIC selectable at runtime |
| `hdmi_out` 7 series only | ZynqMP boards | – | own serialiser (OSERDESE3/GTH) in `firmware/common/ip/hdmi-tx` |

### 5.1 Requirements of SNES and PSX

Both cores have been ported since (current state: `cores/snes/STATUS.md`, `cores/psx/STATUS.md`). The notes below
are the inventory and the assessments made before and during the port (SNES_MiSTer `bdcd33c`, PSX_MiSTer
`cd17b5a`, 2026-10-29 to 2026-10-31); they are kept because they show what to look for in the next core.
"(estimated)" marks derived numbers.

Already verified: `prepare_sources.py` without core rules runs through on both trees (all `SYS_RULES` with expected
hits, `sys_top_zynq.sv` with 11 replaced blocks), although their `sys/` is older than the template pin (without
`LFB_*`, `FFB`) and SNES uses LF instead of CRLF. The generic rule `vhdl-direct-instantiation` hits SNES
`rtl/bram.vhd` twice.

**SNES** (a profile similar to MSX):

- Clocks: PLL 85.909 / 42.955 (phase −4365 ps) / 21.477 MHz = 4:2:1, i.e. the MSX pattern (master 90 MHz, pacer
  21/22, dividers 2 and 4). The phase of the video clock is irrelevant behind `ascal` (estimated). SDC:
  `set_max_delay` 20/23 ns between `main`/`hps_io` and `sdram` → as `set_max_delay`/multicycle in `core.xdc`.
- PAL/NTSC via `pll_cfg` (K value) → gap PLL reprogramming.
- Memory: `SDRAM_*` (ROM ≤ 16 MB, WRAM) via stage C; `DDRAM_*` only for MSU-1 and savestates (bursts 1–2) →
  normal games run without DDRAM (estimated).
- Size (measured 2026-10-30, synth per module): `emu` with all chips ~37,000 LUT, with the frame ~48,200 of 53,200
  (**90.5 %**, placement doubtful). SPC7110 alone 7010 LUT; without it ~41,200 (77 %). Other chips: CX4 3316,
  SA1 3419, GSU 2937, BSX 602, DSPn 796, SDD1 825 LUT.
- BRAM (counted): BSRAM 256 KB = 64 RAMB36, VRAM 2× 32 KB = 16, ARAM 64 KB = 16, DSPn ROMs 10, rest ~31 →
  `emu` ~128, with the frame ~154 of 140, **too many**. With `BSRAM_BITS` 17 (128 KB, `SNES.sv`) ~122, otherwise
  BSRAM in DDR (stage C region). Whether 128 KB is enough for all games remains to be checked.
- Proposed profile: all chips except SPC7110 (`USE_SPC7110` 0 in `rtl/main.v`), `BSRAM_BITS` 17; MSU-1 only with
  DDRAM (saves ~1100 LUT of `msu_audio` while disabled).
- Vivado pitfalls, solved since 2026-10-30: port name spelling (`main.v` 354 connections), unconnected VHDL inputs
  with default (43), entity order in `bram.vhd` and `.mif` as generic steps in `prepare_sources.py`; use before
  declaration, `.do(`, procedural assignment to `wire`/`output`, unequal operand lengths as rules in
  `cores/snes/rules.py` (24); GSU with both clock edges as patch `cores/snes/patches/0001`; `msu_fifo` as a
  replacement file in the profile.
- Measured with the profile (OOC `emu`, 2026-10-30): 31,409 LUT, 97.5 BRAM tiles (VRAM 16, ARAM 16, BSRAM 32
  RAMB36), 23 DSP. Block design `zybo-z7-20_snes_hdmi`: 41,322 LUT, 119.5 BRAM tiles, WNS +0.215 ns, WHS +0.010 ns,
  after moving the SDC values into `core.xdc` and using `clk_sys_mid` instead of falling edges.
- Megafunctions: `altsyncram` with clock enable and `.mif` (DSPn, CX4, BSX), `altdpram` MLAB, `scfifo`, `dcfifo`
  (MSU, both sides on the same clock → sync FIFO), `lpm_mult`, `lpm_divide` (SA1, SPC7110).
- Vivado: `inout reg` in `rtl/sdram.sv` (menu rules `sdram-dq-*` as template), procedural assignment to `output`
  nets in 6 modules (among them `sdram.sv` `SDRAM_nCS`, `SNES.sv` `USER_OUT`) → rules `output reg`; VHDL instances
  from Verilog with positional generics and different port name case (unchecked).
- Services: UART (MIDI), `hps_ext` (MSU), backup RAM via `sd_*`, `video_mixer` with HQ2x.
- Test ROM (not in the repository; `roms/` is ignored, users must supply their own legally obtained images): the
  game used is a PAL Super FX (GSU-2) title (cartridge type 0x15: Super FX + RAM + battery, 32 KB GSU RAM, LoROM,
  2 MB without copier header, checksum verified). It needs `USE_GSU` (GSU half-clock logic, §5) and is therefore not
  a first test. For the first test use a game without a special chip; the Super FX game then checks the GSU path.

**PSX** (biggest chunk):

- Size: ~108 multiplications (32×32 → 4 DSP48), BRAM ~2.1 Mbit (~70–80 BRAM36, estimated); measured below.
- Clocks 1×/2×/3× phase-locked (logic uses `clk2xIndex`) → master 203.2 MHz, dividers 6/3/2; video clock `pll2`
  53.69 MHz with reprogramming (PAL/NTSC/fast-forward).
- `DDRAM_*` mandatory: VRAM, memory cards, SPU RAM, savestates from 0x3000_0000, read bursts up to 128 beats (the
  bridge splits them); `MISTER_FB` (ascal reads the frame buffer, stride 2048).
- Megafunctions: `altsyncram` with clock enable (7 places with two clocks), `altdpram` MLAB (10 instances); FIFOs
  and multipliers are inferred.
- Vivado: library `mem`, VHDL-2008, `inout reg` in `rtl/sdram.sv`, procedural `output` assignments in `PSX.sv`
  (`USER_OUT`, `VGA_DISABLE`); `file_open` only inside `translate_off` regions.
- `sys/ascal.vhd` is older than in the template (missing resets on PLL reprogramming); uncritical here because the
  HDMI clock is fixed (estimated).

**PSX on the Zybo** (assessment 2026-10-30, PSX_MiSTer `cd17b5a`, OOC synthesis of `psx_mister` without `sys/`,
placeholders for `dpram`/`dpram_dif`/`RamMLAB`): full core 44,639 LUT (83.9 %), 121 BRAM tiles (86 %), 104 DSP,
`clk2x` (67.74 MHz) WNS −6.9 ns; with the frame 105 % LUT and 105 % BRAM. Reduced (72 options as constants:
savestates/rewind/cheats, overlays, texture filter, 24-bit rendering, widescreen, multitap, special controllers,
8 MB, turbo, EXE loading) 41,787 LUT, 99.5 tiles; the savestate logic (3.3k LUT) remains despite the constants and
would need a patch. With the frame without `ascal`, DDRAM bridge and stage D ~45k LUT (~85 %), ~107 tiles. Timing:
`clk1x`/`clk3x` met (specify periods exactly 1:2:3), `clk2x` fails at `gpu_poly` `CALCBOUNDARY1`
(`rtl/gpu_poly.vhd:624–631`, 21.7 ns against 14.8 ns). Solved without an additional state:
patch `cores/psx/patches/0001-gpu-poly-target-timing-factors-in-sortvertices.patch` computes the x and y spans
(order-independent) into registers already in `SORTVERTICES`, `CALCBOUNDARY1` only multiplies; differential bench
`gpu_poly_diff_tb` (original against patch, all outputs every clock, 600 commands, 7/7 mutants) PASS, `gpu_poly`
alone OOC WNS −6.9 → +3.3 ns (synthesis estimate).
Memory: VRAM and SPU RAM in DDR from 0x3000_0000 (`DDRAM_*`, mandatory), main RAM/BIOS in SDRAM with
`ram_ena`/`ram_done` → stage D, free-running clocks from an MMCM (stage C would need a 203 MHz master). The
replacement `cores/psx/sdram.vhd` (Avalon master for `COREMEM`, bench `psx_sdram_tb`) exists; image 24 MB, from
0x3800_0000 without overlap with the core's DDRAM areas. Conclusion at the time: conceivable with compromises
(no savestates, no texture filter); XC7Z100-2 full core 16 % LUT, all clocks met. The routed design closed timing
(`zybo-z7-20_psx_hdmi` WNS +0.216 ns) and runs on the board with the picture through `ascal`.

**PSX profile** (`cores/psx`, 2026-10-31): stage D like N64 (`G_FREE_CLK`, `G_DDRAM`, `G_COREMEM` with
`sdram.vhd`), clocks from one MMCM (VCO 812.5 MHz, /24 /12 /8, −432 ppm) instead of a 203 MHz master, `pll2` NTSC
PLLE2 + PAL MMCM behind `BUFGCTRL` (all 4 MMCMs used). The savestate logic is removed by a replacement
`savestates.vhd` that contains only the reset sequence (cycle-identical to the original, comparison testbench):
`emu` 42,289 → 37,028 LUT, because the read-back paths in GPU, GTE, CPU, CD and DMA disappear as well. EXE loading
stays (178 LUT, for homebrew/test programs without a CD image). `SDRAM` image at 0x3800_0000: the core uses only
0x3800_0000–0x397F_FFFF there (RAM, BIOS, EXE), the DDRAM areas are at 0x3000_0000–0x307F_FFFF and 0x3E00_0000
(savestates disabled, `CONF_STR` entry removed); only the disabled rewind area overlaps.
Vivado traps: pull `typedef struct` in `PSX.sv` onto one line before `declarations_first`; `rtl/hps_ext.v` has
CRLF and uses `localparam`s before their declaration.

### 5.2 Requirements of N64

N64_MiSTer `5725381` (pinned 2026-10-30). The core has been ported since (`cores/n64/STATUS.md`): with the profile's
options as constants and two timing patches it runs on the Zybo at its full clocks, but **outside** its timing
constraints (WNS −2.4 ns); at 80 % only two endpoints miss by 0.03 ns, at 2/3 timing is met. The notes below are the
assessments made before the port and show where the limits of the XC7Z020 are.

Size: OOC synthesis of `n64top` (Vivado 2025.2, synth only). The Intel wrappers `dpram*`, `RamMLAB`, `Shiftreg`,
`cpu_mul` are replaced by placeholders built from XPM memories or inference, behaviour unchecked. Without `sys/`,
stage C and HDMI; on the Zybo the frame costs an additional ~11,200 LUT, 26 BRAM36, 35 DSP (§3.1).

| Target | LUT | BRAM36 | DSP | WNS after synth |
|---|---|---|---|---|
| XC7Z020-1 (Zybo) | 45,071 (84.7 %) | 69.5 | 63 | −6.044 ns, 173 endpoints; critical: RDP on `clk1x`, 22 ns, 27 levels |
| XC7Z100-2 (RK7100) | 45,093 (16 %) | 69.5 | 63 | +3.188 ns |
| XCZU7EV-2 (ZCU106) | 45,026 (20 %) | 63.5 | 63 | +4.556 ns |

With the frame this would be ~56,000 LUT on the XC7Z020, i.e. ~106 % (estimated). Timing is additionally short by
6 ns there. Candidates: RK7100 (XC7Z100, armhf like the Zybo, HDMI via ADV7511) or ZCU106.

Second assessment "does it fit on the Zybo after all?" (2026-10-30):

- **Area: solvable.** The OSD options of `N64.sv` as constants (64DD, mouse, keyboard, pads 2–4, SNAC,
  savestates, cache debug off), VI filter off and the RDP multipliers in DSP48: `n64top` 40,044 LUT (75 %).
  The frame without `ascal` (upstream `MISTER_DEBUG_NOHDMI`: HDMI shows the direct video signal, with scandoubler
  31 kHz, for N64 1547 × 525 clocks at 48.68 MHz, i.e. 480p60 with non-standard line length) and without VGA OSD/YC
  costs ~6k LUT instead of 10.8k: together ~46k LUT (~87 %), ~75 BRAM tiles, ~130 DSP.
- **Timing: not at full speed.** The RDP path alpha combiner → coverage → Z buffer overflow → `blend_enable` lies
  in one `clk1x` cycle (16 ns) and needs 22.4 ns routed, even with DSP48 and retiming. All core clocks together at
  2/3 (41.7/62.5/83.3 MHz) close after routing (`clk1x` +1.4 ns, `clk93` +0.5 ns); more than ~69 % is not possible
  without restructuring. The game would run at ~2/3 speed, the audio ~7 semitones lower.
- **Full clock only with an RDP rework:** an additional pipeline stage between `STAGE_COMBINER` and `STAGE_BLENDER`.
  Difficult, because the two-cycle mode feeds the combiner result (`combine_alpha_next`) back in the next cycle and
  the Z buffer needs alpha/coverage in the same cycle as the FB/Z values read: this shifts the memory timing of the
  RDP. In addition `clk93` (CPU, `cop0`/multiplier) ~1.2 ns. A large patch to a cycle-accurate core, effort of
  weeks, outcome open.
- Independently of the board, `DDRAM_*` (RDRAM) and the cartridge SDRAM were missing; both are solved by stage D
  (`G_DDRAM` on HP2, `G_COREMEM` with `cores/n64/sdram.vhd` on HP3).

Conclusion at the time: on the Zybo at most at ~2/3 speed within the constraints. What came of it: the replacement
`RDP_CombineAlpha.vhd` (multiply-add in one DSP48) closes the RDP path at 80 %, the patches 0001/0002 shorten the CPU
paths; full speed within the constraints still needs a larger device (XC7Z100: +3.2 ns at full clock) or an RDP
rework.

- Clocks: `clk1x` 62.5, CPU 93.75, `clk2x` 125 MHz (2:3:4) → master 187.5 MHz with dividers 3/2/1.5, i.e. not
  integer. Alternatively master 375 MHz with dividers 6/4/3 (timing open), or let the clocks run freely and attach
  only the cartridge SDRAM via handshake (below). Plus `pll2` for video 48.68 MHz with `pll_cfg` (PAL/NTSC).
- `DDRAM_*` mandatory: RDRAM lives in DDR, `DDR3Mux` with 9 users, bursts up to 255 beats (the bridge splits them
  into ≤ 16); `MISTER_FB` (VI writes the frame buffer).
- SDRAM: cartridge ROM, access via `ch1/ch2/ch3` with `req`/`ready` (users SAV, PIF, PI, RDP, VI). The core already
  waits → **stage D possible**: replace `sdram` with an identically connected AXI controller, without clock
  stalling.
- Profile `cores/n64`: `N64.sv:194` (`'Z` next to the drivers of `sdram`/`pll`) and the SNAC block (nets in
  `always`) via rule, library `mem` → `work` (32 clauses, 47 names), VHDL 2008 (`core_vhdl_std`). Replacements with
  testbench and mutation test: `cpu_mul` (64 × 64, latency exactly 2: the FPU reads the product 3 edges after
  `mul1`), `Shiftreg` (`altshift_taps` = DEPTH registers), `pll`/`pll2` (MMCM), `pll_cfg_small` (ignores writes);
  `altsyncram` with byte enables as banks of symmetric byte-write RAMs (Vivado has no asymmetric byte-write RAM,
  RSP IMEM 64/32 → 2 RAMB36). `use_dsp` on six RDP units: −1.2k LUT, +59 DSP. OOC `emu` at 2/3: see `STATUS.md`.
- Startup: PIF boot ROMs (`boot.rom` NTSC, `boot1.rom` PAL) are not included (users must supply their own legally
  obtained images), `pifrom.vhd` is empty; Main_MiSTer has `support/n64`.
- Test ROM (not in the repository, `roms/` is ignored): an unmodified big-endian image of a PAL game: 8 MB,
  CIC 6102/7101, header checksum verified. Starting it requires `boot1.rom`.

### 5.3 Inventory of widespread cores

`core_survey.py` (working state 2026-10-30 with lint section 7) over 17 cores from github.com/MiSTer-devel, shallow
clones from 2026-10-30, plus SNES/MSX/N64 at the pin for comparison. Source read only: synthesis NOT RUN, sizes
unknown. `Genesis_MiSTer` is the old fpgagen port (last commit 2023); its successor `MegaDrive_MiSTer` is counted.
`Arcade-CPS1_MiSTer` does not exist; the CPS cores come from jotego/jtcores (project generated by jtframe, different
layout), not included.

| Core (commit) | Core clocks, MHz | SDRAM / SDRAM2 / DDRAM | falling edge, derived (lint) | missing in `hdl/intel` / profile | `.sdc` exceptions | Notes |
|---|---|---|---|---|---|---|
| NES (`49a0a66`) | 85.9 / 43.0 / 21.5 | yes / – / yes | – | `pll_cfg` | 6 | clocks as SNES |
| SMS (`ab09fdf`) | 53.7 | yes / – / yes | – | `pll_cfg` | 7 (MiST `.sdc`) | `MISTER_FB` |
| GBA (`93790a0`) | 100.7 / 50.3 | yes / – / yes | – | – | 0 | `MISTER_FB`, library ≠ `work`, master > 100 MHz |
| TurboGrafx16 (`827d45f`) | 85.9 / 43.0 | yes / – / yes | – | `scfifo` ×2, `dcfifo_mixed_widths` (CD part) | 9 | – |
| Gameboy (`f6796f3`) | 67.1 / 33.6 | yes / – / yes | 3 | – | 4 | – |
| MegaDrive (`becbdee`) | 107.4 / 53.7 | yes / – / yes | 51 places unresolved (Nuked YM6045, internal clocks) | `pll_cfg` | 2 | master > 100 MHz |
| MegaCD (`a3a3da8`) | 107.4 / 53.7 | yes / – / yes | 3 | `pll_cfg` | 4 + 8 (FX68K) | master > 100 MHz |
| ZX-Spectrum (`dac94cc`) | 112 / 56 | yes / – / yes | 11 unresolved (T80 `CLK_n`) | – | 63 | master > 100 MHz |
| C64 (`88354ba`) | 63.1 / 47.3 / 31.5 | yes / – / yes | 1 | `pll_cfg`, `scfifo`, `dcfifo` | 0 | – |
| Atari800 (`10a997d`) | 114.5 / 57.3 / 28.6 | yes / – / – | – | `pll_cfg` ×2, `scfifo` ×3; check `altera_pll` | 0 | master > 100 MHz |
| AtariST (`426ef87`) | 96.3 / 32.1 / 2.0 | yes / – / – | 4 (+14 unresolved) | – | 6 + 8 | – |
| Minimig-AGA (`e47c345`) | 113.5 / 28.4 | yes / – / yes | 1 (+2) | `pll_cfg` | 38 + 8 | `MISTER_FB`, master > 100 MHz |
| NeoGeo (`ffaab14`) | 96.7 / 48.3 | yes / **yes** / yes | 3 | `pll_cfg` | 3 + 8 | – |
| Arcade-Cave (`ee191ea`) | 96 / 32; video PLL 28 | yes / – / yes | 3 | 2nd PLL, `dcfifo`, `altera_std_synchronizer` | 4 + 8 | `MISTER_FB` |
| PSX (`cd17b5a`) | 101.6 / 67.7 / 33.9; `pll2` 53.7 | yes / **yes** / **mandatory** | – | `pll_cfg`, 2nd PLL (since solved in the profile) | 10 | ported since, runs (§5.1) |
| Saturn (`c072434`) | 114.5 / 57.3 | yes / **yes** / yes | – (1 unresolved) | `pll_cfg`, `scfifo` | 11 + 8 | master > 100 MHz |
| ao486 (`628ddbc`) | 5 clocks (90 … 1.8); `pll2` | yes (dual macro) / – / yes | – | `pll_cfg`, 2nd PLL | 12 | `MISTER_FB`, > 3 core clocks |
| *SNES (pin `bdcd33c`)* | 85.9 / 43.0 / 21.5 | yes / – / yes | solved in the profile | – (profile) | 4 | runs |
| *MSX (pin `bb13016`)* | 85.9 / 21.5 | yes / – / – | – | – | – | runs |
| *N64 (pin `5725381`)* | 4 clocks + `pll2` | – / yes / **mandatory** | – | solved in the profile | 11 | runs, full clock outside timing (§5.2) |

How to read it: "SDRAM/DDRAM yes" means the signals are used in the core, not only tied off. Counted over the files
of `files.qip` (`SDRAM_DQ`/`SDRAM_A`, `DDRAM_ADDR`/`_RD`/`_WE`). What a core needs DDRAM for has not been checked per
core. The OSD texts of NES, SMS, GBA, Gameboy, PSX and ZX mention savestates or rewind; MegaDrive uses DDRAM for
CDDA. DDRAM is mandatory for PSX and N64 (§5.1, §5.2). "Falling edge, derived" counts the lint errors: logic on the
falling edge of a clock derived from the pacer clock (5.6 ns instead of half a period). "Unresolved" are edges on
clocks that the lint does not trace back to the PLL; they must be checked by hand. All cores have unconnected VHDL
inputs with default (2–50 places); `prepare_sources.py` already connects them generically.

**Gaps by number of affected cores** (of the 17 new ones):

| Gap | Cores | Affected | Building block |
|---|---|---|---|
| `DDRAM_*` (HP2) | all except Atari800, AtariST | 15 | §5; mostly savestates only, the cores probably run without (estimated) |
| `.sdc` exceptions moved by hand to `core.xdc` | all except Atari800, C64, GBA | 14 | translator `.sdc` → `core.xdc` (path names Quartus → Vivado, scaled to the master) |
| `pll_cfg` (PAL/NTSC, clock selection) | ao486, Atari800, C64, MegaCD, MegaDrive, Minimig, NeoGeo, NES, PSX, Saturn, SMS | 11 | generic replacement derived from `cores/snes/pll_cfg.vhd`, later with pacer ratio at runtime |
| master > 100 MHz (fastest PLL clock ≥ 100 MHz) | GBA, MegaCD, MegaDrive, ZX, Atari800, Minimig, Saturn, PSX | 8 | timing on XC7Z020-1 open: SNES closes at 90 MHz with +0.3 ns |
| falling edge of derived clocks | Arcade-Cave, AtariST, C64, Gameboy, MegaCD, Minimig, NeoGeo; unresolved: MegaDrive, ZX, Saturn | 7 (+3) | mid clock `clk_pulse_div` + rules `falling_edge_to`/`add_port`/`connect_port` (§3.3) |
| `MISTER_FB` (frame buffer of the core) | ao486, Arcade-Cave, GBA, Minimig, PSX, SMS | 6 | `FB_*` path via HP1 untested (§5) |
| FIFO megafunctions (`scfifo`, `dcfifo`, `dcfifo_mixed_widths`) | Atari800, C64, Saturn, TurboGrafx16, Arcade-Cave | 5 | `hdl/intel/scfifo.vhd`, `dcfifo.vhd` with testbench (show-ahead, mixed widths) |
| second core PLL (independent clock) | ao486, Arcade-Cave, PSX | 3 | second pacer domain or free-running clock with CDC |
| `SDRAM2_*` | NeoGeo, PSX, Saturn | 3 | second `sdram_emu` instance (§5) |
| VHDL library ≠ `work` | GBA, PSX | 2 | generic rule (§5) |
| > 3 core clocks (BUFG cascade) | ao486 | 1 | clock plan per core |

**Cheapest next cores for the Zybo** (estimate from the inventory, without synthesis):

1. **NES**: the same clocks as SNES (master 90 MHz, pacer 21/22, SNES `pll.vhd`), no falling edges, one SDRAM,
   only `pll_cfg` missing (reuse the SNES replacement), 6 `.sdc` exceptions. Least effort.
2. **SMS**: one clock (53.7 MHz), only `pll_cfg`; `MISTER_FB` is set in the `.qsf` → check whether the core really
   needs the frame buffer path.
3. **TurboGrafx16**: master 85.9 MHz like SNES and MSX, plus 43.0 MHz; only FIFOs are missing, and only in the CD
   part (replacement or disable).
4. **Gameboy**: two clocks, no missing megafunctions, but 3 falling edges on `clk_sys` → mid clock (§3.3, rules
   verified in the dry run).
5. **GBA**: lint without errors, but master > 100 MHz (timing), `MISTER_FB` and its own VHDL library.

Large or dependent on missing building blocks: Saturn (DDRAM/SDRAM2, size), ao486 (5 clocks, 2 PLLs),
NeoGeo (SDRAM2), Minimig, MegaCD, Arcade-Cave, C64, AtariST, Atari800, MegaDrive (Nuked YM clocks). Ordered by
benefit: generic `pll_cfg` → `.sdc` translator → FIFOs → DDRAM on HP2 (mid clock: available, §3.3).

Weaknesses of `core_survey.py` revealed by the inventory: section 4 lists no `SDRAM_*` row for cores that declare
their ports via `` `include "sys/emu_ports.vh" `` (here NES, GBA, MegaCD, TurboGrafx16, ZX-Spectrum). The column
above therefore comes from a separate count. The lint does not trace internally generated clocks (Nuked YM, T80
`CLK_n`) back to the PLL.

## 6. Profiles at a glance

| Profile | Checkout | Clock replacement | SDRAM | Rules | Notes |
|---|---|---|---|---|---|
| `msx` | MSX_MiSTer | `pll.vhd` (clk_mem, clk_sys = /4), master 90 MHz, pacer 21/22 | 2/13/9, VRAM → BRAM, `G_CACHE_COL_HIGH` 1 | 3 | `MISTER_ZYNQ_NO_DOWNSCALE`, `games.sh` |
| `menu` | Menu_MiSTer | `pll.vhd` (clk_sys = CLK_VIDEO), master 85 MHz (84.79 achieved), pacer 1/1 | 2/13/9, everything via the cache | 4 | `MENU_CORE`, `lfsr.vhd`, `DDRAM_*` tied off |
| `snes` | SNES_MiSTer | `pll.vhd` (clk_mem, CLK_VIDEO /2, clk_sys /4, mid clock), `pll_cfg.vhd` (PAL pacer 227/240), master 90 MHz, pacer 21/22 | stage C, `G_CACHE_SPLIT` 1 | 28 | patches 0001/0002 (GSU, falling edges), `msu_fifo.vhd`, no SPC7110, BSRAM 128 KB |
| `psx` | PSX_MiSTer | `pll.vhd` (MMCM 33.85/67.71/101.56 MHz), `pll2.vhd` + `pll_cfg.vhd` (NTSC/PAL), free-running | stage D: `sdram.vhd` → HP3, `DDRAM_*` → HP2 | 73 | `savestates.vhd` (reset sequence only), options as constants, EXE loading on, patches 0001/0002 (`gpu_poly`) |
| `n64` | N64_MiSTer | `pll.vhd` (MMCM 62.5/93.75/125 MHz), `pll2.vhd` + `pll_cfg_small.vhd` (NTSC/PAL), free-running | stage D: `sdram.vhd` → HP3, `DDRAM_*` (RDRAM) → HP2 | 66 | options as constants, `cpu_mul.vhd`, `Shiftreg.vhd`, `RDP_CombineAlpha.vhd`, `cpu_addr_fwd.vhd`, patches 0001/0002 (timing) |

## 7. New board

Board-specific is only `firmware/targets/<p>/`: `platform.mk` (flows, boot, `MISTER_CORES`, `VIDEO_TX`),
`constraints/<p>_mister.xdc` (pins, clock groups), `scripts/<ver>/<p>_mister.tcl` (block design for every core: PS,
MMCMs, HDMI output, codec, buttons/LEDs), device tree (reserved DDR, `fclk-enable`), board files of the root FS
(codec init). The template is `firmware/targets/_template/` (derived from `zybo-z7-20`, not a board: `common.mk` and
`selfcheck.sh` skip `targets/_*`); its README lists the steps. Lines marked `CONTRACT` stay, `TODO` and `<...>` are
board work. Then `make test` (step 3 dry-runs every flow action of the new board) and
`PLATFORM=<p> FLOW=vivado CORE=menu make create build`.

Board stages (rows of `firmware/targets/<board>/STATUS.md`): `boot` (BOOT.bin from the SD card, U-Boot, kernel),
`linux` (root file system from the card or NFS), `main` (Main_MiSTer with the Zynq patches, OSD), `video` (HDMI/DVI
picture), `audio` (HDMI audio, codec), `input` (USB keyboard, gamepads, Bluetooth), `sd` (`/media/fat` on the card,
image mounting), `net` (TFTP/NFS boot, SSH), `switch` (core switching through `load_core` with quiesce).

### 7.1 Board contract

What `mister_zynq`, the core profiles and Main_MiSTer expect from the board. Only the Zybo Z7-20 version is
proven (`zybo-z7-20_mister.tcl`, `zybo-z7-20_mister.xdc`, `zynq-zybo-z7.dts`); what applies to ZynqMP is marked
**open**.

| Item | Contract (Zybo, verified) | ZynqMP / ZCU106 |
|---|---|---|
| PS | `processing_system7` with board preset, `PLATFORM_ARCH zynq` | `zynq_ultra_ps_e`, `PLATFORM_ARCH zynqmp`; boot additionally needs PMU firmware and TF-A (open) |
| AXI-Lite | `M_AXI_GP0` → SmartConnect → `mister/s_axi` (`hps_bus_axi`) at **0x4000_0000**, 4 KB; Main patch 0002 hard-codes this base | `M_AXI_HPM0_LPD`/`_FPD` have windows from 0x8000_0000 and 0xA000_0000 respectively: patch 0002 needs the base as an option (open) |
| SDRAM image | `mister/m_axi_sdram` → `S_AXI_HP0`, AXI3 64 bit, clock `clk_master` | `S_AXI_HP0_FPD` is AXI4 128 bit: set to 64 bit or use a width converter, AXI3 master to AXI4 (open) |
| Scaler | `mister/m_axi_vbuf` → `S_AXI_HP1`, AXI3 64 bit, clock FCLK0 | as HP0 (open) |
| DDRAM of the cores | only with profile `G_DDRAM 1`: `mister/m_axi_ddram` → `S_AXI_HP2`, AXI3 64 bit, clock `mister/ddram_clk` (`DDRAM_CLK` of the core); `mister_ddram` in the generator adds HP2 | as HP0 (open) |
| Address windows | HP0/HP1 (HP2) see the whole DDR 0x0000_0000–0x3FFF_FFFF (physical addresses of the cores and of Main unchanged) | DDR low from 0, same windows (open) |
| DDR allocation | `G_SDRAM_BASE` 0x3800_0000 (profile), `ascal` 0x2000_0000, Linux FB 0x2200_0000, ROM loading from 0x3000_0000, handover page 0x1FFF_F000; at least 1 GB DDR from 0 | same |
| Device tree | `reserved-memory` 0x1FF0_0000, size 0x2010_0000, `no-map`; `bootargs` with `uio_pdrv_genirq.of_id=generic-uio`; `&clkc { fclk-enable = <0x1>; }` (otherwise Linux switches FCLK0 off) → `_template/dts/mister.dtsi` | `fclk-enable` does not exist, keep `pl_clk0` running some other way (open) |
| Clocks | FCLK0 100 MHz (`clk_100`: AXI-Lite, HP1, sysmem); MMCM `clk_core` on FCLK0: out1 24.576 MHz (`clk_audio`), out2 master of the profile (`clk_master`, HP0), out3 50 MHz (`clk_50`), out4 master **without BUFG** (`clk_master_gate`, input of the BUFGCE in the frame); the generator script checks that out2 and out4 have identical dividers, phase and duty cycle | `pl_clk0` instead of FCLK0; MMCM limits of UltraScale+ (open) |
| Pixel clock | MMCM `clk_hdmi` on FCLK0: 74.25 MHz (`clk_hdmi`) and 371.25 MHz (5×, serialiser) | same, serialiser for UltraScale+ (open) |
| Reset | `proc_sys_reset` in the FCLK0 domain (`ext_reset_in` = `FCLK_RESET0_N`, `dcm_locked` = `clk_core/locked`), `peripheral_aresetn` → `mister/aresetn`; the frame synchronises it into the master clock | `pl_resetn0` (open) |
| Clock groups | XDC block `CONTRACT` (master with `clk_master_gate` and the derived core clocks, 100, 50, HDMI, audio asynchronous); `core.xdc` is read before it | same |
| Video | TMDS directly on the pins (7 series `TMDS_33`): `rgb2dvi` (`VIDEO=dvi`) or `hdmi_out` from `firmware/common/ip/hdmi-tx` (`VIDEO=hdmi`, audio in HDMI) | no `TMDS_33` on UltraScale+: transmitter chip or GTH (open); a transmitter chip gets parallel RGB + I2S from `mister_zynq` |
| Audio | I2S from `mister_zynq` to the codec; codec init as a root FS file (`MISTER_ROOTFS_FILES`, Zybo `ssm2603-init.sh` via PS I2C0 on EMIO), mute pin permanently off | codec of the chosen board (open) |
| Buttons/LEDs | `btn[0]` OSD, `btn[1]` user, `sw` = 0; LEDs: DE10-Nano LED 0, 2, 4 and `status_err` | board choice |
| SD card | PS SD0 under Linux, `/media/fat` as on MiSTer; no PL pins | SD controller of the board (open) |
