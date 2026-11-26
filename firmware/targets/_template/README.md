# Board template (`_template`)

This directory is not a board. `Makefiles/common.mk` and `firmware/common/scripts/selfcheck.sh` skip each
`firmware/targets/_*` directory. The template is the starting point for a new board. The board contract in
`doc/PORTING.md` §7.1 tells what the board must supply to Main_MiSTer and the cores (PS ports, clocks, address
map, DDR reservation). All files here come from `zybo-z7-20`.

- Do not change the lines with the mark `CONTRACT`.
- The lines with the mark `TODO` (and each `<...>`) are board work.

| File | Becomes | Content |
|---|---|---|
| `platform.mk` | `platform.mk` | flows, kernel/U-Boot/boot settings, `MISTER_CORES`, `VIDEO_TX` |
| `scripts/2025.2/template_mister.tcl` | `scripts/<ver>/<board>_mister.tcl` | block design generator for every core (`CORE=`, `VIDEO=`) |
| `constraints/template_mister.xdc` | `constraints/<board>_mister.xdc` | pins (TODO), clock groups (CONTRACT) |
| `dts/mister.dtsi` | nodes in `dts/<dts name>.dts` | DDR reservation for the PL, `uio`, `fclk-enable` |

## New board

```bash
b=<board>
cp -r firmware/targets/_template firmware/targets/$b
cd firmware/targets/$b
mv scripts/2025.2/template_mister.tcl scripts/2025.2/${b}_mister.tcl
mv constraints/template_mister.xdc constraints/${b}_mister.xdc
sed -i "s/<board>/$b/g" platform.mk scripts/2025.2/${b}_mister.tcl constraints/${b}_mister.xdc
grep -rn "TODO\|<[a-z]" .        # what is left to do
```

Then:

1. Put the board files of the vendor into `board_files/`. The generator sets `board_part_repo_paths` to this
   directory. Set the part and `board_part` in `<board>_mister.tcl`.
2. Write the pins into `<board>_mister.xdc` from the master XDC of the board. Add HDMI, codec, LEDs and buttons in
   the generator (`TODO` blocks).
3. Make `dts/<dts name>.dts`: the board DTS of the kernel plus the nodes of `dts/mister.dtsi`.
4. Fill `files/` as in `zybo-z7-20/files/`:
   - FSBL
   - `kernel.config` (only board options: the options of MiSTer are in `firmware/common/linux/kernel.config`)
   - `uboot.config`, `uEnv.txt`
   - the codec setup under `files/mister-rootfs/` (Zybo: `ssm2603-init.sh` + `ssm2603.service`)
5. Run `make test`. Its step 3 does a dry run of each flow action of the new board.
6. Run `PLATFORM=<board> FLOW=vivado make setup`.
7. Run `PLATFORM=<board> FLOW=vivado CORE=menu make create build`.
8. Write a `STATUS.md` like `zybo-z7-20/STATUS.md` and a `README.md` with the board details.
