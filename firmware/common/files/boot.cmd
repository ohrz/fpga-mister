# boot.scr of fpga-mister (FLOW=boot make copy: @BOOTCMD@ bootz|booti, @KERNEL@ zImage|Image)
# Generate by hand: mkimage -c none -A arm -T script -d boot.cmd boot.scr
#
# From the first FAT partition of the SD card (or a USB stick): uEnv.txt sets the kernel
# arguments and runs its boot menu (uenvcmd); without uEnv.txt the kernel and system.dtb of
# the partition are booted with the bootargs U-Boot already has.

for boot_target in ${boot_targets};
do
	echo "Trying to load boot images from ${boot_target}"
	if test "${boot_target}" = "mmc0" || test "${boot_target}" = "mmc1" || test "${boot_target}" = "usb0" || test "${boot_target}" = "usb1"; then
		if test -e ${devtype} ${devnum}:${distro_bootpart} /uEnv.txt; then
			fatload ${devtype} ${devnum}:${distro_bootpart} 0x00200000 uEnv.txt;
			echo "Importing environment(uEnv.txt) from ${boot_target}..."
			env import -t 0x00200000 $filesize
			if test -n $uenvcmd; then
				echo "Running uenvcmd ...";
				run uenvcmd;
			fi
		fi
		if test -e ${devtype} ${devnum}:${distro_bootpart} /@KERNEL@; then
			fatload ${devtype} ${devnum}:${distro_bootpart} 0x00200000 @KERNEL@;
		fi
		if test -e ${devtype} ${devnum}:${distro_bootpart} /system.dtb; then
			fatload ${devtype} ${devnum}:${distro_bootpart} 0x00100000 system.dtb;
		fi
		@BOOTCMD@ 0x00200000 - 0x00100000
	fi
done
