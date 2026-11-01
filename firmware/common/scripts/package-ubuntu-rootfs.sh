#!/bin/bash
# Package the Ubuntu 24.04 console rootfs
#
# Called by FLOW=rootfs make package in firmware/build/<platform>:
# writes ubuntu24.04-console-rootfs.tgz (e.g. for an NFS root or a hand-made card).

set -euo pipefail

targetdir=ubuntu24.04-console-rootfs

if [ ! -d "$targetdir" ]; then
    echo "ERROR: $PWD/$targetdir missing, run FLOW=rootfs make build first" >&2
    exit 1
fi

# left mounted by an interrupted build
for m in dev/pts proc sys; do
    if mountpoint -q "$targetdir/$m"; then
        sudo umount "$targetdir/$m"
    fi
done

cd "$targetdir"
sudo tar cfz ../ubuntu24.04-console-rootfs.tgz *
cd ..
echo "RootFS package $PWD/ubuntu24.04-console-rootfs.tgz"
