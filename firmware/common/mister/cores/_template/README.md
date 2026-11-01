# <Core> (<Checkout>_MiSTer)

<What the core is, in one sentence>, checkout `<Checkout>_MiSTer` at the pin in `firmware/common/checkouts.txt`.
What works where: [STATUS.md](STATUS.md).

## Build and test

    PLATFORM=zybo-z7-20 FLOW=vivado CORE=<core> VIDEO=hdmi make create build
    make hwtest CORE=<core> COMMIT=<commit the bitstream was built from>

The bitstream goes to `/media/fat/<_Console|_Computer|...>/<Core>.rbf`, games to `/media/fat/games/<Core>/`.

## Profile

| File | Content |
|---|---|
| `core.tcl` | <SDRAM geometry, regions, cache, pacer>; the header explains every value |
| `rules.py` | <n> source rules for Vivado |
| `patches/NNNN-<topic>.patch` | <changes of behaviour, one line each> |
| `pll.vhd` | replacement of the Quartus PLL |
| `core.xdc` | generated clocks of `pll.vhd`, the path exceptions of the core's `.sdc` |
| `hwtest.cfg` | game, input and frame rate of `make hwtest` |

Profile decisions and lessons of the port: <short list, links into doc/PORTING.md and doc/ARCHITECTURE.md>.

## Gaps

- <what does not work yet, and why>
