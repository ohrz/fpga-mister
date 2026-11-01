#!/bin/bash
### Build the Ubuntu 24.04 (console) rootfs of a MiSTer board
#
# Runs inside the chroot, started by create-ubuntu-rootfs.sh (FLOW=rootfs make build).
# Expects in /: platform.sh (PLATFORM, ROOTFS_BOOT_DEV, ROOTFS_FALLBACK_DNS), hostname,
# debian/*.deb (the kernel of FLOW=kernel make build) and optional mister-rootfs.tgz
# (FLOW=mister make package: systemd units of Main_MiSTer and the board).  No questions;
# the passwords of root and fpga are set afterwards by create-ubuntu-rootfs.sh (chpasswd).
#
# Only what Main_MiSTer and a headless board need: systemd, SSH, DHCP (systemd-networkd),
# time sync, the libraries of Main_MiSTer, BlueZ for Bluetooth gamepads, i2c-tools for the
# audio codec setup, python3 for the test tools.  Locale C.UTF-8, time zone UTC.

set -euo pipefail

source /platform.sh
echo "Build the Ubuntu 24.04 console rootfs for $PLATFORM"

export LANG=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

#### APT

/debootstrap/debootstrap --second-stage

cat <<EOT > /etc/apt/sources.list
deb http://ports.ubuntu.com/ubuntu-ports noble main restricted universe
deb http://ports.ubuntu.com/ubuntu-ports noble-updates main restricted universe
deb http://ports.ubuntu.com/ubuntu-ports noble-security main restricted universe
EOT

cat <<EOT > /etc/apt/apt.conf.d/71-no-recommends
APT::Install-Recommends "0";
APT::Install-Suggests   "0";
EOT

apt-get update  -y
apt-get upgrade -y

#### Packages, in one go: systemd-resolved replaces /etc/resolv.conf, apt has no DNS afterwards
#   base:      systemd init, udev, kmod, SSH, sudo, networkd (part of systemd), resolved, timesyncd
#   MiSTer:    runtime libraries of Main_MiSTer, BlueZ (Bluetooth gamepads)
#   board:     i2c-tools (codec setup), dosfstools (fsck of /media/fat), python3 (tools/vkbd.py),
#              busybox-static (FLOW=rootfs make flash runs it from RAM while it rewrites the card)
#   console:   nano, less, iproute2, ping, tzdata, ca-certificates
apt-get install -y \
    adduser systemd-sysv udev kmod dbus openssh-server sudo systemd-resolved systemd-timesyncd \
    libimlib2t64 libfreetype6 libpng16-16t64 libbz2-1.0 zlib1g libbluetooth3 bluez \
    i2c-tools dosfstools python3 busybox-static \
    nano less iproute2 iputils-ping tzdata ca-certificates

#### Kernel modules (the same build as zImage on the FAT partition)
dpkg -i $(ls /debian/linux-image-*.deb | grep -v -- -dbg_)
rm -rf /debian

#### Locale and time zone
echo 'LANG=C.UTF-8' > /etc/default/locale
ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
echo 'Etc/UTC' > /etc/timezone

#### Host name
cp /hostname /etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\t\tlocalhost ip6-localhost ip6-loopback\n' "$(cat /hostname)" > /etc/hosts

#### User fpga (sudo); root and fpga get their password from create-ubuntu-rootfs.sh
adduser --disabled-password --gecos "" fpga
adduser fpga sudo

#### fstab: the FAT partition is /media/fat of MiSTer (games, saves, configs, cores);
#### flush: written at once, the board is usually switched off without shutdown
cat <<EOT > /etc/fstab
${ROOTFS_BOOT_DEV}  /media/fat  vfat  defaults,noatime,flush,utf8  0  2
EOT
mkdir -p /media/fat

#### Network: DHCP on eth0 (net.ifnames=0 in uEnv.txt).  Not with an NFS root: the kernel
#### configured the interface (ip=...), a DHCP lease with another address would cut the root
cat <<'EOT' > /etc/systemd/network/20-eth0.network
[Match]
Name=eth0
KernelCommandLine=!root=/dev/nfs

[Network]
DHCP=yes
EOT
if [ -n "${ROOTFS_FALLBACK_DNS:-}" ]; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nFallbackDNS=%s\n' "$ROOTFS_FALLBACK_DNS" > /etc/systemd/resolved.conf.d/10-fallback-dns.conf
fi
ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable systemd-networkd systemd-resolved systemd-timesyncd
# nothing waits for the network (no cable must not delay the boot)
systemctl disable systemd-networkd-wait-online.service || true
# no questions on the console at the first boot (empty machine-id = first boot)
systemctl mask systemd-firstboot.service

#### SSH: no host keys in the image (every card would share them), made at the first boot
#### (about 40 s on a Cortex-A9): only sshd waits for them, not the socket and with it not the boot
rm -f /etc/ssh/ssh_host_*
cat <<'EOT' > /etc/systemd/system/ssh-host-keys.service
[Unit]
Description=Generate the SSH host keys at the first boot
DefaultDependencies=no
After=local-fs.target
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=sysinit.target
EOT
systemctl enable ssh-host-keys.service

#### SSH keys from the FAT partition: /media/fat/linux/authorized_keys (written on any PC)
#### becomes /root/.ssh/authorized_keys at every boot, for key login without a console
cat <<'EOT' > /etc/systemd/system/ssh-authorized-keys.service
[Unit]
Description=SSH keys of root from /media/fat/linux/authorized_keys
RequiresMountsFor=/media/fat
ConditionPathExists=/media/fat/linux/authorized_keys
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'install -d -m 700 /root/.ssh && tr -d "\\r" < /media/fat/linux/authorized_keys > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'

[Install]
WantedBy=multi-user.target
EOT
systemctl enable ssh-authorized-keys.service

#### MiSTer: systemd units of Main_MiSTer and the board (mister.service is enabled by its link);
#### /media/fat itself is the FAT partition (FLOW=rootfs make image)
if [ -f /mister-rootfs.tgz ]; then
    tar -xzf /mister-rootfs.tgz --no-overwrite-dir -C /
    rm -f /mister-rootfs.tgz
fi

#### Clean up: no machine-id (made at the first boot), no apt lists
rm -f /hostname /platform.sh
apt-get clean
rm -rf /var/lib/apt/lists/*
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

##### Package list
dpkg -l > /dpkg-console-list.txt
