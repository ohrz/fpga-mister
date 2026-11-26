# Status KR260

Status per board stage (stage meanings: `doc/PORTING.md` §7). Evidence: HW, Timing, Sim, Script, FAIL, BLOCKED,
NOT RUN, open. `make test` checks the table, `make status` shows the overview.

| Stage | Evidence | Commit | Date | Measurement / Remark |
|---|---|---|---|---|
| boot | open | - | 2026-11-26 | U-Boot of the QSPI flash (never write it), kernel and DTB through TFTP (proposal) |
| linux | open | - | 2026-11-26 | NFS root: armhf RootFS of the Zybo with the arm64 kernel (proposal, as ZCU106) |
| main | open | - | 2026-11-26 | Main_MiSTer with the Zynq patches, register base 0xA000_0000 |
| video | open | - | 2026-11-26 | DisplayPort of the PS, live input from `kr260_dp_live` (Sim PASS), 720p60 |
| audio | open | - | 2026-11-26 | No codec, the driver ignores the DP live audio: PMOD I2S DAC or DP live audio |
| input | open | - | 2026-11-26 | USB keyboard and gamepad through the USB hub of the carrier |
| sd | open | - | 2026-11-26 | The SD card of the carrier is a USB device (`/dev/sda`) |
| net | open | - | 2026-11-26 | TFTP/NFS boot, SSH |
| switch | open | - | 2026-11-26 | Core change through `load_core` |
