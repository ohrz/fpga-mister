#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# Title      : MiSTer NFS root of a board (NFS_ROOT_SETUP of FLOW=boot tftpboot)
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# File       : nfs-rootfs.sh
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-07
#-----------------------------------------------------------------------------
# Description:
#   setup-nfs copies a rootfs once to the NFS root of a board; this script,
#   run as root after every setup-nfs, makes the copy a MiSTer root that needs
#   nothing from the SD card (the card may hold another system's files):
#     - /media/fat is a directory of the NFS root: the fstab line that mounts
#       the FAT partition of the card there is removed
#     - the rootfs files and /media/fat of FLOW=mister make package (systemd
#       units; Main_MiSTer, MiSTer.ini, the cores).  The core folders (_*) are
#       the package's (old cores go); everything else of /media/fat stays
#       (games, saves, savestates); a file in config/ newer than the
#       package's (a setting Main_MiSTer saved) stays; games/ of the package
#       (start media such as games/MSX/boot.vhd) only where the NFS root and
#       --data have no file
#     - host name
#   Options:
#     --modules <kernel_out>  the modules of the kernel in <kernel_out>
#                             (linux-image .deb of FLOW=kernel make build,
#                             unpacked, depmod of the host on the tree): the
#                             ZCU106 boots its arm64 kernel with the armhf
#                             rootfs of the Zybo, the Zybo keeps its modules
#                             in step with the kernel it boots over TFTP
#     --disable <unit>        systemd unit not started (e.g. ssm2603.service of
#                             the Zybo on the ZCU106: its I2C bus 0 has other
#                             chips); may be given more than once
#     --data <dir>            user files for /media/fat (games, saves,
#                             savestates, config, linux/authorized_keys, e.g.
#                             a copy of the card), never over a file the NFS
#                             root has
#   Usage: nfs-rootfs.sh [options] <mister_stage> <hostname> <nfs_root>
#-----------------------------------------------------------------------------
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------

set -euo pipefail

usage="usage: $0 [--modules <kernel_out>] [--disable <unit>]... [--data <dir>] <mister_stage> <hostname> <nfs_root>"
kernel_out= data=
units=() args=()
while [ $# -gt 0 ]; do
    case $1 in
        --modules) kernel_out=${2:?$usage}; shift 2 ;;
        --disable) units+=("${2:?$usage}"); shift 2 ;;
        --data)    data=${2:?$usage}; shift 2 ;;
        -*)        echo "$usage" >&2; exit 2 ;;
        *)         args+=("$1"); shift ;;
    esac
done
[ ${#args[@]} -eq 3 ] || { echo "$usage" >&2; exit 2; }
stage=${args[0]} host=${args[1]} root=${args[2]}
[ "$(id -u)" = 0 ] || { echo "ERROR: $0 must run as root (sudo)" >&2; exit 1; }
[ -d "$root/etc" ] || { echo "ERROR: $root is no rootfs" >&2; exit 1; }
[ -x "$stage/media/fat/MiSTer" ] || { echo "ERROR: $stage/media/fat/MiSTer missing (FLOW=mister make build package)" >&2; exit 1; }
[ -z "$data" ] || [ -d "$data" ] || { echo "ERROR: $data is no directory" >&2; exit 1; }
echo "    NFS root $root: host name $host, /media/fat of $stage${kernel_out:+, modules of $kernel_out}${data:+, user files of $data}"

# kernel modules (/lib is a link to usr/lib in the Ubuntu rootfs)
if [ -n "$kernel_out" ]; then
    [ -f "$kernel_out/kernel.release" ] || { echo "ERROR: $kernel_out/kernel.release missing (FLOW=kernel make build)" >&2; exit 1; }
    rel=$(cat "$kernel_out/kernel.release")
    pkgs=("$kernel_out"/linux-image-"${rel}"_*.deb)
    pkg=${pkgs[0]}
    [ -f "$pkg" ] || { echo "ERROR: no linux-image-${rel}_*.deb in $kernel_out" >&2; exit 1; }
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    dpkg-deb -x "$pkg" "$tmp"
    mods=$(find "$tmp" -maxdepth 3 -type d -path "*/lib/modules/$rel" | head -1)
    [ -n "$mods" ] || { echo "ERROR: no lib/modules/$rel in $pkg" >&2; exit 1; }
    rm -rf "$root/usr/lib/modules/$rel"
    cp -a "$mods" "$root/usr/lib/modules/"
    depmod -b "$root" "$rel"
    echo "    modules $rel"
fi

# host name, units not started
echo "$host" > "$root/etc/hostname"
sed -i '/^127\.0\.1\.1/d' "$root/etc/hosts"
echo "127.0.1.1	$host" >> "$root/etc/hosts"
for u in ${units[@]+"${units[@]}"}; do
    rm -f "$root/etc/systemd/system/"*.wants/"$u"
done

# /media/fat from the NFS root, not from the card (FLOW=rootfs writes the line for the card image)
if [ -f "$root/etc/fstab" ]; then
    awk '$2 != "/media/fat"' "$root/etc/fstab" > "$root/etc/fstab.new"
    cat "$root/etc/fstab.new" > "$root/etc/fstab"
    rm -f "$root/etc/fstab.new"
fi

# rootfs files of the package (mister.service, tmpfs for the bitstreams), then
# /media/fat: the package's files, its core folders with --delete (cores of an older package
# go); config/ of the package (e.g. MSX.CFG of games.sh) only over an older file, so what
# Main_MiSTer saved on the board stays
rsync -a --chown=root:root "$stage/etc/" "$root/etc/"
mkdir -p "$root/media/fat"
rsync -a --chown=root:root --exclude=/config/ --exclude=/games/ "$stage/media/fat/" "$root/media/fat/"
for d in "$stage"/media/fat/_*/; do
    if [ -d "$d" ]; then
        rsync -a --chown=root:root --delete "$d" "$root/media/fat/$(basename "$d")/"
    fi
done
if [ -d "$stage/media/fat/config" ]; then
    rsync -a --chown=root:root --update "$stage/media/fat/config/" "$root/media/fat/config/"
fi
# user files: only what the NFS root does not have yet; before games/ of the package, whose
# start media (games/MSX/boot.vhd of games.sh: the system without ROMs) only fill gaps and
# never replace a card with the user's ROMs
[ -z "$data" ] || rsync -a --chown=root:root --ignore-existing "$data/" "$root/media/fat/"
if [ -d "$stage/media/fat/games" ]; then
    rsync -a --chown=root:root --ignore-existing "$stage/media/fat/games/" "$root/media/fat/games/"
fi
echo "    NFS root ready"
