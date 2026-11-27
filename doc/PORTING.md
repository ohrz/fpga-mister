# Porting: how to bring another MiSTer core to a Zynq board

This guide is for the next core (for example NES, Gameboy, TurboGrafx16, §5.3) and for the next board. It gives
these items:

- **What is already checked and is used again without changes.**
- The sequence in which you port a core.
- The location of each change.

`doc/ARCHITECTURE.md` describes how the building blocks work internally. `firmware/common/mister/README.md`
describes the directories and the conventions.

Principle: **The core and `sys/` stay unchanged.** The port replaces only the parts that do not exist on the Zynq:

- Cyclone V hard blocks.
- Quartus PLLs.
- Intel megafunctions.
- The SDRAM chip.

The replacements are building blocks that are the same for each core. A **profile**
(`firmware/common/mister/cores/<core>/`) describes what a core needs. The shared code does not describe it.

## 1. Layers

```
Core (emu, unchanged)              ← profile: exclusions, replacement files (PLL), rules, macros
  sys/ of the core (unchanged)     ← prepare_sources.py: SYS_RULES, sys_top.v → sys_top_zynq.sv (hard blocks as ports)
    mister_zynq (VHDL, module reference, board- and core-neutral; generics from the profile)
      hps_bus_axi, stage C SDRAM chain, avl_axi_bridge, core_clock_stall, perf_counters
        board block design (generator Tcl <p>_mister.tcl): PS, MMCMs, HDMI (rgb2dvi / hdmi_out from firmware/common/ip/hdmi-tx), codec, pins
```

A new core touches only the top layer (its profile). A new board touches only the bottom layer (§7). All layers
between them are used again without changes. If one of them changes, the change applies to all cores and needs a
testbench.

## 2. Toolkit: what is checked

Types of evidence:

- **Sim** = GHDL testbench with mutation test (`make test`).
- **Timing** = Vivado after route.
- **HW** = runs on the Zybo Z7-20 with at least one core.

| Replaces (DE10-Nano / Quartus) | Building block (file) | Use in a new core | Evidence | Limits |
|---|---|---|---|---|
| HPS GPO/GPI (`h2f_gp`) | `hdl/hps_bus_axi.vhd` in `mister_zynq` | automatic | Sim, HW | – |
| SDRAM chip on `SDRAM_*` | stage C: `sdram_emu` → `sdram_region` → `sdram_bram` / `sdram_cache` → `avl_axi_bridge` → HP0 | generics in the profile (§3.4) | Sim (unit and system test `sdram_stagec_tb`), Timing, HW (MSX 59.92 Hz = nominal) | one SDRAM (no `SDRAM2_*`); controller gives commands on the rising edge; burst 1/2/4/8 |
| Core clock from the Quartus PLL | `core_clock_stall` (BUFGCE + pacer) in `mister_zynq` + replacement `pll.vhd` in the profile | pattern `cores/_template/pll.vhd` with `hdl/clk_pulse_div.vhd` (§3.3) | Sim, Timing, HW (MSX 1/4 divider, menu 1/1) | integer divisors of the fastest clock, phase 0 |
| Falling edge of a derived clock | mid clock `clk_mid` of `hdl/clk_pulse_div.vhd` (`G_MID` = `G_DIV`/2) + rules `falling_edge_to`, `add_port`, `connect_port` in `rules.py` | §3.3 | Sim (`clk_pulse_div_tb`, 7 mutants), rules: unit tests (16 mutants), Gameboy dry run; OOC probe; SNES (own chain, patch) HW | `G_DIV` even (odd: half a master period early); check every consumer of the shifted signals |
| `sysmem` `vbuf` (frame buffer of `ascal`) | `avl_axi_bridge` → HP1 | automatic | Sim, HW | `ascal` with 64 bit (`N_DW` 64); the bridge splits Avalon bursts of 1…255 beats into AXI3 bursts ≤ 16 beats, no 4 KB crossing (Sim) |
| SDRAM controller with handshake (stage D) | replacement file in the profile with Avalon master → emu port `COREMEM_*` (rules) → `ZYNQ_coremem_*` → `avl_axi_bridge` → HP3 | profile `G_COREMEM 1`, `MISTER_ZYNQ_COREMEM`, `G_FREE_CLK 1` (§3.3); pattern `cores/n64/sdram.vhd` + `rules.py` | Sim (`n64_sdram_tb` against a model of the original, 10/11 mutants; `mister_zynq_free_tb` HP3, 5 mutants), block design check passes, RTL elaboration N64 | one replacement per core; one beat per access, no cache |
| Picture without `ascal` (direct video) | `MISTER_DEBUG_NOHDMI`: `HDMI_TX_*` on `CLK_VIDEO` from the VGA branch, DE of the picture (`prepare_sources.py`), `video_pll` (PLLE2) → `vid_clk`/`vid_clk_ser` → transmitter | profile `G_DIRECT_VIDEO 1`, `G_DV_CLKIN_PS`, `G_DV_MULT` (§3.4); the core must deliver 31 kHz (N64: `video_mixer` with scandoubler via rule) | Sim (`video_pll_tb` 7/8 mutants, the survivor is the timeout reset: the PLL model locks even without it; `mister_zynq_free_tb` 4 mutants), RTL elaboration and block design N64 | no CEA mode (N64 1547 × 525 at 48.68 MHz, VIC 0): sink untested; frame rate = that of the core |
| `sysmem` `ram1` (`DDRAM_*` of the core) | `avl_axi_bridge` on `DDRAM_CLK` → `m_axi_ddram` → HP2 | profile `G_DDRAM 1` (§3.4) | Sim (`mister_zynq_tb`: burst across 4 KB, byte enables, quiesce, 3 mutants), block design check passes (MSX with forced `G_DDRAM`) | free-running `DDRAM_CLK` only (stage D); open with a gated core clock (stage C); error responses from HP2 untested |
| PLL reprogramming `pll_cfg_hdmi` | `mister_zynq` only acknowledges | automatic | HW | fixed pixel clock 74.25 MHz: `video_mode=0` (720p60) |
| `pll_audio` | MMCM `clk_core` (24.5734 MHz) | automatic | HW | −110 ppm |
| `audio_out` → I2S → codec | SSM2603 via `ssm2603.service` | automatic | HW (headphones) | 48 kHz, 16 bit (`hdmi_audio_96k=0`) |
| HDMI TX (ADV7513 on the DE10) | `rgb2dvi` (DVI) or `hdmi_out` (HDMI with audio; `firmware/common/ip/hdmi-tx`) | `VIDEO=dvi|hdmi` (argument of the board generator) | `hdmi_out`: Sim (symbol level), Timing, HW (picture + audio on the HDMI output) | 7 series (OSERDESE2, TMDS_33 direct); fixed 720p60 (VIC 4), 48 kHz stereo |
| `altsyncram` | `hdl/intel/altsyncram.vhd` | automatic (same name) | Sim, HW (`sys/sd_card.sv`) | subset: dual port/single port, unregistered, mixed widths; **no** byte enables, clock enables, init files, output registers (an assertion aborts) |
| `altddio_out` | `hdl/intel/altddio_out.vhd` | automatic | Sim | behavioral (LUT); on a pin, use ODDR at the top of the design |
| Core change without bus hang | quiesce (`hps_bus_axi` CTRL/STATUS + Main patch 0004) | automatic | HW | – |
| `ascal` downscaler bottleneck | macro `MISTER_ZYNQ_NO_DOWNSCALE` | in the profile, if the picture is never larger than 720p | Timing, HW | – |
| Area at the LUT limit | macros `MISTER_ZYNQ_SIMPLE_AUDIO` (`hdl/audio_i2s_simple.vhd` instead of `audio_out`: core audio directly as I2S to HDMI and codec, 48 kHz, without filter/volume/S/PDIF, ≈ 1.6k LUT less), `MISTER_ZYNQ_NO_AUDIO` (no audio) and `MISTER_ZYNQ_NO_DIRECT_VIDEO` (`direct_video` = 0: no VGA OSD and no direct video path) | in the profile (`core_defines`) | Sim (`audio_i2s_simple_tb` against `i2s_rx`), Timing, HW (N64) | no audio filter/OSD volume, or no `direct_video=1` |

Tools:

