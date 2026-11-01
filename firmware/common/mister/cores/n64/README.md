# N64 (N64_MiSTer)

Nintendo 64 (VR4300 CPU, RSP, RDP, VI): the [N64_MiSTer](https://github.com/MiSTer-devel/N64_MiSTer) core by Robert
Peip (FPGAzumSpass) and contributors, checkout `N64_MiSTer` at the pin in `firmware/common/checkouts.txt`. This
profile only adapts it to Vivado and the Zynq. What works where: [STATUS.md](STATUS.md).

The profile makes the core fit the XC7Z020 (OSD options as constants, RDP multipliers in DSP48). The
frame runs it as a stage D core (doc/ARCHITECTURE.md §3): free-running core clocks (`G_FREE_CLK`),
`DDRAM_*` on HP2 (`G_DDRAM`), the SDRAM controller replaced by `sdram.vhd` with an Avalon master on HP3
(`G_COREMEM`), the picture through `ascal` at a fixed 1280 x 720 / 60 Hz (vbuf on HP1, slim `ascal`: no
downscaler, small vbuf, no adaptive scanlines). Earlier the picture went out as direct video with the
scandoubler (`G_DIRECT_VIDEO`); a monitor showed it, but not every HDMI sink takes the non-CEA timing.
Full build `zybo-z7-20_n64_hdmi`: timing is met at 2/3 of the original clocks; the profile now runs the original
clocks (100 %), where timing still fails (WNS −2.4 ns) but the test board runs ([STATUS.md](STATUS.md)). This is
outside the specification of the device and not guaranteed on other boards or at other temperatures. Hardware: a
PAL game boots with the PAL PIF ROM `boot1.rom` (not included).

## Build and test

Out-of-context synthesis of `emu` (prepared sources, replacement files, VHDL 2008):

    M=firmware/common/mister
    python3 $M/scripts/prepare_sources.py N64_MiSTer _Checkouts/N64_MiSTer firmware/build/src/N64_MiSTer $M/cores/n64/rules.py
    vivado -mode batch -source $M/scripts/synth_core_ooc.tcl -tclargs \
      --qip firmware/build/src/N64_MiSTer/files.qip --qip firmware/build/src/N64_MiSTer/sys/sys.qip \
      --top emu --out firmware/build/ooc/n64_emu --profile $M/cores/n64/core.tcl \
      --exclude '*/rtl/pll*' --exclude '*/rtl/cpu_mul.vhd' --exclude '*/rtl/Shiftreg.vhd' \
      --exclude '*/rtl/sdram.sv' --exclude '*/sys/pll_hdmi.v' --exclude '*/sys/pll_audio.v' \
      --exclude '*/sys/pll_cfg/*' --exclude '*/sys/pll_hdmi/*' --exclude '*/sys/pll_audio/*' \
      --exclude '*/sys_top.v' --exclude '*/sysmem.sv' --exclude '*/f2sdram_safe_terminator.sv' \
      $(for f in $M/hdl/intel/*.vhd $M/cores/n64/*.vhd; do echo --add $f; done) \
      --define MISTER_FB=1 --define MISTER_DOWNSCALE_NN=1 --define MISTER_DISABLE_ALSA=1 \
      --define MISTER_ZYNQ_NO_DOWNSCALE=1 --define MISTER_ZYNQ_COREMEM=1 --define MISTER_SMALL_VBUF=1 \
      --define MISTER_DISABLE_ADAPTIVE=1 --define MISTER_DISABLE_YC=1 \
      --xdc <create_clock 20 ns on CLK_50M> --xdc $M/cores/n64/core.xdc

(`--exclude '*/sys/pll_*'` would also drop `sys/pll_hdmi_adj.vhd`, which `sys_top_zynq` needs.) With `--top
sys_top_zynq` and `--rtl` the same call only elaborates the core with the frame ports (minutes): port
connections of the rules, widths, missing modules.

Testbenches of the replacement files: `make -C firmware/common/mister/tb n64_cpu_mul_tb n64_shiftreg_tb
n64_pll_tb n64_sdram_tb n64_combinealpha_tb n64_cpu_addr_fwd_tb n64_cop0_diff_tb` (also part of `make test`).
`n64_cop0_diff_tb` runs the original `cpu_cop0` and the patched copy side by side and compares every output and
every exported COP0 register twice per cycle. `n64_sdram_tb` checks `sdram.vhd` against a model of the
original's addressing (16-bit words, wrap of the second half, 8-bit mode of ch3) behind a random Avalon slave.

## Profile

| File | Content |
|---|---|
| `core.tcl` | VHDL 2008, macros, replacement files; SDRAM and DDRAM layout in the header; `G_FREE_CLK`, `G_DDRAM`, `G_COREMEM`, `G_DIRECT_VIDEO` 0 |
| `rules.py` | library `mem` → `work`, `SDRAM_*` without the second driver `'Z`, SNAC block, OSD options as constants, emu ports `COREMEM_*` to `sdram`, RDP multipliers in DSP48 |
| `sdram.vhd` | replaces `rtl/sdram.sv`: same channel ports, a 64-bit Avalon master instead of the SDRAM pins (one beat per access, up to 8 reads in flight); image at 0x3800_0000 |
| `pll.vhd` | MMCM 50 MHz → `clk_1x` 62.5, `clk_93` 93.75, `clk_2x` 125 MHz (the original rates) |
| `pll2.vhd` | PLLE2 → `clk_vid` 48.684 MHz (NTSC) and MMCM → 49.656 MHz (PAL), BUFGCTRL selects |
| `pll_cfg_small.vhd` | takes the reconfiguration writes of `pll2`: the PAL divider selects the PAL clock |
| `RDP_CombineAlpha.vhd` | alpha combiner, same behaviour as `rtl/RDP_CombineAlpha.vhd` (bench compares both), multiply-add in one DSP48, subtract and coverage multiply in LUTs: the path to `cvg_overflow` 20.3 → 17.3 ns after synthesis; read as VHDL 2008 (`core_vhdl2008`) |
| `cpu_addr_fwd.vhd` | memory address adder of `cpu.vhd` with the operand forwarding select after the add (one adder per source) |
| `patches/` | timing patches of the checkout, same outputs in every cycle: 0001 wires in `cpu_addr_fwd.vhd`, 0002 lets `cpu_cop0.vhd` write the exception address (BadVAddr, EntryHi, Context, XContext) one cycle later from registers |
| `cpu_mul.vhd` | 64 × 64 multiplier of the CPU, latency 2 as `altera_mult_add` |
| `Shiftreg.vhd` | shift register of the RDP pipeline (`altshift_taps`), DEPTH enabled stages |
| `core.xdc` | names of the MMCM clocks, `clk_vid` and the 50 MHz input asynchronous to the core clocks |

OSD options tied to constants (`rules.py`): overlays off, VI filters off (bilinear, gamma,
dedither, antialias, divot, noise), VI path instead of clean HDMI, debug page at its defaults, no savestates, no
64DD, controller 1 only (N64Pad, ControllerPak, RumblePak, TransferPak; no SNAC, keyboard, mouse). The menu
still shows them.

## Gaps

- Timing at the original clocks fails (see above); full speed within the constraints needs a larger device.
- Area: about 90 % LUT with `ascal` ([STATUS.md](STATUS.md)).
- Input: only controller 1; the `input` stage is not recorded yet.
- MPAL gets the NTSC video clock (-1100 ppm).
- PIF boot ROM: not in the repository, Main_MiSTer loads it.
