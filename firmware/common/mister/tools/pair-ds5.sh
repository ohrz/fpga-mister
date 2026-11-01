#!/bin/bash
# ----------------------------------------------------------------------------------
#  Title      : Pair a PS5/PS4 controller over Bluetooth
#  Project    : fpga-mister
#  File       : pair-ds5.sh
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-31
# ----------------------------------------------------------------------------------
#  Description: Runs on the board (root), with bluez (bluetoothd, bluetoothctl) and a
#               USB Bluetooth adapter: pair-ds5.sh [scan_seconds] (default 120).
#               Put the controller into pairing mode first (hold Create + PS for ~3 s
#               until the light bar double-blinks). Scans for "DualSense Wireless
#               Controller" / "Wireless Controller", trusts the device (before
#               pairing: the controller opens its HID channels right after pairing and
#               bluetoothd rejects an untrusted device without agent), pairs, connects
#               and lists its /dev/input/event* devices. Main_MiSTer watches
#               /dev/input with inotify and takes the gamepad without restart. Later the
#               bonded controller reconnects with the PS button.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
set -u

SCAN_SECONDS=${1:-120}
NAME_RE='Wireless Controller|DualSense'

die() { echo "ERROR: $*" >&2; exit 1; }

# Adapter and daemon
[ -d /sys/class/bluetooth/hci0 ] || modprobe btusb 2>/dev/null
sleep 1
[ -d /sys/class/bluetooth/hci0 ] || die "no Bluetooth adapter (hci0); is the USB dongle plugged in and btusb loaded?"
systemctl is-active --quiet bluetooth || systemctl start bluetooth || die "bluetooth.service does not start"
sleep 1
bluetoothctl power on    >/dev/null || die "cannot power on the adapter"
bluetoothctl pairable on >/dev/null

# Remove stale entries of earlier pairings (the controller forgets the host
# when it is paired elsewhere; a stale link key makes the new pairing fail)
for mac in $(bluetoothctl devices | awk '{print $2}'); do
	if bluetoothctl info "$mac" | grep -Eq "Name: .*($NAME_RE)"; then
		if ! bluetoothctl info "$mac" | grep -q "Connected: yes"; then
			echo "removing old entry $mac"
			bluetoothctl remove "$mac" >/dev/null
		fi
	fi
done

echo "Scanning up to ${SCAN_SECONDS} s for the controller"
echo "(controller: hold Create + PS for ~3 s until the light bar double-blinks)"
bluetoothctl --timeout "$SCAN_SECONDS" scan on >/dev/null 2>&1 &
SCAN_PID=$!
trap 'kill $SCAN_PID 2>/dev/null' EXIT

MAC=""
end=$((SECONDS + SCAN_SECONDS))
while [ $SECONDS -lt $end ] && kill -0 $SCAN_PID 2>/dev/null; do
	for mac in $(bluetoothctl devices | awk '{print $2}'); do
		info=$(bluetoothctl info "$mac")
		if echo "$info" | grep -Eq "Name: .*($NAME_RE)|Icon: input-gaming"; then
			MAC=$mac
			break 2
		fi
	done
	printf '.'
	sleep 2
done
echo
kill $SCAN_PID 2>/dev/null
wait $SCAN_PID 2>/dev/null
trap - EXIT
bluetoothctl scan off >/dev/null 2>&1

[ -n "$MAC" ] || die "no controller found within ${SCAN_SECONDS} s (pairing mode active? light bar must double-blink)"
echo "Found: $MAC $(bluetoothctl info "$MAC" | sed -n 's/^\s*Name: //p')"

# Trust first (the controller opens its HID channels right after pairing, an
# untrusted device is rejected: "Authentication attempt without agent"), then
# pair (Just Works, no PIN) and connect
bluetoothctl trust "$MAC" >/dev/null || die "trust failed"
bluetoothctl --agent NoInputNoOutput --timeout 30 pair "$MAC" || die "pairing failed (retry: pairing mode again, then rerun)"
for i in 1 2 3 4 5; do
	bluetoothctl info "$MAC" | grep -q "Connected: yes" && break
	bluetoothctl --timeout 15 connect "$MAC" >/dev/null 2>&1
	sleep 2
done
bluetoothctl info "$MAC" | grep -E "Name|Paired|Bonded|Trusted|Connected"

# Input devices of the controller (hid-playstation: gamepad, motion sensors,
# touchpad)
sleep 2
mac_lc=$(echo "$MAC" | tr 'A-F' 'a-f')
found=0
for ev in /sys/class/input/event*; do
	uniq=$(cat "$ev/device/uniq" 2>/dev/null)
	if [ "$uniq" = "$mac_lc" ]; then
		echo "/dev/input/$(basename "$ev"): $(cat "$ev/device/name")"
		found=1
	fi
done
[ $found = 1 ] || die "controller paired but no input device yet; press PS once and check: ls /dev/input"
echo "OK: controller is ready; MiSTer picks it up without restart"
