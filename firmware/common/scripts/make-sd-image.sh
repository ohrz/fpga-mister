#!/bin/bash
# Make the SD card image of a MiSTer board
#
#   make-sd-image.sh <image> <fat dir> <rootfs dir> <FAT MiB> <boot file>...
#
# Called by FLOW=rootfs make image.  The card:
#   partition 1  FAT32 "MISTER", <FAT MiB>, bootable: the boot files of FLOW=boot
#                make copy (BOOT.bin, boot.scr, uEnv.txt, kernel, DTB) and the
#                MiSTer files of FLOW=mister make package (MiSTer, MiSTer.ini, menu.rbf,
#                _Computer/, _Console/, games/, config/); /media/fat on the board
#   partition 2  ext4 "rootfs": <rootfs dir>, the size of its contents + 25 % + 512 MiB
# The FAT image is made with mkfs.vfat + mcopy (no root); the ext4 image with
# mke2fs -d under sudo (the rootfs is owned by root).  Writing the image: dd or any
# SD card writer (balenaEtcher, Raspberry Pi Imager, ...).

set -euo pipefail
export PATH=$PATH:/usr/sbin:/sbin

usage="usage: make-sd-image.sh <image> <fat dir> <rootfs dir> <FAT MiB> <boot file>..."
img=${1:?$usage}
fat=${2:?$usage}
rootfs=${3:?$usage}
fat_mb=${4:?$usage}
shift 4
boot_files=("$@")

for t in mkfs.vfat mcopy sfdisk mke2fs; do
    command -v $t >/dev/null || { echo "ERROR: $t missing (sudo apt install dosfstools mtools fdisk e2fsprogs)" >&2; exit 1; }
done
[ ${#boot_files[@]} -gt 0 ] || { echo "$usage" >&2; exit 1; }
for f in "${boot_files[@]}"; do
    [ -f "$f" ] || { echo "ERROR: $f missing (FLOW=boot make copy)" >&2; exit 1; }
done
[ -f "$fat/MiSTer" ] || { echo "ERROR: $fat/MiSTer missing (FLOW=mister make package)" >&2; exit 1; }
[ -d "$rootfs/etc" ] || { echo "ERROR: $rootfs is no rootfs (FLOW=rootfs make build)" >&2; exit 1; }
if findmnt -rno TARGET | grep -q "^$(realpath "$rootfs")/"; then
    echo "ERROR: something is mounted below $rootfs" >&2; exit 1
fi

tmp=$(mktemp -d "$(dirname "$img")/sd-image.XXXXXX")
trap 'sudo rm -rf "$tmp"' EXIT

# partition 1: FAT32 with the boot files and /media/fat
echo "FAT32 ${fat_mb} MiB: ${boot_files[*]##*/} + $fat"
truncate -s "${fat_mb}M" "$tmp/fat.img"
mkfs.vfat -F 32 -n MISTER "$tmp/fat.img" >/dev/null
export MTOOLS_SKIP_CHECK=1
mcopy -i "$tmp/fat.img" -p -m "${boot_files[@]}" ::
mcopy -i "$tmp/fat.img" -s -p -m "$fat"/* ::
mdir -i "$tmp/fat.img" -/ :: | tail -n 3

# partition 2: ext4 with the rootfs (4 KiB blocks, the size rounded to MiB)
used_mb=$(sudo du -sm --apparent-size "$rootfs" | cut -f1)
root_mb=$(( used_mb * 5 / 4 + 512 ))
echo "ext4 ${root_mb} MiB: $rootfs (${used_mb} MiB used)"
truncate -s "${root_mb}M" "$tmp/root.img"
sudo mke2fs -q -t ext4 -L rootfs -b 4096 -d "$rootfs" "$tmp/root.img"
sudo chown "$(id -u):$(id -g)" "$tmp/root.img"

# card: MBR, partition 1 at 1 MiB (FAT32 LBA, bootable), partition 2 right after it
start1=2048
start2=$(( start1 + fat_mb * 2048 ))
total_mb=$(( 1 + fat_mb + root_mb ))
rm -f "$img"
truncate -s "${total_mb}M" "$img"
sfdisk -q "$img" <<EOT
label: dos
start=${start1}, size=$(( fat_mb * 2048 )), type=c, bootable
start=${start2}, size=$(( root_mb * 2048 )), type=83
EOT
dd if="$tmp/fat.img"  of="$img" bs=1M seek=1 conv=notrunc,sparse status=none
dd if="$tmp/root.img" of="$img" bs=1M seek=$(( 1 + fat_mb )) conv=notrunc,sparse status=none
sfdisk -l "$img" | tail -n 3
echo "SD card image $img ($total_mb MiB, needs a card of at least that size)"
