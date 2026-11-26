# Zybo Z7-20 — the first board of the port

Digilent Zybo Z7-20:

- XC7Z020-1 (`xc7z020clg400-1`), 1 GB DDR3, armhf Linux
- console on UART1
- HDMI TX/RX through SelectIO TMDS (no HDMI chips)
- SSM2603 audio codec
- USB host (PS USB0), SD card on PS SD0

The board files and the master XDC come from Digilent (MIT license, see `LICENSES/README.md`).

| Path | Content |
|---|---|
| `platform.mk` | board profile: flows `vivado kernel uboot boot rootfs mister`, setup checkouts, `VIDEO_TX` (dvi/hdmi), boot design `zybo-z7-20_msx[_hdmi]`, `MISTER_CORES` |
| `board_files/`, `constraints/` | Digilent board files (1.1), master XDC (pin reference), `zybo-z7-20_mister.xdc` (pins and clock groups of every MiSTer design) |
| `scripts/2025.2/` | `zybo-z7-20_mister.tcl`: block design and generator of every MiSTer design (`CORE=<core>`, `VIDEO=dvi|hdmi`) |
| `files/mister-rootfs/` | `ssm2603-init.sh` + `ssm2603.service` (codec setup over I2C0 at boot) |
| `dts/zynq-zybo-z7.dts` | kernel/U-Boot DTS; reserves 0x1FF0_0000-0x3FFF_FFFF for the PL and Main_MiSTer |
| `files/` | `uEnv.txt` (boot menu SD, TFTP/NFS), `uboot.config` (the kernel options of MiSTer are in `firmware/common/linux/kernel.config`) |

Each core profile (menu, msx, snes, psx, n64) has two designs:

- `zybo-z7-20_<core>`: DVI through `rgb2dvi`
- `zybo-z7-20_<core>_hdmi`: HDMI with sound through `hdmi_out` of `firmware/common/ip/hdmi-tx`

`zybo-z7-20_mister.tcl` makes all of them (`PLATFORM=zybo-z7-20 FLOW=vivado CORE=snes VIDEO=hdmi make create build`).
The XC7Z020 is too small for the full SNES, PSX and N64 cores. Their profiles leave out options (core `README.md`
files). N64 runs at its original clocks outside its timing constraints. `MISTER_CORES` packages all of them: menu,
MSX (`_Computer`), SNES, PSX and N64 (`_Console`).

Hardware setup:

1. Set jumper JP5 to SD (start from the SD card).
2. Set jumper JP2 (HOST) for USB host mode. If JP2 is not set, the OTG connector gets no VBUS. Then no USB device
   (keyboard, Bluetooth adapter) enumerates.

A keyboard through an OTG adapter on the USB port works. The board has one USB port. Thus a keyboard and a
Bluetooth adapter at the same time need a USB hub.

Bluetooth (DualSense/DualShock 4): the Ubuntu RootFS uses the system `bluetoothd` (bluez 5.72, `bluetooth.service`)
and the kernel HIDP path with `hid-playstation`. The Bluetooth helpers of Main_MiSTer (`/bin/bluetoothd`, MiSTer
image convention) do not exist here (journal: `/bin/bluetoothd: not found`). To pair a controller, do these
steps:

1. Copy `firmware/common/mister/tools/pair-ds5.sh` to the board.
2. Put the controller in pairing mode with Create + PS.
3. Run the script in a shell on the board. The script trusts, pairs and connects the controller.

Main_MiSTer takes the new `/dev/input/event*` without a restart. After that, the controller connects again with the
PS button. The Bluetooth modules (`bluetooth`, `btusb`, `hidp`) come with the kernel package of the build that
enabled them (`firmware/common/linux/kernel.config`). We checked this on 2026-10-31 with a CSR 0a12:0001 adapter and
a DualSense:

- Adapter: BT 2.1, no firmware file. One `hardware error 0x37` occurred at setup.
- The controller paired and connected, and Main opened the gamepad.
- A PSX game is playable.

Network boot without MiSTer files on the card: `PLATFORM=zybo-z7-20 VIDEO_TX=hdmi FLOW=boot make tftpboot` serves
the kernel over TFTP. It also exports a copy of the RootFS over NFS. In this copy, `/media/fat` is a directory, not
the FAT partition of the card. `firmware/common/mister/scripts/nfs-rootfs.sh` makes this copy:

- It adds the package of `FLOW=mister`.
- It adds the kernel modules.
- It writes no fstab line for `/media/fat`.

`NFS_ROOT_DATA=<dir>` adds user files (games, saves, config, for example a copy of the old card). It does not
overwrite a file. The board uses only `BOOT.bin` (FSBL, U-Boot) and the boot menu from the card. The MiSTer designs
need these settings from the FSBL:

- FCLK0 at 100 MHz.
- HP0-HP3 at 64 bit (the reset width).
- I2C0 on EMIO for the codec.

The Bluetooth pairings are in `/var/lib/bluetooth` of the root. Thus a new NFS root needs a new pairing.

Pitfalls:

- 1080p runs the SelectIO TMDS beyond the XC7Z020-1 datasheet. 720p is within the datasheet.
- The flows build the FSBL on demand from the XSA of the boot design (`files/fsbl/` is not tracked here).
- U-Boot sets no board MAC address. Each Zybo with this image uses the Xilinx default `00:0a:35:00:00:00` and gets
  the same DHCP lease. Thus only one such board at a time works in a network. Open item: the unique MAC in the OTP
  area of the QSPI flash.
