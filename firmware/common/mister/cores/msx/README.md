# MSX (MSX_MiSTer)

MSX2/2+: this profile is for the [MSX_MiSTer](https://github.com/MiSTer-devel/MSX_MiSTer) core. Sorgelig and
contributors made this MiSTer port of KdL's OCM-PLD. The core is mostly VHDL. OCM-PLD is based on the One Chip MSX
by Kazuhiro Tsujikawa (ESE Artists' factory). The checkout `MSX_MiSTer` is at the pin in
`firmware/common/checkouts.txt`. MSX was the first core of the port. This profile only adapts the core to Vivado and
the Zynq. What works where: [STATUS.md](STATUS.md).

## Build and test

    PLATFORM=zybo-z7-20 FLOW=vivado CORE=msx VIDEO=hdmi make create build     # design zybo-z7-20_msx_hdmi
    make hwtest CORE=msx COMMIT=<commit the bitstream was built from>         # Kings Valley 2, 59.92 Hz

The bitstream goes to `/media/fat/_Computer/MSX.rbf`. For `FLOW=mister make package`, `games.sh` builds the start
medium (`boot.vhd` and one card for each ROM). Game change: push F12 and mount the card of the game (top-level
README).

## Profile

| File | Content |
|---|---|
| `core.tcl` | SDRAM geometry, BRAM region for VRAM pages 0/1, cache with `G_CACHE_COL_HIGH`, pacer 21/22 of 90 MHz. The header explains each value. |
| `rules.py` | source rules for Vivado (OCM VHDL instantiation, Quartus syntax) |
| `patches/0001` | hides the ROM of the ESE-SCC after a mount of a card (game change). It connects `scc_rom_hide.vhd`. |
| `scc_rom_hide.vhd` | the logic of patch 0001 (testbench `tb/scc_rom_hide_tb.vhd`) |
| `pll.vhd` | replacement of the Quartus PLL: gated master, `clk_sys` every 4th pulse |
| `core.xdc` | generated clocks of `pll.vhd` |
| `core_ultrascale.xdc` | UltraScale(+) only: keeps the BUFGCE cascade of `pll.vhd`. Without it, opt_design makes the cascade parallel and the generated clock loses its source. |
| `games.sh` | start medium of the core |
| `hwtest.cfg` | game, keyboard input and frame rate of `make hwtest` |

Lessons of the port:

- doc/PORTING.md
- doc/ARCHITECTURE.md §3 (memory map, §3.4)
- doc/ARCHITECTURE.md §5.3 (game change)

## Gaps

- Saves to the SD card image work (`STATUS.md`, row `saves`). We did not check the battery SRAM of cartridges.
- Synthesis reports `Netlist 29-358` for `REG_R9_PAL_MODE` (`rtl/VIDEO/vdp_register.vhd`). Its asynchronous reset
  loads the signal `FORCED_V_MODE`. The result is an FDCPE with asynchronous set and clear. This is harmless while
  `FORCED_V_MODE` is stable during reset (it is a core setting). We did not change the core for it.
