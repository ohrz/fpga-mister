#!/bin/bash
# Create the Ubuntu 24.04 console rootfs
#
# Called by FLOW=rootfs make build in firmware/build/<platform>, which provides
# platform.sh (PLATFORM, ROOTFS_ARCH, ...), hostname, build-ubuntu24.04-console-rootfs.sh,
# debian/ (kernel packages) and optional mister-rootfs.tgz (FLOW=mister make package).
#   1. debootstrap --variant=minbase (first stage)
#   2. build-ubuntu24.04-console-rootfs.sh in the chroot (no questions)
#   3. passwords of root and fpga: ROOTFS_PASSWORD (FLOW=rootfs default: mister)
# proc, dev/pts (and sys, mounted by the debootstrap second stage) are unmounted on every exit.
#
# Requirements (the chroot runs the target binaries through binfmt_misc + qemu-user)
# $ sudo apt install debootstrap qemu-user-binfmt binfmt-support

set -euo pipefail

source ./platform.sh

targetdir=ubuntu24.04-console-rootfs
distro=noble

# architecture from the board profile (ROOTFS_ARCH in platform.sh, written by FLOW=rootfs)
arch=${ROOTFS_ARCH:?ROOTFS_ARCH missing in platform.sh (FLOW=rootfs make build writes it)}
case "$arch" in
    arm64)  qemu=qemu-aarch64-static; binfmt=qemu-aarch64 ;;
    armhf)  qemu=qemu-arm-static;     binfmt=qemu-arm ;;
    *)  echo "ERROR: unknown ROOTFS_ARCH '$arch' (arm64 or armhf)" >&2; exit 1 ;;
esac
echo "$PLATFORM ($arch) .............. detected"

if [ -e "$targetdir" ]; then
    echo "ERROR: $PWD/$targetdir exists, remove it first: PLATFORM=$PLATFORM FLOW=rootfs make clean" >&2
    exit 1
fi
[ -e /proc/sys/fs/binfmt_misc/$binfmt ] ||
    { echo "ERROR: no binfmt_misc entry $binfmt (sudo apt install qemu-user-binfmt binfmt-support)" >&2; exit 1; }

[ -n "${ROOTFS_PASSWORD:-}" ] || { echo "ERROR: ROOTFS_PASSWORD is empty" >&2; exit 1; }

cleanup() {
    for m in dev/pts proc sys; do
        if mountpoint -q "$targetdir/$m"; then
            sudo umount "$targetdir/$m"
        fi
    done
}
trap cleanup EXIT

# first stage
mkdir "$targetdir"
sudo debootstrap --arch=$arch --variant=minbase --foreign $distro "$targetdir"
# qemu in the chroot only for a binfmt entry without the F flag (qemu-user-binfmt has it)
if ! grep -q '^flags:.*F' /proc/sys/fs/binfmt_misc/$binfmt && [ -x /usr/bin/$qemu ]; then
    sudo cp /usr/bin/$qemu "$targetdir/usr/bin"
fi
sudo cp /etc/resolv.conf "$targetdir/etc"

# host name, settings, build script, kernel packages, MiSTer files
sudo mv hostname platform.sh build-ubuntu24.04-console-rootfs.sh debian "$targetdir"/
if [ -f mister-rootfs.tgz ]; then sudo cp mister-rootfs.tgz "$targetdir"/; fi

sudo mount -t proc proc "$targetdir/proc"
sudo mount --bind /dev/pts "$targetdir/dev/pts"

# second stage, packages, users (runs in the chroot, no questions); stdin is no terminal, so
# apt/dpkg never touch the terminal (a process outside the foreground group would stop there)
sudo chroot "$targetdir" /bin/bash /build-ubuntu24.04-console-rootfs.sh < /dev/null

# passwords (not stored in any file)
printf 'root:%s\nfpga:%s\n' "$ROOTFS_PASSWORD" "$ROOTFS_PASSWORD" | sudo chroot "$targetdir" chpasswd

# build helpers out of the rootfs
sudo rm -f "$targetdir/usr/bin/qemu-arm-static" "$targetdir/usr/bin/qemu-aarch64-static" \
           "$targetdir/build-ubuntu24.04-console-rootfs.sh"
if [ -f "$targetdir/dpkg-console-list.txt" ]; then
    sudo mv "$targetdir/dpkg-console-list.txt" ubuntu24.04-console-dpkg-list.txt
fi

echo "RootFS $PWD/$targetdir done, next: FLOW=rootfs make image (SD card) or package (tgz)"
