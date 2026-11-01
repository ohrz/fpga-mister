# Board template (`_template`)

Not a board: `Makefiles/common.mk` and `firmware/common/scripts/selfcheck.sh` skip every
`firmware/targets/_*` directory. It is the starting point for a new board; what the board has to provide
to Main_MiSTer and the cores (PS ports, clocks, address map, DDR reservation) is the board contract in
`doc/PORTING.md` §7.1. Everything here is taken from `zybo-z7-20`; lines marked `CONTRACT` stay as they
are, lines marked `TODO` (and every `<...>`) are board work.

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

1. `board_files/`: the vendor's board files (the generator sets `board_part_repo_paths` to it), part and
   `board_part` in `<board>_mister.tcl`.
2. Pins in `<board>_mister.xdc` from the board's master XDC; HDMI, codec, LEDs, buttons in the generator
   (`TODO` blocks).
3. `dts/<dts name>.dts`: the kernel's board DTS plus the nodes of `dts/mister.dtsi`.
4. `files/`: FSBL, `kernel.config`, `uboot.config`, `uEnv.txt` as in `zybo-z7-20/files/`; codec setup under
   `files/mister-rootfs/` (Zybo: `ssm2603-init.sh` + `ssm2603.service`).
5. `make test` (step 3 dry-runs every flow action of the new board), then
   `PLATFORM=<board> FLOW=vivado make setup` and `PLATFORM=<board> FLOW=vivado CORE=menu make create build`.
6. A `STATUS.md` like `zybo-z7-20/STATUS.md` and a `README.md` with the board details.
