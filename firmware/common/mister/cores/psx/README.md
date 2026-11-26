# PSX (PSX_MiSTer)

Sony PlayStation (R3000A CPU, GTE, GPU, SPU, MDEC, CD-ROM): this profile is for the
[PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) core by Robert Peip (FPGAzumSpass) and contributors. The
checkout `PSX_MiSTer` is at the pin in `firmware/common/checkouts.txt`. This profile only adapts the core to Vivado
and the Zynq. What works where: [STATUS.md](STATUS.md).

PSX is a stage D core like N64 (doc/ARCHITECTURE.md §3):

- free-running core clocks (`G_FREE_CLK`)
- `DDRAM_*` on HP2 (`G_DDRAM`: VRAM, SPU RAM, memory cards)
- `sdram.vhd` replaces the SDRAM controller, with an Avalon master on HP3 (`G_COREMEM`, main RAM, BIOS, EXE
  download at 0x3800_0000)
- the picture through `ascal` at a fixed 1280 x 720 / 60 Hz (vbuf on HP1, slim `ascal`)

These functions are off, so that the core fits the XC7Z020: savestates, rewind, SNAC, cheats, fast forward and the
non-default OSD options. EXE loading (`F1,EXE`) stays for homebrew and test programs (178 LUT).

## Build and test

Out-of-context synthesis of `emu` (prepared sources, replacement files, VHDL 2008):

    M=firmware/common/mister
    python3 $M/scripts/prepare_sources.py PSX_MiSTer _Checkouts/PSX_MiSTer firmware/build/src/PSX_MiSTer $M/cores/psx/rules.py
    vivado -mode batch -source $M/scripts/synth_core_ooc.tcl -tclargs \
      --qip firmware/build/src/PSX_MiSTer/files.qip --qip firmware/build/src/PSX_MiSTer/sys/sys.qip \
      --top emu --out firmware/build/ooc/psx_emu --profile $M/cores/psx/core.tcl \
      --exclude '*/rtl/pll*' --exclude '*/rtl/sdram.sv' --exclude '*/rtl/savestates.vhd' \
      --exclude '*/sys/pll_hdmi.v' --exclude '*/sys/pll_audio.v' \
      --exclude '*/sys/pll_cfg/*' --exclude '*/sys/pll_hdmi/*' --exclude '*/sys/pll_audio/*' \
      --exclude '*/sys_top.v' --exclude '*/sysmem.sv' --exclude '*/f2sdram_safe_terminator.sv' \
      $(for f in $M/hdl/intel/*.vhd $M/hdl/pll_reset.vhd $M/cores/psx/*.vhd; do echo --add $f; done) \
      --define MISTER_FB=1 --define MISTER_DOWNSCALE_NN=1 --define MISTER_DISABLE_ALSA=1 \
      --define MISTER_ZYNQ_COREMEM=1 --define MISTER_ZYNQ_NO_DOWNSCALE=1 --define MISTER_SMALL_VBUF=1 \
      --define MISTER_DISABLE_ADAPTIVE=1 --define MISTER_DISABLE_YC=1 --define MISTER_ZYNQ_SIMPLE_AUDIO=1 \
      --define MISTER_ZYNQ_NO_DIRECT_VIDEO=1 \
      --xdc <create_clock 20 ns on CLK_50M> --xdc $M/cores/psx/core.xdc

With `--rtl`, the same call only elaborates `emu` (minutes). This shows the port connections of the rules, the
widths and missing modules.

The testbenches of the replacement files are also part of `make test`. `psx_pll_tb` needs `UNISIM_SRC`. This
command runs them:

    make -C firmware/common/mister/tb psx_savestates_tb psx_savestates_fast_tb psx_pll_tb

`psx_savestates_tb` compares `savestates.vhd` cycle by cycle with the original `rtl/savestates.vhd` (renamed
copy). The inputs are random. The bench runs these sequences:

- one full reset sequence (scratchpad, SPU RAM, VRAM, main RAM)
- one aborted reset sequence
- one reset sequence in EXE mode

`psx_savestates_fast_tb` runs 100 shortened sequences (`FASTSIM`) with resets at random times. `psx_pll_tb` checks
the three core clocks on their common grid and the reset sequencers. It also checks the NTSC/PAL switch of `clk_vid`
with the writes of `PSX.sv`.

## Profile

| File | Content |
|---|---|
| `core.tcl` | VHDL 2008, macros, replacement files. DDRAM and SDRAM layout in the header. `G_FREE_CLK`, `G_DDRAM`, `G_COREMEM`, `G_DIRECT_VIDEO` 0 |
| `rules.py` | library `mem` → `work`, SNAC block, savestate slot entry out of `CONF_STR`, OSD options as constants, emu ports `COREMEM_*` to `sdram`, declaration order for Vivado (`PSX.sv`, `rtl/hps_ext.v`) |
| `sdram.vhd` | replaces `rtl/sdram.sv`: same channel ports, a 64-bit Avalon master instead of the SDRAM pins (bench `psx_sdram_tb`) |
| `savestates.vhd` | replaces `rtl/savestates.vhd`: only its reset sequence (pause, reset pulses, header check, clearing scratchpad, SPU RAM, VRAM and main RAM), cycle-identical with save = load = 0. No save or load paths (−5.3k LUT in `emu`). |
| `pll.vhd` | MMCM 50 MHz → `clk_1x` 33.854, `clk_2x` 67.708, `clk_3x` 101.563 MHz (−432 ppm, phase-locked 1:2:3) |
| `pll2.vhd` | PLLE2 → `clk_vid` 53.704 MHz (NTSC, +196 ppm) and MMCM → 53.205 MHz (PAL, +32 ppm), BUFGCTRL selects |
| `pll_cfg.vhd` | takes the reconfiguration writes of `PSX.sv`. The PAL clock follows `isPal` directly (`rules.py`, synchronized in `pll2.vhd`), because the write sequence lost the switch on the board. |
| `core.xdc` | names of the MMCM clocks, the two `clk_vid` sources exclusive, `clk_vid` asynchronous to the core clocks |
| `core_ultrascale.xdc` | UltraScale(+) only: MMCM cascade from the board clock over the backbone, PAL clock to `buf_vid` over general routing (one CMT per region) |
| `patches/` | 0001: `gpu_poly` calculates the timing factors already in `SORTVERTICES` (`clk_2x` timing, bench `gpu_poly_diff_tb` against the original). 0002: signed compare of the left polygon edge (Vivado evaluated `to_integer(xStart) > drawingAreaRight` wrongly for negative values) |

OSD options tied to constants (`rules.py`):

- 2 MB RAM
- no turbo or CD speed hacks
- original timing (no pal60, no 480p hack)
- 15-bit color without dithering changes
- no texture filter or widescreen
- no overlays (FPS, CD, errors)
- only digital/analog pads on both ports (no GunCon, NeGcon, wheel, mouse, Justifier, multitap, SNAC)
- no savestates or rewind, no cheats, no fast forward

The menu still shows these options.

## Gaps

- Savestates, rewind, cheats, fast forward, SNAC and the special controllers are off (area of the XC7Z020).
- We measured the OOC numbers in `STATUS.md` with a stand-in for `sdram.vhd` (56 LUT). The routed design (row
  `timing`) contains the real `sdram.vhd`.
- BIOS: not in the repository. Main_MiSTer loads `boot.rom`. We did not test CD images.
- Fast forward gets the NTSC video clock (no 85 MHz `clk_vid`).