- `scripts/core_survey.py` (inventory, §3.1) and `scripts/synth_core_ooc.tcl` (OOC synthesis).
- On the board: `tools/fps.py` (frame rate), `tools/perf.py` (stage C counters), `tools/vkbd.py` (keyboard).
- On the board: `tools/vpad.py` (gamepad), `tools/grab_frame.sh` (input picture of `ascal`), `tools/pair-ds5.sh`
  (Bluetooth controller).

## 3. Port a core, step by step

Each step has a result that you can check. Do not continue before you have this result.

### 3.0 Stages

The stages are the rows of `cores/<core>/STATUS.md` and the columns of the matrix in `README.md` (`make status`,
`scripts/status.py`). Each row gives these items:

- The evidence (HW, Timing, OOC, Sim, Script, FAIL, BLOCKED, NOT RUN, open).
- The commit.
- The date of the measurement.

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
| `extras` | core-specific features (MSX game change, SNES MSU-1, …) | core `README.md` |

§7 gives the board stages of `firmware/targets/<board>/STATUS.md`.

### 3.1 Checkout and inventory

1. Add a line to `firmware/common/checkouts.txt` (name, URL, branch, **fixed commit**). Then run `make setup` of a
   flow.
2. Make the inventory. This command only reads and does not change a file:

       firmware/common/mister/scripts/core_survey.py _Checkouts/<Core>_MiSTer _Checkouts/Template_MiSTer

   The report lists these items:
   - Files.
   - Intel megafunctions (with the replacement file or "missing").
   - PLL outputs.
   - Used `emu` ports (used vs. only tied off, `.*` instances).
   - `.qsf` macros.
   - Suspicious constructs with file:line.
   - The distance of `sys/` from the template.

   Result on MSX and on the menu: the report finds exactly the places that their profiles handle. Type errors are
   the exception, for example the vector width in `t80.vhd`. Only Vivado reports them. Result on SNES and PSX
   against a manual inventory (§5.1): the report found each megafunction, `pll_cfg`, the library `mem` and the
   bursts > 16 beats. The report does not find these items:
   - Procedurally assigned `output` nets (Vivado `Synth 8-2577`).
   - The detailed settings of a megafunction (clock enable, `init_file` value). For these, read the instance.
3. Assess the core before the build:
   - **Missing megafunction** (table §2, "missing"): Write a new replacement in `hdl/intel/` with a testbench. Use
     the same name, generics and ports. Reject unsupported settings with an assertion. Never write it again inside
     the core.
   - **`DDRAM_*` used, `SDRAM2_*` used**: This is a gap (§5). Close it first.
   - **Size**: Do an OOC synthesis (§3.6) against the FPGA of the board. XC7Z020: 53,200 LUT, 140 BRAM36, 220 DSP.
     The frame (`sys/` with `ascal`, OSD, `audio_out`) + stage C + HDMI already use 11,200 LUT, 26 BRAM36 and
     35 DSP. This value is for `zybo-z7-20_menu_hdmi` after place, with the tiny menu core. The MSX design uses
     18,500 LUT and 67.5 BRAM36 (32 of them for the VRAM region). Thus ≈ 40,000 LUT and 110 BRAM36 are free for the
     core, minus the BRAM regions.

**Lint** (section 7 of the report): The lint finds problems in the source, with file:line. Without the lint, only
timing or hardware shows these problems. With `--profile cores/<core>`, the lint counts what the profile already
handles. Without this option, it uses the profile with a matching `core_name`. With `--strict`, it exits with code 1
on errors.

| Check | Error | Warning / info |
|---|---|---|
| falling edge (`falling_edge`, `negedge`, `not CLK` on a clock port), traced through the instances up to the PLL output | on a derived clock, file not touched by the profile | profile touches the file (patch or word in `rules.py`), clock unknown / fastest clock: info |
| core clocks from the PLL | – | more than 3: BUFGCE cascade |
| `.sdc` path exceptions vs. those in `core.xdc` | – | more in the `.sdc`; `create_generated_clock -invert` |
| Intel primitives | without replacement | replacement in `hdl/intel/`, via `core_add` or only in excluded files: info; only in touched files: warning |
| unconnected VHDL inputs with default in Verilog instances | – | count (info), `prepare_sources.py` connects them |

Status: SNES without profile has 13 errors. These are exactly the places that we found during the port. SNES with
profile has 0 errors and 12 warnings. MSX and menu: 0/0. Put the BRAM tiles of the first successful OOC synthesis
into the profile as `set core_expect_bram <n>`. `synth_core_ooc.tcl --profile cores/<core>/core.tcl` (or
`--expect-bram <n>`) aborts on a deviation of more than 10 %. Such a deviation shows silently removed RAMs.

### 3.2 Make the sources readable for Vivado

Vivado reports only the first failing file in each run. The OOC synthesis of the core (§3.6) gives fast
iterations. Each change belongs in exactly one location. The table gives the locations in this order:

| Case | Location | Example |
|---|---|---|
| Intel building block | replacement in `hdl/intel/` (for all cores) | `altsyncram`, `altddio_out` |
| whole module unsuitable (PLL, `lcell` ring, SDRAM controller in stage D) | replacement file in the profile: `core_exclude` + `core_add`, same module name and same ports | `cores/msx/pll.vhd`, `cores/menu/lfsr.vhd` |
| mechanical Quartus/Vivado difference (syntax, visibility, port kind), countable | rule in `cores/<core>/rules.py` with expected hit count | `t80-ioq-mask`, `sdram-dq-*` |
| the same difference in `sys/` | `SYS_RULES` in `prepare_sources.py` (for all cores) | `sys-hps-io-ps2-scope` |
| behavioral change | patch `cores/<core>/patches/NNNN-<topic>.patch` with header (Main_MiSTer: `patches/Main_MiSTer/`); new logic as a separate VHDL file in the profile with testbench, the patch only wires it in | Main_MiSTer 0001–0005; MSX_MiSTer 0001 + `cores/msx/scc_rom_hide.vhd` |
| unused file that Vivado does not parse | `core_exclude` | MSX `*/VM2413/*` |

Known differences (a rule or a replacement solves each of them):
- VHDL `label : work.ent` without `entity` → generic rule `vhdl-direct-instantiation`. It runs for each core. Name it
  in the profile with an expected count.
- VHDL `when … else null;` → `vhdl_null_waveform`. Use it only after you check each occurrence (the latch becomes 0).
- Vectors of unequal length in logic operations → `literal` rule at that location.
- Verilog `inout reg`, outputs assigned in `always` without `reg`, declarations inside `generate` used outside →
  rule.
- `lcell` rings (combinational loops) → clocked replacement file.
- Verilog string passed to a VHDL `boolean` (`"false"` becomes `true`) → 0/1. `prepare_sources.py` checks this for
  `ascal`.
