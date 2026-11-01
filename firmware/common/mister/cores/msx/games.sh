#!/bin/bash
# ----------------------------------------------------------------------------------
#  Title      : Start media of the MSX core: games/MSX/boot.vhd, one card per ROM
#  Project    : fpga-mister
#  File       : games.sh
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-28
# ----------------------------------------------------------------------------------
#  Description: games.sh <games dir> [<rom dir>]
#               Builds <games dir>/boot.vhd, the SD card of the OCM/KdL MSX core
#               (MSX_MiSTer has no ROM loader in the OSD; Main_MiSTer mounts boot.vhd
#               of games/MSX by itself). The same card as sdcreate.cmd of
#               MSX_MiSTer/Utils/sdcreate.zip, without Windows and without root:
#                 - MBR with one primary FAT16 partition at 1 MiB (sfdisk, mkfs.fat)
#                 - OCM-BIOS.DAT as first file, so it starts at the first data cluster
#                   (checked against the image), then MSX-DOS2/Nextor, COMMAND2.COM, the
#                   OS files, HELP/, UTILS/ (EXECROM, ROMLOAD, ...), MM/ (file manager)
#                 - the *.rom files of <rom dir> in the root directory with 8.3 names;
#                   with exactly one ROM, AUTOEXEC.BAT loads it with ROMLOAD /R into the
#                   ESE-SCC and resets, so the BIOS starts it like a cartridge (EXECROM from
#                   MSX-DOS leaves VRAM 0x2000-0x201F at F4, Kings Valley shows it as tile 0);
#                   with several ROMs it lists them
#                 - with several ROMs also <games dir>/<rom name>.vhd per ROM, the same card
#                   with only that ROM (started at once): chosen in the OSD with Mount *.VHD.
#                   A reset keeps the loaded ROM in the ESE-SCC and the BIOS starts it again,
#                   so a game change boots the new card with OSD Slot1 = Empty first (MSX-DOS
#                   starts, ROMLOAD finds no cartridge), then Slot1 = MegaSCC+ and "autoexec"
#                 - <games dir>/../../config/MSX.CFG with OSD Slot1 = MegaSCC+ 1MB (status bit 4),
#                   the ESE-SCC that ROMLOAD needs, and Reset after Mount (bit 14); an
#                   existing MSX.CFG is kept
#               Needs unzip, sfdisk, mkfs.fat (dosfstools), mtools; MSX_VHD_MB sets the
#               size (default 64). Called by FLOW=mister make package for the core MSX.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
set -euo pipefail

games=${1:?usage: games.sh <games dir> [<rom dir>]}
roms=${2:-}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../../../.." && pwd)
sdcreate=$root/_Checkouts/MSX_MiSTer/Utils/sdcreate.zip
size_mb=${MSX_VHD_MB:-64}
part_lba=2048

export PATH=$PATH:/usr/sbin:/sbin
for t in unzip sfdisk mkfs.fat mcopy mmd; do
    command -v "$t" >/dev/null || { echo "games.sh: $t missing (sudo apt install unzip fdisk dosfstools mtools)" >&2; exit 1; }
