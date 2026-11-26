# Menu (Menu_MiSTer)

This profile is for the menu core `menu.rbf` of [Menu_MiSTer](https://github.com/MiSTer-devel/Menu_MiSTer) (Sorgelig
and contributors). Main_MiSTer loads this core at the start and between two cores. The checkout `Menu_MiSTer` is at
the pin in `firmware/common/checkouts.txt`. What works where: [STATUS.md](STATUS.md).

## Build and test

    PLATFORM=zybo-z7-20 FLOW=vivado CORE=menu VIDEO=hdmi make create build    # design zybo-z7-20_menu_hdmi
    make hwtest CORE=menu COMMIT=<commit the bitstream was built from>        # noise picture, no frame rate

The bitstream goes to `/media/fat/menu.rbf`.

## Profile

| File | Content |
|---|---|
| `core.tcl` | SDRAM geometry (answers as a 32 MB module), master 85 MHz, pacer 1/1. The header explains each value. |
| `rules.py` | 4 source rules (`inout reg SDRAM_DQ`, clock of the LFSR) |
| `lfsr.vhd` | clocked LFSR instead of the free-running lcell ring of `rtl/lfsr.v` (background noise) |
| `pll.vhd` | replacement of the Quartus PLL: the master clock is `clk_sys` and `CLK_VIDEO` |
| `hwtest.cfg` | load and picture check of `make hwtest` |

## Gaps

- The menu picture runs at 51 Hz instead of 60 Hz (calculated: 60 Hz × 85 MHz / 100 MHz). The scaler sends 720p60.
- `DDRAM_*` is tied off. Thus the Linux console / framebuffer mode of the menu shows nothing.
