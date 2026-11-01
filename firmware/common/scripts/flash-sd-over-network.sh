#!/bin/bash
# Write the SD card image to the card in a running board, over the network
#
#   flash-sd-over-network.sh <board> <image .img or .img.xz> <busybox> [<authorized_keys>]
#
# Called by FLOW=rootfs make flash.  The card stays in the board:
#   1. host: the image in a temporary copy; with <authorized_keys> the keys go to
#      /linux/authorized_keys of its FAT partition (root key login after the flash,
#      ssh-authorized-keys.service); SHA-256 of the copy
#   2. board (ssh root@<board>): checks the card size, stops Main_MiSTer, unmounts the FAT
#      partition, copies the static <busybox> (armhf, from the rootfs build) to /dev/shm and
#      starts a script from there that needs nothing of the card any more:
#      remount / read-only (or freeze it), receive the image on TCP port 5555 (busybox nc) and
#      write it to /dev/mmcblk0, drop the page cache, read the card back and hand the
#      SHA-256 out on port 5556, then reboot -f on "reboot" at port 5557
#   3. host: sends the image, compares the checksums, sends "reboot" (only when they match)
# A failed or interrupted transfer leaves a card that does not boot: then the card has to be
# written on a PC.  The board gets new SSH host keys (first boot of the image), the old
# entry of <board> in ~/.ssh/known_hosts is removed.

set -euo pipefail
export PATH=$PATH:/usr/sbin:/sbin

usage="usage: flash-sd-over-network.sh <board> <image .img|.img.xz> <busybox> [<authorized_keys>]"
board=${1:?$usage}
image=${2:?$usage}
busybox=${3:?$usage}
keys=${4:-}
dev=/dev/mmcblk0
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

[ -f "$image" ] || { echo "ERROR: $image missing (FLOW=rootfs make image)" >&2; exit 1; }
[ -f "$busybox" ] || { echo "ERROR: $busybox missing (FLOW=rootfs make build installs busybox-static)" >&2; exit 1; }
file -L "$busybox" | grep -q 'ARM.*statically linked' || { echo "ERROR: $busybox is no static ARM binary" >&2; exit 1; }
[ -z "$keys" ] || [ -f "$keys" ] || { echo "ERROR: $keys missing" >&2; exit 1; }
ssh "${ssh_opts[@]}" root@"$board" true ||
    { echo "ERROR: no key login as root@$board (ssh-copy-id, or /media/fat/linux/authorized_keys)" >&2; exit 1; }

tmp=$(mktemp -d "$(dirname "$image")/flash.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
img=$tmp/card.img

# 1. the image, the SSH keys in its FAT partition, the checksum
echo "== image $image"
case "$image" in
    *.xz) xz -dc -T0 "$image" > "$img" ;;
    *)    cp --sparse=always "$image" "$img" ;;
esac
if [ -n "$keys" ]; then
    fat_lba=$(sfdisk -d "$img" | sed -n 's/^[^ ]*1 : start= *\([0-9]*\),.*/\1/p')
    [ -n "$fat_lba" ] || { echo "ERROR: no partition 1 in $image" >&2; exit 1; }
    export MTOOLS_SKIP_CHECK=1
    mmd -i "$img@@$(( fat_lba * 512 ))" ::/linux 2>/dev/null || true
    mcopy -o -i "$img@@$(( fat_lba * 512 ))" "$keys" ::/linux/authorized_keys
    echo "   $keys -> /linux/authorized_keys of the FAT partition"
fi
size=$(stat -c %s "$img")
[ $((size % 512)) = 0 ] || { echo "ERROR: $image is not a multiple of 512 bytes" >&2; exit 1; }
sum=$(sha256sum "$img" | cut -d' ' -f1)
echo "   $size bytes, sha256 $sum"

