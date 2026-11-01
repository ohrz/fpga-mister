#!/bin/bash
# Everything the SD card of one platform needs, in this order:
#
#   ./build-all.sh <platform>
#
#   1. bitstream of the boot design (BOOT_DEFAULT_TOPLEVEL), only when hw/bins/<design>.bit is missing:
#      FLOW=vivado create + build (Vivado, long); plus xsa-export when the FSBL has to be built
#   2. U-Boot (boards with BOOT_FIRMWARE=files, the Zynq-7000 boards), only when u-boot.elf is missing:
#      FLOW=uboot checkout + build
#   3. boards with FLOW=mister: the bitstreams of MISTER_CORES (when hw/bins/<design>.bit.bin is missing),
#      FLOW=mister setup + build + package (Main_MiSTer and /media/fat, built into the rootfs)
#   4. FLOW=kernel build, FLOW=rootfs build, FLOW=boot copy, FLOW=rootfs image (the SD card image)
#
# Needs the Xilinx environment (source <Xilinx>/<version>/Vivado/settings64.sh) and sudo
# for the rootfs and the image.  The rootfs directory must not exist
# (PLATFORM=<platform> FLOW=rootfs make clean).  Stops at the first error.
# The release image: VIDEO_TX=hdmi BOOT_NETBOOT=0 MISTER_ROMS= ./build-all.sh <platform>
# (HDMI designs with sound, uEnv.txt without the lab network, no game images).

set -euo pipefail

PLATFORM=${1:?usage: ./build-all.sh <platform>}
export PLATFORM

cd "$(dirname "$0")"

# a variable of the board profile as the boot flow sees it
profile() {
    make -s --no-print-directory -f Makefiles/boot/Makefile -f - pv <<< "pv: ; @echo \$($1)"
}

ver=$(profile VIVADO_VER)
design=$(profile BOOT_DEFAULT_TOPLEVEL)
firmware=$(profile BOOT_FIRMWARE)
hw=firmware/build/$PLATFORM/$ver/hw

if [ ! -f "$hw/bins/$design.bit" ]; then
    make FLOW=vivado setup
    make FLOW=vivado TOPLEVEL="$design" create
    make FLOW=vivado TOPLEVEL="$design" build
fi
if [ "$firmware" = files ]; then
    if [ ! -f "firmware/targets/$PLATFORM/files/fsbl/fsbl.elf" ] && [ ! -f "$hw/$design.xsa" ]; then
        make FLOW=vivado TOPLEVEL="$design" xsa-export
    fi
    if [ ! -f "firmware/build/$PLATFORM/$ver/u-boot-xlnx/u-boot.elf" ]; then
        make FLOW=uboot checkout
        make FLOW=uboot build
    fi
fi

if [[ " $(profile PLATFORM_FLOWS) " == *" mister "* ]]; then
    for core in $(profile MISTER_CORES); do
        if [ ! -f "$hw/bins/${core%%:*}.bit.bin" ]; then
            make FLOW=vivado setup
            make FLOW=vivado TOPLEVEL="${core%%:*}" create
            make FLOW=vivado TOPLEVEL="${core%%:*}" build
        fi
    done
    make FLOW=mister setup
    make FLOW=mister build
    make FLOW=mister package
fi

make FLOW=kernel build
make FLOW=rootfs build
make FLOW=boot   copy
make FLOW=rootfs image