- `.qsf` macros (`VERILOG_MACRO`) → `core_defines`. They can change `sys/` (menu: `MENU_CORE`).
- `` `include `` targets → `mister_core_add` adds them as Verilog headers (automatic).
- Automatic in `prepare_sources.py` (each core, count in the log):
  - It writes the port names from Verilog to VHDL entities in the spelling of the entity.
  - It connects unconnected VHDL inputs with default to the default. Otherwise Vivado ties them to 0.
  - It puts the entities of a VHDL file before their use.
  - It maps Intel libraries and megafunction instances to the replacements in `work`.
  - It changes `.mif` → `.mem` with absolute path.
- Use before declaration (Verilog) → `declarations_first` in the profile, for each file with an expected count.

Each rule has its **expected hit count**. If the upstream code changes, `prepare_sources.py` aborts. It does not
silently build something different. `make test` (step 7) checks all profiles against their pin.

### 3.3 Clocks: replace the core PLL

Pattern (MSX, menu, checked on HW):

- The frame drives the **gated master clock** onto `CLK_50M`.
- The replacement `pll.vhd` gives it out as the fastest core clock.
- The replacement makes each slower clock as a BUFGCE on the same clock, with a counter in the same domain
  (`cores/_template/pll.vhd`).
- `core.xdc` has one `create_generated_clock` line for each derived clock (`cores/_template/core.xdc`).

Thus the phase relation of all core clocks stays identical after each stall. Each BUFGCE is one element of a BUFG
cascade. The cascade starts at `core_buf`, which is on an MMCM output without BUFG. Each element needs an adjacent
BUFGCTRL site. `core_buf` can drive two clocks directly, and each of them can drive one more (SNES: four BUFGs,
placed). The falling edges of a derived clock have only 5.6 ns. A mid clock replaces them. The mid clock comes from
the master pulses at which the original clock falls (SNES `clk_sys_mid`, patch 0002). The generic solution is
`clk_pulse_div` with rules (below).
If the core has an `.sdc`, copy its `set_max_delay`/`set_false_path` to `core.xdc`. Convert the values to the master
period.

Select the master clock:
1. Find the fastest core clock *f*<sub>nom</sub> (from §3.1, PLL outputs). Set the master clock *f*<sub>m</sub> a
   few percent above it. *f*<sub>nom</sub>/*f*<sub>m</sub> = `G_PACE_NUM/G_PACE_DEN` must be a small exact fraction
   (MSX: 85.909 MHz = 90.0 MHz · 21/22).
2. Set `core_master_mhz`, run `make create` and read the line `INFO: clk_core clk_out2 …`. The Clocking Wizard
   shares one VCO between audio (24.576 MHz, fractional only on CLKOUT0), master clock and 50 MHz. Thus it does not
   always get the requested value (menu: 85 → 84.79 MHz). The fraction applies to the **actual** value.
3. The margin 1 − NUM/DEN must be at least the stall time from cache misses (MSX: 4.5 % margin, 0.8 % stall).
   Set `G_PACE_BUCKET` 1024 if sequences of misses stall the core for a longer time. Measure with `tools/perf.py`.
   Some cores change their clock at runtime (`pll_cfg`, SNES PAL). For them, a second ratio
   `G_PACE_NUM_ALT/G_PACE_DEN_ALT` is available for the same master clock. Example: SNES PAL 85.125 MHz =
   90 MHz · 227/240, −6 ppm. The replacement
   `pll_cfg` of the profile reports the selection through the `emu` port `ZYNQ_PACE_ALT` (§5).
4. Timing: the master clock is the clock of the core. The core must meet it (OOC synthesis with the master clock).

If the pattern does not fit:
- **Non-integer ratios** between core clocks (for example 33.8688 and 53.69 MHz): Two separate master clocks cannot
  stay phase-locked with a common stall. There are two options:
  - All clocks as edge sequences of a common faster master, with one pacer for each clock (new building block, Sim
    first).
  - Stage D (controller replacement, no stall).
- **Phase-shifted outputs** (usually only `SDRAM_CLK`): The pin emulator removes them. Check other outputs one by
  one.
- **Free-running core clocks (stage D, `G_FREE_CLK 1`)**, if the core waits for its memories through a handshake
  (N64):
  - `mister_zynq` itself drives `clk_master` (free-running, BUFG) onto `CLK_50M`, without pacer, BUFGCE and
    stage C. `SDRAM_*` stays unconnected, and HP0 is idle.
  - The replacement `pll.vhd` then puts an MMCM on `CLK_50M` (`core_master_mhz` = input clock of the original PLL,
    N64: 50.0, `cores/n64/pll.vhd`). Its outputs are derived clocks of `clk_master`. Thus they are in the
    asynchronous group of `clk_master` in the board constraints. An MMCM on `clk_50` is synchronous to the frame.
  - The memories of the core then go through stage D (controller replacement, `G_COREMEM`, §3.4) and `G_DDRAM`.
    Sim: `mister_zynq_free_tb` (5 mutants).
  - The core then runs from the PL configuration on, also before its MMCM locks. At the start, `pll_reset` holds it
    in reset for 1.3 ms. A replacement controller that uses `locked`/`init` must synchronize this signal to its own
    clock. It must not expect a reset that does not exist. Example: PSX `sdram.vhd` accepted only half of the first
    CPU fetch on the asynchronous LOCKED edge. Without a reset, it hung forever. N64 `sdram.vhd` synchronizes in the
    same way.
- **Falling edges of a derived clock** (lint error "derived clock" from `core_survey.py`): The high time is that of
  the master clock (5.6 ns at 90 MHz). The building block is `clk_pulse_div` with `G_MID => G_DIV/2` in the
  replacement `pll`. It gives the mid clock as an additional port `outclk_<n>`. The mid clock is the master pulse at
  which the DE10 clock falls. `rules.py` connects it and moves the edges, each rule with an expected count:
  ```python
  ("mid-net",   "Gameboy.sv", literal("wire clk_sys, clk_ram;", "wire clk_sys, clk_ram;\nwire clk_sys_mid;"), 1),
  ("mid-pll",   "Gameboy.sv", literal("\t.outclk_1(clk_sys),\n", "\t.outclk_1(clk_sys),\n\t.outclk_2(clk_sys_mid),\n"), 1),
  ("mid-gb",    "Gameboy.sv", connect_port("gb", "clk_sys_mid", "clk_sys_mid"), 1),
  ("mid-port",  "rtl/gb.v",   add_port("gb", "input clk_sys_mid"), 1),
  ("mid-edges", "rtl/gb.v",   falling_edge_to("clk_sys", "clk_sys_mid"), 1),
  ```
  `falling_edge_to(clock, mid)`: Verilog `negedge clock` and `.p(~clock)`, VHDL `falling_edge(clock)` (with
  sensitivity list) and `=> not clock`. `add_port(module, decl)`: Verilog ANSI/non-ANSI, VHDL entity.
  `connect_port(module, port, net)`: named connections of each instance. The sequence of all edges stays that of
  the DE10, also during a stall. Move all falling edges of the same clock. This includes the edges in other files
  and on RAM ports (`clock => not CLK`). Example: SNES CX4 writes on the falling edge with enable from `CE`. An edge
  that stays on the clock keeps 5.6 ns. After the change, run the lint again (`core_survey.py --profile`).
  Gameboy (pin `f6796f3`) as dry run: 11 rules, each with count 1. Generated clocks: see the header of
  `clk_pulse_div.vhd` and the pattern `*div_buf/O` (the generate label is a part of the name). A logic divider with
  50 % duty cycle instead of a mid clock needs no rules. But it causes ≈ 3 ns of skew between the master clock and
  the derived clock.
- **PLL reprogramming** by the core (`altera_pll_reconfig`, PAL/NTSC change): gap (§5).

### 3.4 SDRAM: derive the profile generics from the controller of the core

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

Checks:
- Read the commands of the controller (ACT/READ/WRITE/PRE/REF/MRS, burst, CL from the mode register). The SDRAM
  emulator takes CL from the MRS.
- Write down the address mapping in the profile header, as for MSX.
- `sdram_stagec_tb` covers the behavior for each controller of this type.
- The first hardware metric is the frame rate (= nominal?).

### 3.5 Create the profile

1. Run `cp -r firmware/common/mister/cores/_template firmware/common/mister/cores/<core>`. Replace all `<…>`. For
   each number, give file:line of the source (header comment). All files of a core are in this directory:
   - `README.md` (entry point).
   - `STATUS.md` (evidence for each board and stage, `make status`).
   - The profile and the replacement files.
   - `patches/` (patches of the core checkout, `prepare_sources.py --patch-dirs` shows the mapping).
   - `hwtest.cfg`.
2. You do not need a design wrapper. `<p>_mister.tcl` makes the design for each profile:
   `PLATFORM=<p> FLOW=vivado CORE=<core> [VIDEO=hdmi] make create build` (design `<p>_<core>[_hdmi]`).
3. For the MiSTer package: add the entry `<p>_<core>$(ZYBO_DESIGN_SUFFIX):<Corename>` to `MISTER_CORES` of the
   board profile. The `.rbf` name is the name that Main uses to find the core in `_Computer/` or in its folder.
4. Run `make test`. Step 7 checks the profile and the rules against the pin.

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

Run Vivado only inside `systemd-run --user --scope -p MemoryMax=… -p MemorySwapMax=0`. Read these items:

- The critical warnings (the PSU warnings about the DQS delay come from the board preset).
- WNS/WHS.
- The clock list of `make create`.
- The generic values of a VHDL entity in the synth DCP (`get_cells`).

The critical path is usually in the core itself or at the `ascal` input on `CLK_VIDEO`. In the second case, use
`MISTER_ZYNQ_NO_DOWNSCALE` if the picture is never larger than 720p.

All designs in one run (overnight, `scripts/build_matrix.py`): `make build-matrix [BOARDS=…] [CORES=…] [UPDATE=1]`.
For each board, it builds these cores as `_hdmi` designs, one after the other:

- The cores from `MISTER_CORES`.
- Each core whose `STATUS.md` has a `timing` row for the board (not BLOCKED).

To add a new core, add a row `| <board> | timing | NOT RUN | | | |`. The columns are Board | Stage | Evidence
| Commit | Date | Measurement / Remark. Each build runs in `systemd-run … MemoryMax=24G` (`MEM=`). After the builds,
the script reads the `impl_1` reports (WNS, WHS, routing errors, LUT, BRAM tiles). It writes the logs,
`results.json` and the proposed `timing` rows to `firmware/build/logs/build_matrix/<time>/`. `UPDATE=1` writes the
rows into `STATUS.md`:

- The evidence is Timing or FAIL.
- Commit = HEAD at the start. The tree under `firmware/` must be clean.
- `-` where there is no git history.
- Commit the change by hand.

`REPORT_ONLY=1` evaluates the existing builds. `DRY_RUN=1` shows the calls.

A run without errors does not prove that Vivado built everything. Vivado silently removes logic with unconnected or
constant inputs (SNES: VRAM, ARAM, BSRAM and SA1). Thus, after the first OOC synthesis, do these steps:

1. Count the BRAM for each instance in the checkpoint (`get_cells -hier -filter {REF_NAME =~ RAMB*}`). Compare the
   count with the inventory.
2. Do the same for the LUT of the large modules (`report_utilization -hierarchical`).
3. If something is missing, keep the instance with `DONT_TOUCH`. Then query the drivers of its pins.

### 3.7 Hardware bring-up

Sequence (each stage with evidence, tools §2):
1. Load the core without a change of the SD card. Copy `.bit.bin` to `/tmp` on the board. Put a `mount --bind`
   over `/media/fat/_Computer/<Core>.rbf`. Use `load_core` through `/dev/MiSTer_cmd`. Write the content with
   `cat >`, not with `mv`.
2. Check with `devmem2`: ID register 0x40000008 = `0x5A4D5354`, STATUS 0x4000000C = 0.
3. Picture: on the HDMI output, or `tools/grab_frame.sh` (input buffer of `ascal`).
4. Frame rate against the nominal value of the original: `tools/fps.py 60`. Measure for at least 60 s, because
   shorter windows have a coarse quantization. If the frame rate deviates, use `tools/perf.py` (stall share, misses,
   bucket full). Then adjust `G_PACE_*`, `G_CACHE_*` and the regions.
5. Audio: HDMI (HDMI design) and headphones.
6. Input: keyboard, gamepad or `tools/vkbd.py keys F12` (OSD), media load through the OSD, core change menu ↔ core
   (quiesce).
7. When the core is on the card, create `cores/<core>/hwtest.cfg`. It contains the game, the input sequence for
   `vpad.py` or `vkbd.py text`, and the expected frame rate. Then run `make hwtest CORE=<core> COMMIT=<build commit>`
   (`tools/hwtest.py`). It loads the core with the game and plays back the input. Then it checks these items:
   - Load.
   - Speed (frame rate ±0.2 %, edges ≥ pacer share, no warning from `perf.py`).

   Put the printed rows into `STATUS.md`. Do this again after each change to the frame or to the profile.
8. Only then install the core permanently on the card (`FLOW=mister make package`, `VIDEO_TX`). Keep a backup of
   the old files.

### 3.8 Wrap-up

- Write all values and sources into the profile header. Add the core to `doc/ARCHITECTURE.md` §3.6 (table of
  profiles).
- Write new findings (rules, pitfalls, measurements) into the `README.md`/`STATUS.md` of the core. If they apply to
  other cores, also write them into `doc/PORTING.md`.
- Add new shared building blocks only with a testbench and a mutation test. Give each type of evidence separately.
- Replacements for Intel IP (`hdl/intel/`): Also synthesize in Vivado each parameter set that a core uses, one by
  one. Check the mapping (RAMB instead of LUT/FF, DSP). GHDL accepts templates that Vivado rejects (`altsyncram`
  with unequal port widths, `Synth 8-2913`).

## 4. Maintain rules, patches and replacement files

- Rules are tied to the **pin** (expected hit count). For a new pin of a checkout, `make test` shows each count that
  deviates. Adapt or remove the rule. Never change the count before you look at the location.
- Patches (`cores/<core>/patches/NNNN-<topic>.patch`, Main_MiSTer `patches/Main_MiSTer/`) have a header before the
  diff (Title, Project with pin, Author, Company, Created, Description: *why*). The flow applies them in sort order.
  `make test` (step 5) applies them to an export of the pin. It checks that the copy from `prepare_sources.py`
  contains them. For a new pin, rebase the patches and adjust the Project line.
- The header of a replacement file gives these items:
  - **Which file** it replaces.
  - Which properties of the original it keeps (name, ports, clocks, behavior).
  - The conditions for which this is true.
- Never change `_Checkouts/`. Builds use `firmware/build/src/<checkout>`. `prepare_sources.py` makes this directory
  again on each `make create`.

## 5. Open gaps for the next cores

Status 2026-11-01. The column "SNES/PSX" refers to §5.1.

| Gap | Affects | SNES/PSX | Proposal |
|---|---|---|---|
| `DDRAM_*` (`sysmem` `ram1`) with gated core clock | menu console, many arcade cores, savestates (stage C cores) | SNES: MSU-1, savestates; PSX: **mandatory** (VRAM) | HP2 with free-running `DDRAM_CLK` exists (`G_DDRAM`, §3.4). Still missing for stage C: bridge on the master clock with `ce`, or CDC FIFO from the gated to a free-running clock |
| DDR allocation: SDRAM image `G_SDRAM_BASE` 0x3800_0000 lies inside the cores' DDR window (0x2000_0000–0x3FFF_FFFF, physically addressed as on the DE10) | every core with `DDRAM_*` | SNES MSU 0x2060_0000–0x3F7F_FFFF: **overlap**; PSX only 0x3000_0000–0x306F_FFFF and savestates 0x3E00_0000–0x3EFF_FFFF, image (24 MB) from 0x3800_0000 free | move the image below 0x2000_0000 (extend the device tree reservation downwards by 32 MB, Linux loses 32 MB) or a free area per core in the profile |
| second SDRAM (`SDRAM2_*`, `MISTER_DUAL_SDRAM`) | cores with two SDRAM chips | PSX only in the DualSDRAM build (SPU) | standard build without; otherwise a second `sdram_emu` instance with its own region/cache, shared stall |
| PLL reprogramming by the core (`pll_cfg` in `emu`, Altera register values) | cores with PAL/NTSC or clock change | SNES done (PAL, HW); PSX done for NTSC/PAL (`cores/psx/pll_cfg.vhd`), fast forward off | replacement `pll_cfg` in the profile decodes the written K value (SNES `cores/snes/pll_cfg.vhd`) and sets `reconfig_to_pll[0]`; a rule brings it out as `emu` port `ZYNQ_PACE_ALT` (`MISTER_ZYNQ_PACE_ALT`), `core_clock_stall` then uses `G_PACE_NUM_ALT/G_PACE_DEN_ALT`. Two fixed ratios; more ratios (PSX fast-forward) need registers |
| clocks that are not integer divisors of the fastest clock | cores with for example 1×/2×/3× | PSX 33.87/67.74/101.61 MHz (phase lock required) | master clock = LCM (6 × 33.8688 = 203.2 MHz) with dividers 2/3/6; timing at -1 open |
| falling edge of derived clocks (`falling_edge`, `clock0 => not CLK`) | cores with half-clock logic | SNES solved (`clk_sys_mid`, patch 0002); generic: `clk_pulse_div` + rules (§3.3); PSX unchecked | mid clock in the replacement `pll`, rules instead of a patch; per core only after checking every consumer (CE on falling edge) |
| missing megafunctions | per core (`core_survey.py` "missing") | SNES: `altdpram`, `lpm_mult` done, `dcfifo` as profile replacement (`msu_fifo`); `scfifo`, `lpm_divide` only in the SPC7110 (disabled); PSX: `altdpram` | replacement in `hdl/intel/` with testbench (FIFO with show-ahead, pipelined divider) |
| VHDL library other than `work` | cores with `library x;` | PSX `mem` (37 bindings, mixed with `work.`) | solved per profile: rules `library mem;` → comment, `mem.` → `work.` (N64 `cores/n64/rules.py`, 32 + 47 hits); `core_survey.py` reports a library without a rule as a lint error |
| VHDL-2008 according to `.qsf` (`VHDL_INPUT_VERSION`) | cores with 2008 syntax | PSX | done: `set core_vhdl_std 2008` in the profile, `mister_core_add` sets the file type of the VHDL files of the core `.qip`, `synth_core_ooc.tcl` reads them as VHDL 2008 with `--profile` or `--vhdl2008` (N64) |
| `MISTER_FB` (ascal reads the core's frame buffer from DDR) | cores with their own frame memory | PSX | ascal path via HP1 exists, `FB_*` path untested |
| fixed video mode 720p60 | all (`video_mode=0`) | – | Clocking Wizard with DRP, `hdmi-tx` with VIC selectable at runtime |
| `hdmi_out` 7 series only | ZynqMP boards | – | own serializer (OSERDESE3/GTH) in `firmware/common/ip/hdmi-tx` |

### 5.1 Requirements of SNES and PSX

Both cores are ported now (current state: `cores/snes/STATUS.md`, `cores/psx/STATUS.md`). The notes below are the
inventory and the assessments from before and during the port (SNES_MiSTer `bdcd33c`, PSX_MiSTer `cd17b5a`,
2026-10-29 to 2026-10-31). We keep them because they show what to look for in the next core. "(estimated)" marks
derived numbers.

Already checked: `prepare_sources.py` without core rules runs through on both trees (all `SYS_RULES` with expected
hits, `sys_top_zynq.sv` with 11 replaced blocks). This is true although their `sys/` is older than the template pin
(without `LFB_*`, `FFB`) and SNES uses LF instead of CRLF. The generic rule `vhdl-direct-instantiation` hits SNES
`rtl/bram.vhd` twice.

**SNES** (a profile similar to MSX):

- Clocks: PLL 85.909 / 42.955 (phase −4365 ps) / 21.477 MHz = 4:2:1. This is the MSX pattern (master 90 MHz, pacer
  21/22, dividers 2 and 4). The phase of the video clock is not important behind `ascal` (estimated). SDC:
  `set_max_delay` 20/23 ns between `main`/`hps_io` and `sdram` → as `set_max_delay`/multicycle in `core.xdc`.
- PAL/NTSC through `pll_cfg` (K value) → gap PLL reprogramming.
- Memory: `SDRAM_*` (ROM ≤ 16 MB, WRAM) through stage C. `DDRAM_*` is only for MSU-1 and savestates (bursts 1–2).
  Thus normal games run without DDRAM (estimated).
- Size (measured 2026-10-30, synth for each module): `emu` with all chips ≈ 37,000 LUT, with the frame ≈ 48,200 of
  53,200 (**90.5 %**, placement doubtful). SPC7110 alone uses 7010 LUT. Without it: ≈ 41,200 (77 %). Other chips:
  CX4 3316, SA1 3419, GSU 2937, BSX 602, DSPn 796, SDD1 825 LUT.
- BRAM (counted): BSRAM 256 KB = 64 RAMB36, VRAM 2× 32 KB = 16, ARAM 64 KB = 16, DSPn ROMs 10, rest ≈ 31. Thus
  `emu` ≈ 128, with the frame ≈ 154 of 140, **too many**. With `BSRAM_BITS` 17 (128 KB, `SNES.sv`): ≈ 122. Else
  put BSRAM in DDR (stage C region). It is not checked yet if 128 KB is enough for all games.
- Proposed profile: all chips except SPC7110 (`USE_SPC7110` 0 in `rtl/main.v`), `BSRAM_BITS` 17. MSU-1 only with
  DDRAM (while MSU-1 is disabled, this saves ≈ 1100 LUT of `msu_audio`).
- Vivado pitfalls, solved since 2026-10-30:
  - Generic steps in `prepare_sources.py`: port name spelling (`main.v` 354 connections), unconnected VHDL inputs
    with default (43), entity order in `bram.vhd`, `.mif`.
  - Rules in `cores/snes/rules.py` (24): use before declaration, `.do(`, procedural assignment to `wire`/`output`,
    unequal operand lengths.
  - Patch `cores/snes/patches/0001`: GSU with both clock edges.
  - Replacement file in the profile: `msu_fifo`.
- Measured with the profile (OOC `emu`, 2026-10-30): 31,409 LUT, 97.5 BRAM tiles (VRAM 16, ARAM 16, BSRAM 32
  RAMB36), 23 DSP. Block design `zybo-z7-20_snes_hdmi`: 41,322 LUT, 119.5 BRAM tiles, WNS +0.215 ns, WHS
  +0.010 ns. These values are after we moved the SDC values into `core.xdc` and used `clk_sys_mid` instead of
  falling edges.
- Megafunctions:
  - `altsyncram` with clock enable and `.mif` (DSPn, CX4, BSX).
  - `altdpram` MLAB.
  - `scfifo`.
  - `dcfifo` (MSU, both sides on the same clock → sync FIFO).
  - `lpm_mult`.
  - `lpm_divide` (SA1, SPC7110).
- Vivado:
  - `inout reg` in `rtl/sdram.sv` (menu rules `sdram-dq-*` as template).
  - Procedural assignment to `output` nets in 6 modules (among them `sdram.sv` `SDRAM_nCS`, `SNES.sv`
    `USER_OUT`) → rules `output reg`.
  - VHDL instances from Verilog with positional generics and different port name case (not checked).
- Services: UART (MIDI), `hps_ext` (MSU), backup RAM through `sd_*`, `video_mixer` with HQ2x.
- Test ROM: It is not in the repository. Git ignores `roms/`, and users must supply their own legally obtained
  images. The game is a PAL Super FX (GSU-2) title. Cartridge type 0x15 (Super FX + RAM + battery), 32 KB GSU RAM,
  LoROM, 2 MB without copier header, checksum checked. It needs `USE_GSU` (GSU half-clock logic, §5). Thus it is
  not a first test. For the first test, use a game without a special chip. The Super FX game then checks the GSU
  path.

**PSX** (biggest chunk):

- Size: ≈ 108 multiplications (32×32 → 4 DSP48), BRAM ≈ 2.1 Mbit (≈ 70–80 BRAM36, estimated). The measured values
  are below.
- Clocks 1×/2×/3× phase-locked (logic uses `clk2xIndex`) → master 203.2 MHz, dividers 6/3/2. Video clock `pll2`
  53.69 MHz with reprogramming (PAL/NTSC/fast-forward).
- `DDRAM_*` mandatory: VRAM, memory cards, SPU RAM, savestates from 0x3000_0000, read bursts up to 128 beats (the
  bridge splits them). `MISTER_FB` (ascal reads the frame buffer, stride 2048).
- Megafunctions: `altsyncram` with clock enable (7 locations with two clocks), `altdpram` MLAB (10 instances).
  Vivado infers the FIFOs and the multipliers.
- Vivado: library `mem`, VHDL-2008, `inout reg` in `rtl/sdram.sv`, procedural `output` assignments in `PSX.sv`
  (`USER_OUT`, `VGA_DISABLE`). `file_open` occurs only inside `translate_off` regions.
- `sys/ascal.vhd` is older than in the template (missing resets on PLL reprogramming). This is not critical here
  because the HDMI clock is fixed (estimated).

**PSX on the Zybo** (assessment 2026-10-30, PSX_MiSTer `cd17b5a`, OOC synthesis of `psx_mister` without `sys/`,
placeholders for `dpram`/`dpram_dif`/`RamMLAB`):

- Full core: 44,639 LUT (83.9 %), 121 BRAM tiles (86 %), 104 DSP, `clk2x` (67.74 MHz) WNS −6.9 ns. With the
  frame: 105 % LUT and 105 % BRAM.
- Reduced core (72 options as constants): 41,787 LUT, 99.5 tiles. The options are savestates/rewind/cheats,
  overlays, texture filter, 24-bit rendering, widescreen, multitap, special controllers, 8 MB, turbo and EXE
  loading. The savestate logic (3.3k LUT) stays in spite of the constants. Its removal needs a patch.
- With the frame without `ascal`, DDRAM bridge and stage D: ≈ 45k LUT (≈ 85 %), ≈ 107 tiles.
- Timing: `clk1x`/`clk3x` met (give the periods exactly as 1:2:3). `clk2x` fails at `gpu_poly` `CALCBOUNDARY1`
  (`rtl/gpu_poly.vhd:624–631`, 21.7 ns against 14.8 ns).
- Solution without an additional state: patch
  `cores/psx/patches/0001-gpu-poly-target-timing-factors-in-sortvertices.patch`. It calculates the x and y spans
  (independent of the order) into registers already in `SORTVERTICES`. `CALCBOUNDARY1` only multiplies. The
  differential bench `gpu_poly_diff_tb` (original against patch, all outputs on each clock, 600 commands, 7/7
  mutants) gives PASS. `gpu_poly` alone, OOC: WNS −6.9 → +3.3 ns (synthesis estimate).
- Memory: VRAM and SPU RAM in DDR from 0x3000_0000 (`DDRAM_*`, mandatory). Main RAM/BIOS in SDRAM with
  `ram_ena`/`ram_done` → stage D, free-running clocks from an MMCM (stage C needs a 203 MHz master). The
  replacement `cores/psx/sdram.vhd` (Avalon master for `COREMEM`, bench `psx_sdram_tb`) is available. The image
  has 24 MB, from 0x3800_0000, without overlap with the DDRAM areas of the core.
- Conclusion at that time: possible with compromises (no savestates, no texture filter). XC7Z100-2: full core
  16 % LUT, all clocks met.
- Result: the routed design closed timing (`zybo-z7-20_psx_hdmi` WNS +0.216 ns). It runs on the board with the
  picture through `ascal`.

**PSX profile** (`cores/psx`, 2026-10-31):

- Stage D as for N64 (`G_FREE_CLK`, `G_DDRAM`, `G_COREMEM` with `sdram.vhd`).
- Clocks from one MMCM (VCO 812.5 MHz, /24 /12 /8, −432 ppm) instead of a 203 MHz master. `pll2`: NTSC PLLE2 + PAL
  MMCM behind `BUFGCTRL` (all 4 MMCMs used).
- A replacement `savestates.vhd` removes the savestate logic. It contains only the reset sequence (cycle-identical
  to the original, comparison testbench). `emu` 42,289 → 37,028 LUT, because the read-back paths in GPU, GTE, CPU,
  CD and DMA also disappear.
- EXE loading stays (178 LUT, for homebrew/test programs without a CD image).
- `SDRAM` image at 0x3800_0000: the core uses only 0x3800_0000–0x397F_FFFF there (RAM, BIOS, EXE). The DDRAM areas
  are at 0x3000_0000–0x307F_FFFF and 0x3E00_0000 (savestates disabled, `CONF_STR` entry removed). Only the disabled
  rewind area overlaps.
- Vivado pitfalls: Pull `typedef struct` in `PSX.sv` onto one line before `declarations_first`. `rtl/hps_ext.v`
  has CRLF and uses `localparam`s before their declaration.

### 5.2 Requirements of N64

N64_MiSTer `5725381` (pinned 2026-10-30). The core is ported now (`cores/n64/STATUS.md`). It runs on the Zybo at
its full clocks, with the options of the profile as constants and two timing patches. But it runs **outside** its
timing constraints (WNS −2.4 ns). At 80 %, only two endpoints miss by 0.03 ns. At 2/3, timing is met. The notes
below are the assessments from before the port. They show where the limits of the XC7Z020 are.

Size: OOC synthesis of `n64top` (Vivado 2025.2, synth only). Placeholders from XPM memories or inference replace the
Intel wrappers `dpram*`, `RamMLAB`, `Shiftreg`, `cpu_mul` (behavior not checked). The values are without `sys/`,
stage C and HDMI. On the Zybo, the frame needs ≈ 11,200 LUT, 26 BRAM36, 35 DSP more (§3.1).

| FPGA (board) | LUT | BRAM36 | DSP | WNS after synth |
|---|---|---|---|---|
| XC7Z020-1 (Zybo) | 45,071 (84.7 %) | 69.5 | 63 | −6.044 ns, 173 endpoints; critical: RDP on `clk1x`, 22 ns, 27 levels |
| XC7Z100-2 (RK7100) | 45,093 (16 %) | 69.5 | 63 | +3.188 ns |
| XCZU7EV-2 (ZCU106) | 45,026 (20 %) | 63.5 | 63 | +4.556 ns |

With the frame, the XC7Z020 needs ≈ 56,000 LUT (≈ 106 %, estimated). Also, the timing on this device is 6 ns
short. Candidates: RK7100 (XC7Z100, armhf as the Zybo, HDMI through ADV7511) or ZCU106.

Second assessment "does it fit on the Zybo after all?" (2026-10-30):

- **Area: solvable.** `n64top` needs 40,044 LUT (75 %) with these changes:
  - The OSD options of `N64.sv` as constants (64DD, mouse, keyboard, pads 2–4, SNAC, savestates, cache debug off).
  - VI filter off.
  - The RDP multipliers in DSP48.

  The frame without `ascal` and without VGA OSD/YC needs ≈ 6k LUT instead of 10.8k. Upstream `MISTER_DEBUG_NOHDMI`
  makes this possible: HDMI shows the direct video signal, with scandoubler 31 kHz. For N64, this is 1547 × 525
  clocks at 48.68 MHz, thus 480p60 with a non-standard line length. Together: ≈ 46k LUT (≈ 87 %), ≈ 75 BRAM tiles,
  ≈ 130 DSP.
- **Timing: not at full speed.** The RDP path alpha combiner → coverage → Z buffer overflow → `blend_enable` is in
  one `clk1x` cycle (16 ns). Routed, it needs 22.4 ns, also with DSP48 and retiming. All core clocks together at
  2/3 (41.7/62.5/83.3 MHz) close after routing (`clk1x` +1.4 ns, `clk93` +0.5 ns). More than ≈ 69 % is not
  possible without restructuring. The game then runs at ≈ 2/3 speed, and the audio is ≈ 7 semitones lower.
- **Full clock only with an RDP rework:** an additional pipeline stage between `STAGE_COMBINER` and `STAGE_BLENDER`.
  This is difficult for two reasons:
  - The two-cycle mode feeds the combiner result (`combine_alpha_next`) back in the next cycle.
  - The Z buffer needs alpha/coverage in the same cycle as the FB/Z values that it reads.

  Thus the change shifts the memory timing of the RDP. Also, `clk93` (CPU, `cop0`/multiplier) is short by ≈ 1.2 ns.
  This is a large patch to a cycle-accurate core. The effort is weeks, and the result is open.
- Independently of the board, `DDRAM_*` (RDRAM) and the cartridge SDRAM were missing. Stage D solves both
  (`G_DDRAM` on HP2, `G_COREMEM` with `cores/n64/sdram.vhd` on HP3).

Conclusion at that time: on the Zybo, at most ≈ 2/3 speed within the constraints. The result: the replacement
`RDP_CombineAlpha.vhd` (multiply-add in one DSP48) closes the RDP path at 80 %. The patches 0001/0002 make the CPU
paths shorter. Full speed within the constraints still needs a larger device (XC7Z100: +3.2 ns at full clock) or an
RDP rework.

- Clocks: `clk1x` 62.5, CPU 93.75, `clk2x` 125 MHz (2:3:4) → master 187.5 MHz with dividers 3/2/1.5. These are not
  integer dividers. Alternatives:
  - Master 375 MHz with dividers 6/4/3 (timing open).
  - Free-running clocks, with only the cartridge SDRAM through a handshake (below).

  Also `pll2` for video 48.68 MHz with `pll_cfg` (PAL/NTSC).
- `DDRAM_*` mandatory: RDRAM is in DDR, `DDR3Mux` with 9 users, bursts up to 255 beats (the bridge splits them into
  ≤ 16). `MISTER_FB` (VI writes the frame buffer).
- SDRAM: cartridge ROM, access through `ch1/ch2/ch3` with `req`/`ready` (users SAV, PIF, PI, RDP, VI). The core
  already waits → **stage D possible**: replace `sdram` with an AXI controller with identical connections, without
  a clock stall.
- Profile `cores/n64`:
  - Rules: `N64.sv:194` (`'Z` next to the drivers of `sdram`/`pll`), the SNAC block (nets in `always`), library
    `mem` → `work` (32 clauses, 47 names).
  - VHDL 2008 (`core_vhdl_std`).
  - Replacements with testbench and mutation test:
    - `cpu_mul` (64 × 64, latency exactly 2: the FPU reads the product 3 edges after `mul1`).
    - `Shiftreg` (`altshift_taps` = DEPTH registers).
    - `pll`/`pll2` (MMCM).
    - `pll_cfg_small` (ignores writes).
  - `altsyncram` with byte enables as banks of symmetric byte-write RAMs. Vivado has no asymmetric byte-write RAM
    (RSP IMEM 64/32 → 2 RAMB36).
  - `use_dsp` on six RDP units: −1.2k LUT, +59 DSP.
  - OOC `emu` at 2/3: see `STATUS.md`.
- Start: The PIF boot ROMs (`boot.rom` NTSC, `boot1.rom` PAL) are not included. Users must supply their own legally
  obtained images. `pifrom.vhd` is empty. Main_MiSTer has `support/n64`.
- Test ROM (not in the repository, Git ignores `roms/`): an unmodified big-endian image of a PAL game: 8 MB,
  CIC 6102/7101, header checksum checked. To start it, you need `boot1.rom`.

### 5.3 Inventory of widespread cores

`core_survey.py` (working state 2026-10-30 with lint section 7) ran over 17 cores from github.com/MiSTer-devel.
These are shallow clones from 2026-10-30, plus SNES/MSX/N64 at the pin for comparison. The script only read the
source: synthesis NOT RUN, sizes unknown. `Genesis_MiSTer` is the old fpgagen port (last commit 2023). The table
counts its successor `MegaDrive_MiSTer`. `Arcade-CPS1_MiSTer` does not exist. The CPS cores come from
jotego/jtcores (project made by jtframe, different layout). The table does not include them.

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

How to read the table: "SDRAM/DDRAM yes" means that the core uses the signals and does not only tie them off. The
count is over the files of `files.qip` (`SDRAM_DQ`/`SDRAM_A`, `DDRAM_ADDR`/`_RD`/`_WE`). We did not check for each
core what it needs DDRAM for. The OSD texts of NES, SMS, GBA, Gameboy, PSX and ZX mention savestates or rewind.
MegaDrive uses DDRAM for CDDA. DDRAM is mandatory for PSX and N64 (§5.1, §5.2). The column "falling edge,
derived" counts the lint errors. Such an error is logic on the falling edge of a clock derived from the pacer clock
(5.6 ns instead of half a period). The word "unresolved" marks edges on clocks that the lint does not trace back to
the PLL. Check them by hand. All cores have
unconnected VHDL inputs with default (2–50 locations). `prepare_sources.py` already connects them generically.

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

**Next cores with the lowest effort on the Zybo** (estimate from the inventory, without synthesis):

1. **NES**: The same clocks as SNES (master 90 MHz, pacer 21/22, SNES `pll.vhd`), no falling edges, one SDRAM.
   Only `pll_cfg` is missing (use the SNES replacement again). It has 6 `.sdc` exceptions. Least effort.
2. **SMS**: One clock (53.7 MHz), only `pll_cfg`. The `.qsf` sets `MISTER_FB` → check if the core really needs the
   frame buffer path.
3. **TurboGrafx16**: Master 85.9 MHz as SNES and MSX, plus 43.0 MHz. Only FIFOs are missing, and only in the CD
   part (replacement or disable).
4. **Gameboy**: Two clocks, no missing megafunctions. But it has 3 falling edges on `clk_sys` → mid clock (§3.3,
   rules checked in the dry run).
5. **GBA**: Lint without errors. But master > 100 MHz (timing), `MISTER_FB` and its own VHDL library.

These cores are large or need missing building blocks:

- Saturn (DDRAM/SDRAM2, size).
- ao486 (5 clocks, 2 PLLs).
- NeoGeo (SDRAM2).
- Minimig, MegaCD, Arcade-Cave, C64, AtariST, Atari800.
- MegaDrive (Nuked YM clocks).

Sequence by benefit: generic `pll_cfg` → `.sdc` translator → FIFOs → DDRAM on HP2 (mid clock: available, §3.3).

Weaknesses of `core_survey.py` that the inventory showed:

- Section 4 lists no `SDRAM_*` row for cores that declare their ports through `` `include "sys/emu_ports.vh" ``
  (here NES, GBA, MegaCD, TurboGrafx16, ZX-Spectrum). Thus the column above comes from a separate count.
- The lint does not trace clocks that a core makes internally (Nuked YM, T80 `CLK_n`) back to the PLL.

## 6. Profiles at a glance

| Profile | Checkout | Clock replacement | SDRAM | Rules | Notes |
|---|---|---|---|---|---|
| `msx` | MSX_MiSTer | `pll.vhd` (clk_mem, clk_sys = /4), master 90 MHz, pacer 21/22 | 2/13/9, VRAM → BRAM, `G_CACHE_COL_HIGH` 1 | 3 | `MISTER_ZYNQ_NO_DOWNSCALE`, `games.sh` |
| `menu` | Menu_MiSTer | `pll.vhd` (clk_sys = CLK_VIDEO), master 85 MHz (84.79 achieved), pacer 1/1 | 2/13/9, everything via the cache | 4 | `MENU_CORE`, `lfsr.vhd`, `DDRAM_*` tied off |
| `snes` | SNES_MiSTer | `pll.vhd` (clk_mem, CLK_VIDEO /2, clk_sys /4, mid clock), `pll_cfg.vhd` (PAL pacer 227/240), master 90 MHz, pacer 21/22 | stage C, `G_CACHE_SPLIT` 1 | 28 | patches 0001/0002 (GSU, falling edges), `msu_fifo.vhd`, no SPC7110, BSRAM 128 KB |
| `psx` | PSX_MiSTer | `pll.vhd` (MMCM 33.85/67.71/101.56 MHz), `pll2.vhd` + `pll_cfg.vhd` (NTSC/PAL), free-running. KR260: `pll2_us.vhd` (one MMCM for NTSC and PAL, `core_swap_low_mmcm`) | stage D: `sdram.vhd` → HP3, `DDRAM_*` → HP2 | 73 | `savestates.vhd` (reset sequence only), options as constants, EXE loading on, patches 0001/0002 (`gpu_poly`) |
| `n64` | N64_MiSTer | `pll.vhd` (MMCM 62.5/93.75/125 MHz), `pll2.vhd` + `pll_cfg_small.vhd` (NTSC/PAL), free-running. KR260: `pll2_us.vhd` (one MMCM for NTSC and PAL, `core_swap_low_mmcm`) | stage D: `sdram.vhd` → HP3, `DDRAM_*` (RDRAM) → HP2 | 66 | options as constants, `cpu_mul.vhd`, `Shiftreg.vhd`, `RDP_CombineAlpha.vhd`, `cpu_addr_fwd.vhd`, patches 0001/0002 (timing) |

## 7. New board

Only `firmware/targets/<p>/` is specific to the board:

- `platform.mk` (flows, boot, `MISTER_CORES`, `VIDEO_TX`).
- `constraints/<p>_mister.xdc` (pins, clock groups).
- `scripts/<ver>/<p>_mister.tcl` (block design for each core: PS, MMCMs, HDMI output, codec, buttons/LEDs).
- Device tree (reserved DDR, `fclk-enable`).
- Board files of the RootFS (codec init).

The template is `firmware/targets/_template/`. It is derived from `zybo-z7-20` and is not a board: `common.mk` and
`selfcheck.sh` skip `targets/_*`. Its README lists the steps. Lines with the mark `CONTRACT` stay. `TODO` and
`<...>` are board work. Then do these steps:

1. Run `make test` (step 3 does a dry run of each flow action of the new board).
2. Run `PLATFORM=<p> FLOW=vivado CORE=menu make create build`.

Board stages (rows of `firmware/targets/<board>/STATUS.md`):

- `boot`: BOOT.bin from the SD card, U-Boot, kernel.
- `linux`: RootFS from the card or NFS.
- `main`: Main_MiSTer with the Zynq patches, OSD.
- `video`: HDMI, DVI or DisplayPort picture.
- `audio`: HDMI audio, codec or DisplayPort audio.
- `input`: USB keyboard, gamepads, Bluetooth.
- `sd`: `/media/fat` on the card, image mount.
- `net`: network boot (TFTP/NFS), SSH.
- `switch`: core change through `load_core` with quiesce.

### 7.1 Board contract

This section gives what `mister_zynq`, the core profiles and Main_MiSTer expect from the board. The Zybo Z7-20
column has proof on the hardware (`zybo-z7-20_mister.tcl`, `zybo-z7-20_mister.xdc`, `zynq-zybo-z7.dts`). The ZCU106
column has proof on the hardware for all five cores (`zcu106_mister.tcl`, `zcu106_mister.xdc`,
`zynqmp-zcu106-revA.dts`, `firmware/targets/zcu106/README.md`). The KR260 column has proof on the hardware for menu and MSX
(`kr260_mister.tcl`, `kr260_mister.xdc`, `firmware/targets/kr260/README.md`).

| Item | Contract (Zybo, checked) | ZynqMP: ZCU106 (checked) | ZynqMP: KR260 (menu, MSX checked) |
|---|---|---|---|
| PS | `processing_system7` with board preset, `PLATFORM_ARCH zynq` | `zynq_ultra_ps_e` with board preset, `PLATFORM_ARCH zynqmp`. The boot firmware of the board's own SD card (FSBL, PMU firmware, TF-A, U-Boot) stays | As ZCU106. The boot firmware and U-Boot are in the QSPI flash and stay |
| AXI-Lite | `M_AXI_GP0` → SmartConnect → `mister/s_axi` (`hps_bus_axi`) at **0x4000_0000**, 4 KB. Main patch 0002 selects the base at runtime: 0x4000_0000, or 0xA000_0000 if the device tree has `xlnx,zynqmp` (`MISTER_ZYNQ_REG_BASE` overrides it) | `M_AXI_HPM0_FPD` (128 bit) → SmartConnect → `mister/s_axi` at **0xA000_0000**, 4 KB. Patch 0002 selects this base from `xlnx,zynqmp` | As ZCU106 |
| SDRAM image | `mister/m_axi_sdram` → `S_AXI_HP0`, AXI3 64 bit, clock `clk_master` | SmartConnect (64 to 128 bit, AXI3 to AXI4) → `S_AXI_HP0_FPD` at 128 bit, the reset value of the AFI registers. No FSBL setting is necessary | As ZCU106. Check the AFI registers under the Kria boot firmware |
| Scaler | `mister/m_axi_vbuf` → `S_AXI_HP1`, AXI3 64 bit, clock FCLK0 | As HP0, `S_AXI_HP1_FPD`, clock `clk_100` | As ZCU106 |
| DDRAM of the cores | only with profile `G_DDRAM 1`: `mister/m_axi_ddram` → `S_AXI_HP2`, AXI3 64 bit, clock `mister/ddram_clk` (`DDRAM_CLK` of the core); `mister_ddram` in the generator adds HP2 | As HP0, `S_AXI_HP2_FPD`. `S_AXI_HP3_FPD` for `G_COREMEM`. The SmartConnects of HP2 and HP3 get the reset of `mister_zynq` on their clock | As ZCU106 |
| Address windows | HP0/HP1 (HP2) see the whole DDR 0x0000_0000–0x3FFF_FFFF (physical addresses of the cores and of Main unchanged) | `HP<n>_DDR_LOW` 0x0000_0000–0x7FFF_FFFF, the same physical addresses | As ZCU106 |
| DDR allocation | `G_SDRAM_BASE` 0x3800_0000 (profile), `ascal` 0x2000_0000, Linux FB 0x2200_0000, ROM loading from 0x3000_0000, handover page 0x1FFF_F000; at least 1 GB DDR from 0 | same | same |
| Device tree | `reserved-memory` 0x1FF0_0000, size 0x2010_0000, `no-map`; `bootargs` with `uio_pdrv_genirq.of_id=generic-uio`; `&clkc { fclk-enable = <0x1>; }` (otherwise Linux switches FCLK0 off) → `_template/dts/mister.dtsi` | Board DTS with the same `reserved-memory` and `bootargs`. No `fclk-enable`: the PL does not use a PS clock | Open: a board DTS with the same nodes |
| Clocks | FCLK0 100 MHz (`clk_100`: AXI-Lite, HP1, sysmem); MMCM `clk_core` on FCLK0: out1 24.576 MHz (`clk_audio`), out2 master of the profile (`clk_master`, HP0), out3 50 MHz (`clk_50`), out4 master **without BUFG** (`clk_master_gate`, input of the BUFGCE in the frame); the generator script checks that out2 and out4 have identical dividers, phase and duty cycle | Board oscillator CLK_125 → MMCM `clk_base` (100 MHz with safe clock startup, 25 MHz) → `clk_core` with the dividers of the Zybo. No PS clock | 25 MHz carrier oscillator → `clk_base` (100 MHz, 25 MHz) → `clk_core` as ZCU106. The XCK26 has four MMCMs in one column: `kr260_mmcm_frame.xdc` sets their sites. PSX and N64 (two MMCMs of their own): compact variant without `clk_base`, `clk_core` from 25 MHz (VCO 900 MHz: 100, 50, 24.573 MHz), sites in `kr260_mmcm_compact.xdc` |
| Pixel clock | MMCM `clk_hdmi` on FCLK0: 74.25 MHz (`clk_hdmi`) and 371.25 MHz (5×, serializer) | 74.25 MHz from the Si5324 (148.5 MHz / 2 through `BUFG_GT`) | MMCM `clk_pix`: exactly 74.25 MHz from 25 MHz |
| Reset | `proc_sys_reset` in the FCLK0 domain (`ext_reset_in` = `FCLK_RESET0_N`, `dcm_locked` = `clk_core/locked`), `peripheral_aresetn` → `mister/aresetn`; the frame synchronizes it into the master clock | `proc_sys_reset` on `clk_100` with `ext_reset_in` = 1 and `dcm_locked` = `clk_core/locked`. No PS reset | As ZCU106 |
| Clock groups | XDC block `CONTRACT` (master with `clk_master_gate` and the derived core clocks, 100, 50, HDMI, audio asynchronous); `core.xdc` is read before it | same, plus the transceiver clocks | same |
| Video | TMDS directly on the pins (7 series `TMDS_33`): `rgb2dvi` (`VIDEO=dvi`) or `hdmi_out` from `firmware/common/ip/hdmi-tx` (`VIDEO=hdmi`, audio in HDMI) | No `TMDS_33` on UltraScale+: `hdmi_tx` symbols over three GTH lanes and the DP159 retimer (`zcu106_hdmi`) | No HDMI: `kr260_dp_live` into the live video input of the PS DisplayPort |
| Audio | I2S from `mister_zynq` to the codec; codec init as a RootFS file (`MISTER_ROOTFS_FILES`, Zybo `ssm2603-init.sh` via PS I2C0 on EMIO), mute pin permanently off | In the HDMI data islands (`i2s_rx` of `hdmi-tx`) | No codec: `kr260_dp_audio` puts the I2S into the live audio input of the PS DisplayPort. `kr260_dp_live.py` sets it up, because the driver ignores the live audio |
| Buttons/LEDs | `btn[0]` OSD, `btn[1]` user, `sw` = 0; LEDs: DE10-Nano LED 0, 2, 4 and `status_err` | GPIO_SW_C OSD, GPIO_SW_N user. LEDs 0–3 as on the Zybo, LEDs 4–7 HDMI status | No PL buttons or LEDs: OSD with F12, LEDs in `board_status` |
| SD card | PS SD0 under Linux, `/media/fat` as on MiSTer; no PL pins | The board's own SD card only up to U-Boot. Kernel through TFTP, RootFS with `/media/fat` through NFS | As ZCU106 (checked). The SD card of the carrier is a USB device |
