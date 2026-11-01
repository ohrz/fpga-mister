# fpga-mister

A port of the [MiSTer FPGA](https://github.com/MiSTer-devel) platform to AMD/Xilinx Zynq boards. Instead of
the Intel Cyclone V SoC of the DE10-Nano, the MiSTer framework (`sys/`), the ARM application Main_MiSTer and
a handful of MiSTer cores run on a Zynq-7000 with Vivado 2025.2 block designs: ROMs and disk images on the SD card,
USB and Bluetooth game controllers (e.g. a PS5 DualSense) through Linux on the ARM cores, and video over HDMI.

> **Standing on the shoulders of giants.** This repository is a *port*, not an emulator of its own. Every
> emulated system, the framework, the menu and the ARM application were written by the MiSTer developers and
> by the authors of the original cores, over many years. fpga-mister reuses their work as it is (the few
> patches to the cores are small, documented and applied to a copy) and only adds the glue that a different FPGA
> family needs: replacements for Intel-specific building blocks, an SDRAM
> emulation on top of the Zynq DDR, a Zynq backend for Main_MiSTer, an HDMI transmitter, board files and build
> flows. None of this would exist without the projects listed under [Credits](#credits). Please read that
> section first.

This is a hobby project. It is not affiliated with or endorsed by the MiSTer project, its core authors,
AMD/Xilinx or Digilent. **Please report problems of this port here, not to the upstream projects.**

## Credits

fpga-mister builds on the following projects. They are cloned at pinned revisions
([firmware/common/checkouts.txt](firmware/common/checkouts.txt)), never modified in place, and keep their own
licenses ([LICENSES/README.md](LICENSES/README.md)).

| Project | Authors | What fpga-mister takes from it |
| ------- | ------- | ------------------------------ |
| [MiSTer-devel](https://github.com/MiSTer-devel) | the MiSTer project, founded and maintained by Alexey Melnikov (Sorgelig), and its many contributors | the whole platform this port is about |
| [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) | Alexey Melnikov (Sorgelig) and contributors; the `ascal` scaler by TEMLIB (Grabulosaure); parts of `sys/` go back to the [MiST](https://github.com/mist-devel) project of Till Harbaum | the framework `sys/` (`sys_top.v`, `hps_io`, OSD, scandoubler, `ascal`, audio): it stays the top level of every design here |
| [Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) | Alexey Melnikov (Sorgelig) and contributors | the ARM application (menu, OSD, file loading, input); this repository only adds a Zynq register and loading backend as patches |
| [Menu_MiSTer](https://github.com/MiSTer-devel/Menu_MiSTer) | Alexey Melnikov (Sorgelig) and contributors | the menu core `menu.rbf` |
| [MSX_MiSTer](https://github.com/MiSTer-devel/MSX_MiSTer) | MiSTer port by Sorgelig and contributors of the MSX core of [KdL](http://gnogni.altervista.org/) (OCM-PLD), based on the One Chip MSX / ESE MSX-SYSTEM3 by Kazuhiro Tsujikawa (ESE Artists' factory), with thanks in its sources to t.hara, caro, mygodess and the MSX Resource Center community | the MSX2/2+ core |
| [SNES_MiSTer](https://github.com/MiSTer-devel/SNES_MiSTer) | written by [srg320](https://github.com/srg320) (Sergiy Dvodnenko), with Sorgelig and contributors | the SNES core with its enhancement chips |
| [PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) | Robert Peip (FPGAzumSpass) and contributors | the PlayStation core |
| [N64_MiSTer](https://github.com/MiSTer-devel/N64_MiSTer) | Robert Peip (FPGAzumSpass) and contributors | the Nintendo 64 core |
| [Digilent vivado-library](https://github.com/Digilent/vivado-library), [vivado-boards](https://github.com/Digilent/vivado-boards), [digilent-xdc](https://github.com/Digilent/digilent-xdc) | Digilent, Inc. | `rgb2dvi` (DVI output), Zybo Z7-20 board files and master constraints |
| [linux-xlnx](https://github.com/Xilinx/linux-xlnx), [u-boot-xlnx](https://github.com/Xilinx/u-boot-xlnx), [soc-prebuilt-firmware](https://github.com/Xilinx/soc-prebuilt-firmware) | AMD/Xilinx and the Linux and U-Boot communities | kernel (including `fpga_manager`, `hid-playstation`, Bluetooth), boot loader, boot firmware |
| [Ubuntu](https://ubuntu.com/), [BlueZ](https://www.bluez.org/), [GHDL](https://github.com/ghdl/ghdl) | their communities | root file system, Bluetooth stack, the VHDL simulator of all testbenches |

The names above are taken from the upstream repositories, their source headers and commit histories; the
contributor lists of those repositories are the complete record. If you enjoy these cores, please support
their authors through the MiSTer project and their own channels.

What is new in this repository: the Zynq glue in `firmware/common/mister/` (`mister_zynq`, the SDRAM
emulation, the Avalon-to-AXI bridges, the clock gating, replacements of Intel megafunctions, core profiles with
source rules and patches), the HDMI transmitter `firmware/common/ip/hdmi-tx`, the Main_MiSTer Zynq patches,
the board support for the Zybo Z7-20 and the build flows. The development of this code and its documentation
was assisted by an AI coding assistant (Claude, Anthropic).

## Quick start: the SD card image

Every [release](https://github.com/ohrz/fpga-mister/releases) has a ready SD card image for the Zybo Z7-20,
`fpga-mister-zybo-z7-20-<version>.img.xz`, with all cores of the board, Main_MiSTer and the Linux system. **It
contains no ROMs, BIOS files or games**: you add the ones you are legally entitled to use.

1. Write the image to a microSD card of at least 8 GB, with [balenaEtcher](https://etcher.balena.io/),
   [Raspberry Pi Imager](https://www.raspberrypi.com/software/) ("Use custom") or on Linux:

       xz -dc fpga-mister-zybo-z7-20-<version>.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

2. Copy your files to the FAT32 partition `MISTER` of the card (it is `/media/fat` on the board, as on MiSTer):

   | Core | Folder | What you add |
   | ---- | ------ | ------------ |
   | MSX (`_Computer/MSX.rbf`) | `games/MSX/` | nothing: `boot.vhd` (MSX-DOS2, Nextor, ROM loader) is included; game ROMs go into `boot.vhd` (a FAT16 disk image) or a card made by [games.sh](firmware/common/mister/cores/msx/games.sh) |
   | SNES (`_Console/SNES.rbf`) | `games/SNES/` | game images |
   | PSX (`_Console/PSX.rbf`) | `games/PSX/` | the BIOS as `boot.rom`, CD images |
   | N64 (`_Console/N64.rbf`) | `games/N64/` | the PIF boot ROMs and game images ([core README](firmware/common/mister/cores/n64/README.md)) |

3. Board: jumper JP5 on SD, JP2 on HOST (USB host). Monitor on the HDMI TX port (1280×720, sound over HDMI and
   on the headphone jack), USB keyboard or gamepad on the USB port (a hub for more than one device, e.g. a
   Bluetooth adapter), Ethernet optional (DHCP). Power on: Main_MiSTer starts about 15 seconds later (Linux boots in 12 s)
   with the menu; F12 opens the OSD.

Login on the serial console (USB-UART, 115200 baud) or over SSH (host name `mister-zybo-z7-20`, address from DHCP): users `root` and `fpga`,
password **`mister`**; change it with `passwd`. Root logs in over SSH with a key only: put your public key into
`linux/authorized_keys` on the FAT partition, it is installed at every boot. N64 runs outside its timing
constraints and is experimental (see [Status](#status)).

## Status

| Platform     | Device                   | Linux | Status |
| ------------ | ------------------------ | ----- | ------ |
| `zybo-z7-20` | Zynq-7020 (Digilent Zybo Z7-20) | armhf | menu, MSX, SNES, PSX and N64 run from the SD card; DVI or HDMI with sound |
| ZynqMP (e.g. ZCU106) | ZU7EV | arm64 | not started; what a ZynqMP board still needs: [doc/PORTING.md](doc/PORTING.md) §7.1 |

The Zybo Z7-20 (XC7Z020) is small for the larger cores, so they run with compromises: SNES without the
SPC7110 chip and with 128 KB backup RAM, PSX without savestates, rewind, cheats and fast forward, N64 with most
OSD options fixed and at full clock *outside* its timing constraints (it works on the test board, but is not
guaranteed). The per-core `README.md` files list the details.

What works where, per core, board and stage (stages: [doc/PORTING.md](doc/PORTING.md) §3.0). The block below is
generated by `make status-update` from the `STATUS.md` files; `make test` checks them. `make build-matrix
[UPDATE=1]` builds every board x core design and fills in the timing rows.

<!-- status:begin -->
**zybo-z7-20**

| Core | prepare | ooc | timing | load | picture | audio | input | speed | saves | extras |
|---|---|---|---|---|---|---|---|---|---|---|
| menu | Scr | – | Tim | HW | HW | – | HW | HW | – | – |
| msx | Scr | OOC | Tim | HW | HW | HW | HW | HW | HW | HW |
| n64 | Scr | OOC | FAIL | HW | HW | HW | – | HW | – | – |
| psx | Scr | OOC | Tim | HW | HW | HW | HW | HW | HW | – |
| snes | Scr | OOC | Tim | HW | HW | HW | HW | HW | BLK | BLK |

| Board | boot | linux | main | video | audio | input | sd | net | switch |
|---|---|---|---|---|---|---|---|---|---|
| zybo-z7-20 | HW | HW | HW | HW | HW | HW | HW | HW | HW |

HW = measured on the hardware, Tim = timing after route, OOC = out-of-context synthesis, Sim = testbench, Scr = script (rules, checks), BLK = blocked, – = open. Details and measured values: `firmware/common/mister/cores/<core>/STATUS.md`, `firmware/targets/<board>/STATUS.md`; generated by `make status`.
<!-- status:end -->

## Documentation

| File | Content |
| ---- | ------- |
| [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md) | architecture of the port: block design, HPS bus, memory (SDRAM to DDR), video, software |
| [doc/PORTING.md](doc/PORTING.md) | guide for the next core or board: building blocks, procedure, profiles, rules and patches, gaps |
| [firmware/common/mister/README.md](firmware/common/mister/README.md) | layout and conventions of the MiSTer part |
| `firmware/common/mister/cores/<core>/README.md`, `STATUS.md` | core profiles and their state per board |
| [firmware/targets/zybo-z7-20/README.md](firmware/targets/zybo-z7-20/README.md) | board details |
| [firmware/common/ip/hdmi-tx/README.md](firmware/common/ip/hdmi-tx/README.md) | HDMI transmitter with sound |
| [LICENSES/README.md](LICENSES/README.md) | licenses of the own work, the derived files and the third-party files |

## Requirements

- Vivado/Vitis 2025.2, environment sourced: `source /opt/Xilinx/2025.2/Vitis/settings64.sh` (the cross
  compilers of the kernel, U-Boot and Main_MiSTer builds come from Vitis). The version is taken from `XILINX_VIVADO`.
- Host packages: `bison flex libssl-dev debhelper bc rsync cpio libncurses-dev u-boot-tools
  device-tree-compiler libgnutls28-dev uuid-dev`, for the rootfs `debootstrap qemu-user-binfmt binfmt-support`
  (on older Ubuntu releases `qemu-user-static`), for the MSX boot medium and the SD card image
  `unzip fdisk dosfstools mtools e2fsprogs xz-utils`.
- Newer hosts (checked on Ubuntu 26.04): Vivado 2025.2 needs `libncurses.so.5`/`libtinfo.so.5` (symlinks to the
  `.so.6` libraries work); the Rust coreutils of Ubuntu 25.10+ break the U-Boot (`dd conv=block,sync`) and kernel
  package (`install -D` in parallel) builds, use GNU coreutils (`sudo apt install coreutils-from-gnu`).
- `ghdl` for the VHDL testbenches (`make test`); the benches with Xilinx primitives use the unisim VHDL sources of
  the Vivado installation (`$XILINX_VIVADO/data/vhdl/src/unisims`, override with `UNISIM_SRC=<dir>`).
- Lab addresses (TFTP/NFS server, board IP) are placeholders in `firmware/common/lab.mk`; put your own into
  `lab.local.mk` in the repository root (not tracked). `make lab` prints them.
- The hardware tests (`make hwtest`, `firmware/common/mister/tools/hwtest.py`) need SSH access as root to the board
  (key login); picture and sound are judged on the HDMI output.

## Usage

All commands from the repository root:

    PLATFORM=<platform> FLOW=<flow> [TOPLEVEL=<design>] make <action>
    make help                      # flows and actions
    FLOW=<flow> make help          # actions, variables and platforms of one flow
    make test                      # hardware-free self-check (scripts, make -n of every flow x board x action,
                                   # GHDL testbenches, patches and core profiles against the pinned checkouts)
    make status                    # core x board x stage matrix from the STATUS.md files

| Flow     | Actions                                              | Output |
| -------- | ---------------------------------------------------- | ------ |
| `vivado` | `create build xsa-export launch setup clean`         | `firmware/build/<p>/<ver>/hw/` (project, `bins/<design>.bit(.bin)`, `<design>.xsa`) |
| `kernel` | `build checkout patch collect clean`                 | `firmware/build/<p>/<ver>/kernel/` (zImage, board DTB, Debian packages) |
| `uboot`  | `checkout build clean`                               | `firmware/build/<p>/<ver>/u-boot-xlnx/` |
| `boot`   | `copy clean tftpboot`                                | `firmware/build/<p>/<ver>/boot/` (boot.scr, BOOT.bin, kernel, DTBs, uEnv.txt) |
| `rootfs` | `build image write flash package clean`              | `firmware/build/<p>/ubuntu24.04-console-rootfs/`, `firmware/build/<p>/fpga-mister-<p>-<version>.img(.xz)` (SD card image) |
| `mister` | `setup build package clean`                          | `firmware/build/<p>/mister/MiSTer`, `firmware/build/<p>/mister/rootfs/media/fat`, `firmware/build/<p>/mister-rootfs.tgz` (systemd units) |

### PL design

    PLATFORM=zybo-z7-20 FLOW=vivado make setup                                  # once: vivado-library, Template_MiSTer and the cores
    PLATFORM=zybo-z7-20 FLOW=vivado CORE=msx make create build                  # design zybo-z7-20_msx (DVI)
    PLATFORM=zybo-z7-20 FLOW=vivado CORE=menu make create build                 # menu core (menu.rbf)
    PLATFORM=zybo-z7-20 FLOW=vivado CORE=msx VIDEO=hdmi make create build       # zybo-z7-20_msx_hdmi: HDMI with sound
    PLATFORM=zybo-z7-20 FLOW=vivado CORE=snes VIDEO=hdmi make create build      # SNES core (likewise psx, n64)
    PLATFORM=zybo-z7-20 FLOW=vivado TOPLEVEL=zybo-z7-20_snes_hdmi make create build  # the same by design name

A MiSTer design `<board>_<core>[_hdmi]` has no Tcl file of its own: the board design `zybo-z7-20_mister.tcl`
generates it for every core with a profile `firmware/common/mister/cores/<core>/core.tcl` (`FLOW=vivado help` lists
the cores). `CORE` and `VIDEO` (short for `VIDEO_TX`, `dvi` or `hdmi`) name the design; `TOPLEVEL=<board>_<core>[_hdmi]`
is the same, so the boot and mister flows keep using design names.

The default designs send DVI (Digilent `rgb2dvi`, no sound on HDMI). `VIDEO=hdmi` selects the VHDL transmitter
`hdmi_out` of this repository, which sends HDMI with the core's sound in data islands
(`firmware/common/ip/hdmi-tx`); the headphone jack keeps playing (doc/ARCHITECTURE.md §4.1). `VIDEO_TX=hdmi` (board
profile, default `dvi`) makes `FLOW=boot` (BOOT.bin) and `FLOW=mister` (package) take the `_hdmi` designs:

    VIDEO_TX=hdmi PLATFORM=zybo-z7-20 FLOW=boot make copy
    VIDEO_TX=hdmi PLATFORM=zybo-z7-20 FLOW=mister make package

External sources are pinned in `firmware/common/checkouts.txt` and cloned to `_Checkouts/` by
`firmware/common/scripts/checkout.sh`; they are never edited, the port's changes live in
`firmware/common/mister/` and are applied to a copy in `firmware/build/src/`.

### Main_MiSTer and the SD card contents

    PLATFORM=zybo-z7-20 FLOW=mister make setup build package

Main_MiSTer is built from the pinned checkout with the patches in `firmware/common/mister/patches/Main_MiSTer`
(`make ZYNQ=1`: register access over AXI GP0 at 0x4000_0000, cores loaded through the Linux `fpga_manager`) by the
armhf cross compiler of Vitis. `package` collects `/media/fat` (MiSTer, `MiSTer.ini` with `video_mode=0`, the
bitstreams of `MISTER_CORES` of the board profile as `<folder>/<core>.rbf`, the menu core as `menu.rbf`), the FAT
partition of the SD card image, and the systemd units, which `FLOW=rootfs make build` installs. On the Zybo,
`MISTER_CORES` packages all five cores (MSX in `_Computer`, SNES, PSX and N64 in `_Console`). Details:
`doc/ARCHITECTURE.md` §5.

The MSX core boots from `games/MSX/boot.vhd`, built by `firmware/common/mister/cores/msx/games.sh` (the FAT16 SD card
of the OCM core with MSX-DOS2 and ROM loaders) and `config/MSX.CFG` (OSD Slot1 = MegaSCC+ 1MB). Put your own test
ROMs (`*.rom`) into `roms/` (ignored by Git); a single ROM is loaded by `AUTOEXEC.BAT` with `ROMLOAD /R` and started
like a cartridge. With several ROMs, `boot.vhd` lists them and every ROM also gets its own card
`games/MSX/<rom name>.vhd` that starts it. To change the game: F12, first line, choose the game's card
(doc/ARCHITECTURE.md §5.3).

### Linux: kernel, rootfs, boot files, SD card image

    ./build-all.sh zybo-z7-20                               # bitstreams if missing, U-Boot, Main_MiSTer (FLOW=mister),
                                                            # kernel, rootfs, boot files, SD card image (sudo)
    VIDEO_TX=hdmi BOOT_NETBOOT=0 MISTER_ROMS= ./build-all.sh zybo-z7-20     # the release image
    PLATFORM=zybo-z7-20 FLOW=rootfs SDCARD=/dev/sdX make write              # image to a card in a card reader
    PLATFORM=zybo-z7-20 FLOW=rootfs make flash                              # image to the card in the running board

The rootfs is a minimal Ubuntu 24.04 (systemd, SSH, DHCP, the libraries of Main_MiSTer, BlueZ); the image has a
FAT32 partition with the boot files and `/media/fat` and an ext4 partition with the rootfs. `flash` rewrites the
card in the board over Ethernet (busybox from RAM, read-back checksum, then reboot), needs root key login on the
board and `BOARD_IP` (`lab.local.mk`). Details: `doc/ARCHITECTURE.md` §5.4.

Build times on the development host (AMD Ryzen AI Max+ 395, 16 cores / 32 threads, 128 GB, Vivado 2025.2,
three designs in parallel with `VIVADO_JOBS=10`):

| Step | Time |
| ---- | ---- |
| `FLOW=vivado create build`, menu / MSX / SNES / PSX / N64 (HDMI) | 4 / 5 / 9 / 9 / 21 min |
| `FLOW=kernel build` (linux-xlnx 6.12, `bindeb-pkg`) | about 2 min |
| `FLOW=uboot build`, `FLOW=mister build`, FSBL (xsct) | under 1 min each |
| `FLOW=rootfs build` (debootstrap + chroot through qemu) | about 5 min |
| `FLOW=rootfs image` (FAT32 4 GB + ext4, xz) | under 1 min |
| `FLOW=rootfs flash` (5 GB over Ethernet, SD card write at about 9 MB/s, read-back check) | about 17 min |

The device tree reserves 0x1FF0_0000-0x3FFF_FFFF of the DDR for the PL and Main_MiSTer: the same physical
range the DE10-Nano gives the FPGA, plus the hand-over page of Main_MiSTer at 0x1FFF_F000.

## Repository

    Makefile, Makefiles/<flow>/Makefile, Makefiles/common.mk     flows (board-neutral)
    Makefiles/arch-{zynq,zynqmp}.mk                               defaults of the board profiles per architecture
    firmware/targets/<platform>/platform.mk                       board profile (flows, kernel/U-Boot/boot variables)
    firmware/targets/<platform>/                                  board files, constraints, design Tcl, DTS, boot files
    firmware/targets/_template/                                   starting point for a new board
    firmware/common/mister/                                       the MiSTer port, board-neutral (layout: its README.md)
      cores/<core>/                                               core profiles (core.tcl, rules.py, patches, replacement files), _template/
      hdl/, tb/                                                   own VHDL and its GHDL testbenches
      scripts/                                                    core_survey.py, prepare_sources.py, status.py, Vivado Tcl helpers
      patches/Main_MiSTer/                                        patches of Main_MiSTer (Zynq backend)
      files/rootfs/, tools/                                       systemd units of Main_MiSTer; helpers for tests on the board
    firmware/common/ip/hdmi-tx/                                   HDMI transmitter with sound (VHDL, GHDL testbench)
    firmware/common/checkouts.txt, scripts/checkout.sh            external sources with URL, branch and pin
    firmware/common/scripts/                                      Vivado build/export, rootfs, selfcheck (make test)
    firmware/build/                                               build output (not tracked)
    _Checkouts/                                                   external sources (not tracked): MiSTer framework, cores and
                                                                  Main, vivado-library, soc-prebuilt-firmware
    roms/                                                         test ROMs for the MSX start medium (not tracked)
    doc/                                                          ARCHITECTURE.md (the port), PORTING.md (next core or board)

## License

The own work of this repository (VHDL, scripts, Makefiles, documentation) is licensed under the
**GNU General Public License v2.0 or later** ([LICENSE](LICENSE), SPDX `GPL-2.0-or-later`), the license of the
MiSTer framework it extends. Files derived from other projects keep the license of their origin:

| Path | Derived from | License |
| ---- | ------------ | ------- |
| `firmware/common/mister/cores/msx/` (patches, replacement files) | [MSX_MiSTer](https://github.com/MiSTer-devel/MSX_MiSTer) (`MSX.sv`) | GPL-2.0-or-later |
| `firmware/common/mister/cores/psx/` (patches, replacement files) | [PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) | GPL-2.0 |
| `firmware/common/mister/cores/n64/` (patches, replacement files) | [N64_MiSTer](https://github.com/MiSTer-devel/N64_MiSTer) | GPL-3.0 |
| `firmware/common/mister/cores/snes/` (patches, replacement files) | [SNES_MiSTer](https://github.com/MiSTer-devel/SNES_MiSTer) | GPL-3.0 |
| `firmware/common/mister/patches/Main_MiSTer/` | [Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) | GPL-3.0 |
| `firmware/targets/zybo-z7-20/board_files/` | [Digilent vivado-boards](https://github.com/Digilent/vivado-boards) | MIT (Digilent) |
| `firmware/targets/zybo-z7-20/constraints/Zybo-Z7-Master.xdc` | [Digilent digilent-xdc](https://github.com/Digilent/digilent-xdc) | MIT (Digilent) |

Details and the license texts of the third-party parts: [LICENSES/README.md](LICENSES/README.md). A bitstream built
from this repository combines the framework with a core; it is covered by the license of that core as well
(GPL-2.0 for PSX, GPL-3.0 for N64 and SNES, and the license of the OCM-PLD sources for MSX). The MiSTer framework,
the cores, Main_MiSTer and the Digilent IP are not part of this repository: the flows clone them at pinned
revisions (`firmware/common/checkouts.txt`).

## Legal notes

- This repository contains **no ROMs, BIOS images, PIF ROMs, game or disk images** and no other copyrighted
  content of third parties. The flows and tests expect such files in places that are not tracked (`roms/`,
  `/media/fat/games/<core>/` on the SD card). Use only images you are legally entitled to use; this project does
  not tell you where to get them.
- Game titles that appear in comments and status notes only describe which software a test was run with.
- MiSTer, Zynq, Vivado, Zybo, HDMI and other names are trademarks of their respective owners; their use here
  is purely descriptive.
