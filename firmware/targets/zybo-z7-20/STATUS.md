# Status Zybo Z7-20

Status per board stage (stage meanings: `doc/PORTING.md` §7). Evidence: HW, Timing, Sim, Script, FAIL, BLOCKED,
NOT RUN, open. `make test` checks the table, `make status` shows the overview. Commit `-` means the evidence predates
the public history of this repository.

| Stage | Evidence | Commit | Date | Measurement / Remark |
|---|---|---|---|---|
| boot | HW | - | 2026-10-30 | BOOT.bin `zybo-z7-20_msx_hdmi` (new framework) from the card, U-Boot "SD Boot" without intervention; after `systemctl reboot` reachable via SSH within 35 s, MSX-DOS prompt, then `make hwtest` menu/msx/snes PASS |
| linux | HW | - | 2026-10-29 | Linux 6.12 from the card (`/dev/mmcblk0p2`) and via NFS |
| main | HW | - | 2026-10-28 | Main_MiSTer with Zynq patches 0001–0004, OSD |
| video | HW | - | 2026-10-30 | HDMI 720p60 with audio (`hdmi_out`) and DVI (`rgb2dvi`) |
| audio | HW | - | 2026-10-30 | HDMI audio 48 kHz; SSM2603 headphones |
| input | HW | - | 2026-10-30 | USB keyboard on the OTG port (jumper JP2), uinput keyboard and gamepad; real gamepad over Bluetooth: see PSX input |
| sd | HW | - | 2026-10-29 | `/media/fat` on the card, VHD mount (MSX), ROM loading (SNES) |
| net | HW | - | 2026-10-28 | TFTP/NFS boot, SSH |
| switch | HW | - | 2026-10-30 | Core switching via `load_core`: 22/22, 3 rounds with the new framework, SNES ↔ MSX |