done
[ -f "$sdcreate" ] || { echo "games.sh: $sdcreate missing (FLOW=vivado make setup)" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unzip -q "$sdcreate" -d "$tmp/sd"
export MTOOLS_SKIP_CHECK=1 MTOOLS_NO_VFAT=1

# make_vhd <image> [<rom>...]: the card with the system and the given ROMs
make_vhd() {
    local img=$1; shift
    local part_kib fs autoexec f n d b base k data bios rom_names=()

    # MBR + FAT16 partition from 1 MiB to the end (diskpart of sdcreate.cmd: one primary partition)
    truncate -s "${size_mb}M" "$img"
    printf 'label: dos\nstart=%d, type=6\n' "$part_lba" | sfdisk -q "$img"
    part_kib=$(( (size_mb * 1024 * 1024 / 512 - part_lba) / 2 ))
    mkfs.fat -F 16 -n MSXFAT16 --offset "$part_lba" -h "$part_lba" "$img" "$part_kib" >/dev/null
    fs="$img@@$(( part_lba * 512 ))"
    put() {   # put <file> <target path on the card>, 8.3 names in upper case (no long names)
        mcopy -i "$fs" "$1" "::$(tr '[:lower:]' '[:upper:]' <<<"$2")"
    }

    # the BIOS first (the IPL of the core reads it from the start of the data area), then the system
    put "$tmp/sd/sdbios/OCM-BIOS.DAT" OCM-BIOS.DAT
    for f in MSXDOS2.SYS NEXTOR.SYS COMMAND2.COM; do put "$tmp/sd/os/$f" "$f"; done
    for f in "$tmp"/sd/os/*; do
        n=$(basename "$f")
        case "${n^^}" in MSXDOS2.SYS|NEXTOR.SYS|COMMAND2.COM|AUTOEXEC.BAT) ;; *) put "$f" "$n" ;; esac
    done
    for d in help utils mm; do
        mmd -i "$fs" "::${d^^}"
        for f in "$tmp/sd/$d"/*; do
            n=$(basename "$f")
            case "$n" in *.txt|*.TXT) [ "$d" != help ] || continue ;; esac
            put "$f" "${d^^}/$n"
        done
    done

    # ROMs: 8.3 name from the file name (letters and digits, at most 8)
    autoexec=$(tr -d '\r' < "$tmp/sd/os/autoexec.bat")
    for f in "$@"; do
        b=$(basename "$f"); b=${b%.*}; b=${b//[^A-Za-z0-9]/}; b=${b:0:8}
        [ -n "$b" ] || b=GAME
        # unique on the card: Kings_Valley.rom and Kings_Valley_2_msx2.rom both give KINGSVAL
        base=${b^^}; k=1
        while [[ " ${rom_names[*]} " == *" ${b^^}.ROM "* ]]; do
            k=$((k + 1)); b=${base:0:$((8 - ${#k}))}$k
        done
        put "$f" "$b.ROM"
        rom_names+=("${b^^}.ROM")
        echo "games.sh: $f -> $(basename "$img"):\\${b^^}.ROM"
    done
    if [ ${#rom_names[@]} = 1 ]; then
        # ROMLOAD resets on success; the hint only shows when Slot1 has no ESE-SCC (game change)
        autoexec+=$'\n'"echo Starting ${rom_names[0]}"$'\n'"romload ${rom_names[0]} /r"
        autoexec+=$'\n'"echo"$'\n'"echo Set OSD Slot1 to MegaSCC+ 1MB, then type: autoexec"
        echo "games.sh: $(basename "$img"): AUTOEXEC.BAT starts ${rom_names[0]} (ROMLOAD /R)"
    elif [ ${#rom_names[@]} -gt 1 ]; then
        # no < > | in the text: COMMAND2 takes them as redirection or pipe, even after echo
        autoexec+=$'\n'"echo ROMs: ${rom_names[*]}"$'\n'"echo Start one with: romload NAME /r"
    fi
    printf '%s\r\n' "${autoexec//$'\n'/$'\r\n'}" > "$tmp/AUTOEXEC.BAT"
    put "$tmp/AUTOEXEC.BAT" AUTOEXEC.BAT

    # check: OCM-BIOS.DAT occupies the start of the data area (boot sector fields of the partition)
    bpb() { od -An -tu"$2" -j $(( part_lba * 512 + $1 )) -N "$2" "$img" | tr -d ' '; }
    data=$(( (part_lba + $(bpb 14 2) + $(bpb 16 1) * $(bpb 22 2)) * 512 + $(bpb 17 2) * 32 ))
    bios=$tmp/sd/sdbios/OCM-BIOS.DAT
    cmp -s -n "$(stat -c %s "$bios")" "$bios" <(tail -c +$(( data + 1 )) "$img") ||
        { echo "games.sh: OCM-BIOS.DAT is not at the start of the data area" >&2; exit 1; }
}

mapfile -t rom_files < <([ -n "$roms" ] && [ -d "$roms" ] && find "$roms" -maxdepth 1 -type f -iname '*.rom' | LC_ALL=C sort)
mkdir -p "$games"
make_vhd "$tmp/boot.vhd" "${rom_files[@]}"
mv "$tmp/boot.vhd" "$games/boot.vhd"
echo "games.sh: $games/boot.vhd (${size_mb} MiB, FAT16, OCM-BIOS.DAT at the first data cluster)"
# with several ROMs also one card per ROM that starts it, to choose in the OSD (Mount *.VHD)
if [ ${#rom_files[@]} -gt 1 ]; then
    for f in "${rom_files[@]}"; do
        v=$(basename "$f"); v=${v%.*}.vhd
        make_vhd "$tmp/$v" "$f" >/dev/null
        mv "$tmp/$v" "$games/$v"
        echo "games.sh: $games/$v (starts $(basename "$f"))"
    done
fi

# OSD settings of Main_MiSTer (cur_status, 16 bytes): Slot1 = MegaSCC+ 1MB for ROMLOAD
# (status bit 4), Reset after Mount (bit 14) so a card mounted in the OSD starts at once
config=$(dirname "$(dirname "$games")")/config
mkdir -p "$config"
if [ ! -e "$config/MSX.CFG" ]; then
    printf '\x10\x40\0\0\0\0\0\0\0\0\0\0\0\0\0\0' > "$config/MSX.CFG"
    echo "games.sh: $config/MSX.CFG (Slot1 MegaSCC+ 1MB, Reset after Mount)"
fi