# 2. the board: card size, Main_MiSTer stopped, FAT partition unmounted, busybox in RAM
echo "== board $board"
card=$(ssh "${ssh_opts[@]}" root@"$board" "blockdev --getsize64 $dev")
[ "$card" -ge "$size" ] || { echo "ERROR: the card ($card bytes) is smaller than the image ($size bytes)" >&2; exit 1; }
echo "   card $dev: $card bytes"
scp -q "${ssh_opts[@]}" "$busybox" root@"$board":/dev/shm/busybox
ssh "${ssh_opts[@]}" root@"$board" sh -s "$dev" "$size" <<'EOT'
set -e
dev=$1; size=$2
# read back with dd and a block count: busybox head -c takes no count above 2^31 on 32-bit
if [ $((size % 1048576)) = 0 ]; then bs=1M; count=$((size / 1048576)); else bs=512; count=$((size / 512)); fi
/dev/shm/busybox chmod 755 /dev/shm/busybox
/dev/shm/busybox nc 2>&1 | /dev/shm/busybox grep -q -- '-l' || { echo "ERROR: busybox nc without -l" >&2; exit 1; }
systemctl stop mister.service 2>/dev/null || true
sync
for m in $(awk -v d="$dev" 'index($1, d) == 1 && $2 != "/" { print $2 }' /proc/mounts); do umount "$m"; done
cat > /dev/shm/flash.sh <<EOS
#!/dev/shm/busybox sh
# runs only from RAM (busybox in /dev/shm); the kernel needs no SysRq
bb=/dev/shm/busybox
\$bb sleep 5
\$bb sync
# the root file system of the card must not be written any more: read-only, else frozen;
# neither works: no write (the host finds no listener on port 5555, the card stays as it is).
# A tmpfs on /var/log takes the wtmp record of busybox reboot, which would wait for ever on
# the frozen file system
\$bb mount -t tmpfs tmpfs /var/log
if \$bb mount -o remount,ro / 2>/dev/null; then ro=remount
elif \$bb fsfreeze --freeze / 2>/dev/null; then ro=freeze
else exit 1; fi
# no global sync from here on (it would wait for the frozen file system): fsync of the card only
\$bb nc -l -p 5555 | \$bb dd of=$dev bs=1M conv=fsync 2> /dev/shm/dd.log
echo 3 > /proc/sys/vm/drop_caches
echo "\$(\$bb dd if=$dev bs=$bs count=$count 2>/dev/null | \$bb sha256sum | \$bb cut -d' ' -f1) \$ro" > /dev/shm/sum
# every connection gets the checksum; only "reboot" or "abort" on port 5557 ends the script
# (a port scan or an empty connection does not)
( while :; do \$bb nc -l -p 5556 < /dev/shm/sum; done ) &
while :; do
    \$bb nc -l -p 5557 > /dev/shm/cmd
    case "\$(\$bb cat /dev/shm/cmd)" in
        reboot) \$bb reboot -f -n ;;
        abort)  kill \$! ; break ;;
    esac
done
EOS
/dev/shm/busybox chmod 755 /dev/shm/flash.sh
/dev/shm/busybox setsid /dev/shm/flash.sh < /dev/null > /dev/null 2>&1 &
echo "   flash.sh runs from /dev/shm: root file system read-only or frozen in 5 s, then port 5555"
EOT

# 3. send, compare, reboot
sleep 7
echo "== write $size bytes to $board:$dev (port 5555)"
t=$(date +%s)
sent=0
for i in $(seq 1 10); do
    if { exec 3> /dev/tcp/"$board"/5555; } 2>/dev/null; then sent=1; break; fi
    sleep 2
done
[ $sent = 1 ] || { echo "ERROR: $board does not listen on port 5555 (root file system neither read-only nor frozen?), the card is unchanged; reboot the board" >&2; exit 1; }
cat "$img" >&3
exec 3>&-
echo "   sent in $(( $(date +%s) - t )) s, waiting for the read-back checksum"
board_sum=""
for i in $(seq 1 600); do
    if board_sum=$( { cat < /dev/tcp/"$board"/5556; } 2>/dev/null ) && [ -n "$board_sum" ]; then break; fi
    sleep 2
done
echo "   card sha256 ${board_sum% *} (root file system: ${board_sum#* })"
if [ "${board_sum% *}" != "$sum" ]; then
    echo "ERROR: checksum differs, the card is not rebooted. Write it again (the board waits:" >&2
    echo "       echo abort > /dev/tcp/$board/5557, then reboot it), or boot it anyway:" >&2
    echo "       echo reboot > /dev/tcp/$board/5557" >&2
    exit 1
fi
# port 5557 listens only after port 5556 has been served
for i in $(seq 1 10); do
    if { echo reboot > /dev/tcp/"$board"/5557; } 2>/dev/null; then break; fi
    sleep 1
done
ssh-keygen -R "$board" >/dev/null 2>&1 || true
echo "== $board reboots from the new card ($(( $(date +%s) - t )) s)"
