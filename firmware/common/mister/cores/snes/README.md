# SNES (SNES_MiSTer)

Super Nintendo: the [SNES_MiSTer](https://github.com/MiSTer-devel/SNES_MiSTer) core written by srg320 (Sergiy
Dvodnenko), with Sorgelig and contributors, including its enhancement chips (GSU/SuperFX, SA-1, CX4, DSP-n, OBC1,
S-DD1, MSU-1); checkout `SNES_MiSTer` at the pin in `firmware/common/checkouts.txt`. This profile only adapts it to
Vivado and the Zynq. What works where: [STATUS.md](STATUS.md).

## Build and test

    PLATFORM=zybo-z7-20 FLOW=vivado CORE=snes VIDEO=hdmi make create build    # design zybo-z7-20_snes_hdmi
    make hwtest CORE=snes COMMIT=<commit the bitstream was built from>        # Yoshi's Island, 50.465 Hz

The bitstream goes to `/media/fat/_Console/SNES.rbf`, games to `/media/fat/games/SNES/`.

## Profile

| File | Content |
|---|---|
| `core.tcl` | SDRAM geometry, cache (`G_CACHE_SPLIT` 1: ROM and WRAM 8 KB each), pacer 21/22 of 90 MHz; the header explains every value |
| `rules.py` | 28 source rules for Vivado (`output reg`, port defaults of `dpram`, SPC7110 removed, BSRAM 128 KB, `msu_audio` on `CLK_MID`) |
| `patches/0001` | GSU: one process per clock edge (Vivado refuses both edges in one process) |
| `patches/0002` | falling edges of `clk_sys` become rising edges of `CLK_MID` (`clk_sys_mid`) |
| `pll.vhd` | replacement of `rtl/pll`: `clk_mem` = gated master, `CLK_VIDEO` /2, `clk_sys` /4, `CLK_MID` |
| `pll_cfg.vhd` | replacement of `sys/pll_cfg`: decodes the region write (K value) into `reconfig_to_pll[0]`, out as emu port `ZYNQ_PACE_ALT`: the pacer runs at 227/240 instead of 21/22 for PAL |
| `msu_fifo.vhd` | replacement of the `dcfifo` of MSU-1 |
| `core.xdc` | generated clocks of `pll.vhd`, the path exceptions of the core's `.sdc` |
| `hwtest.cfg` | game, gamepad sequence and frame rate of `make hwtest` |

Decisions: no SPC7110 and backup RAM 128 KB so that the core fits the XC7Z020; cache split after the
miss classes of `tools/perf.py`. Lessons of the port: doc/PORTING.md, doc/ARCHITECTURE.md §3 (stage C).

## Region

PAL games run at the PAL clock: `pll_cfg.vhd` turns the region write into the pacer ratio
227/240 of 90 MHz (21.28125 MHz core clock, −6 ppm); `make hwtest CORE=snes` measures 50.07 Hz for Yoshi's Island
(nominal 50.007 Hz).

## Gaps

- MSU-1 and savestates need `DDRAM_*`; not connected.
- Backup RAM to the card not checked yet.
