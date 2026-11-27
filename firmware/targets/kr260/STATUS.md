# Status KR260

Status per board stage (stage meanings: `doc/PORTING.md` §7). Evidence: HW, Timing, Sim, Script, FAIL, BLOCKED,
NOT RUN, open. `make test` checks the table, `make status` shows the overview.

| Stage | Evidence | Commit | Date | Measurement / Remark |
|---|---|---|---|---|
| boot | HW | - | 2026-11-26 | U-Boot of the QSPI flash (never write it, no `saveenv`). Entry 1 of the boot menu in `uEnv.txt` of the SD card: menu core (`fpga load`), kernel and DTB through TFTP. Entry 0 (default) boots the RootFS of the SD card |
| linux | HW | - | 2026-11-26 | NFS root: armhf RootFS of the Zybo with the arm64 kernel. `/proc/iomem`: `1ff00000-3fffffff : reserved` |
| main | HW | - | 2026-11-26 | Main identifies the core `MENU` and runs (STATUS 0 after 2.5 min, one run). |
| video | HW | - | 2026-11-27 | DisplayPort of the PS with an active DP to HDMI adapter, live input from `kr260_dp_live` at 1280x720@59.99. `kr260-dp-live.service` switches to it after the start of Main, also after a restart. The picture stays after a core change. A passive adapter does not work (the DP of the ZynqMP has no dual mode) |
| audio | HW | - | 2026-11-27 | `kr260_dp_audio` into the live audio input of the DisplayPort, 48000 frames/s. 1 kHz test tone and MSX sound checked |
| input | HW | - | 2026-11-27 | USB keyboard through Main: `ver` and `dir` in MSX-DOS. A virtual keyboard (uinput, over SSH) started a game |
| sd | open | - | 2026-11-26 | The SD card of the carrier is a USB device (`/dev/sda`) |
| net | HW | - | 2026-11-26 | GEM1 (`ff0c0000`, Linux `eth0`) 1 Gbit/s, TFTP 14.9 MiB/s, NFS root |
| switch | HW | - | 2026-11-26 | Core change menu to MSX through `load_core` in `/dev/MiSTer_cmd` |
