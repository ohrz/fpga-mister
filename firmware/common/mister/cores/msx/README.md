# MSX (MSX_MiSTer)

MSX2/2+: the [MSX_MiSTer](https://github.com/MiSTer-devel/MSX_MiSTer) core (MiSTer port by Sorgelig and
contributors of KdL's OCM-PLD, based on the One Chip MSX by Kazuhiro Tsujikawa, ESE Artists' factory; mostly VHDL),
checkout `MSX_MiSTer` at the pin in `firmware/common/checkouts.txt`. The first core of the port; this profile only
adapts it to Vivado and the Zynq. What works where: [STATUS.md](STATUS.md).

## Build and test

    PLATFORM=zybo-z7-20 FLOW=vivado CORE=msx VIDEO=hdmi make create build     # design zybo-z7-20_msx_hdmi
    make hwtest CORE=msx COMMIT=<commit the bitstream was built from>         # Kings Valley 2, 59.92 Hz

The bitstream goes to `/media/fat/_Computer/MSX.rbf`; `games.sh` builds the start medium (`boot.vhd` and one card
per ROM) for `FLOW=mister make package`. Game change: F12, mount the card of the game (top-level README).

## Profile

| File | Content |
|---|---|
| `core.tcl` | SDRAM geometry, BRAM region for VRAM pages 0/1, cache with `G_CACHE_COL_HIGH`, pacer 21/22 of 90 MHz; the header explains every value |
| `rules.py` | source rules for Vivado (OCM VHDL instantiation, Quartus syntax) |
| `patches/0001` | hide the ROM of the ESE-SCC after a card is mounted (game change), wires `scc_rom_hide.vhd` |
| `scc_rom_hide.vhd` | the logic of patch 0001 (testbench `tb/scc_rom_hide_tb.vhd`) |
| `pll.vhd` | replacement of the Quartus PLL: gated master, `clk_sys` every 4th pulse |
| `core.xdc` | generated clocks of `pll.vhd` |
| `games.sh` | start medium of the core |
| `hwtest.cfg` | game, keyboard input and frame rate of `make hwtest` |

Lessons of the port: doc/PORTING.md, doc/ARCHITECTURE.md §3 (memory map, §3.4) and §5.3 (game change).

## Gaps

- Saves to the SD card image work (`STATUS.md`, row `saves`); battery SRAM of cartridges not checked.
