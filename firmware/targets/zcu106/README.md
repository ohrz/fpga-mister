# ZCU106 — Zynq UltraScale+ board

AMD/Xilinx ZCU106:

- XCZU7EV-2 (`xczu7ev-ffvc1156-2-e`), 4 GB PS DDR4, arm64 Linux.
- Console on PS UART0 (`ttyPS0`).
- HDMI TX through GTH transceivers (quad 223) with the TI DP159 retimer and a Si5324 clock.

The board files (2.6) and the pin data come from AMD (UG1244 XDC). The board DTS comes from linux-xlnx, the boot
firmware from soc-prebuilt-firmware.

| Path | Content |
|---|---|
| `platform.mk` | board profile: flows `vivado kernel boot mister`, kernel DTS, network boot, NFS root, `MISTER_CORES` |
| `board_files/`, `constraints/` | AMD board files (2.6), `zcu106_mister.xdc` (pins, clock groups, bus skew of the HDMI FIFO), `zcu106_core_buf.xdc` (clock region of the gated core clocks, cores without `G_FREE_CLK`) |
| `scripts/2025.2/` | `zcu106_mister.tcl`: block design and generator of every MiSTer design (`CORE=<core>`) |
| `hdl/zcu106_hdmi.vhd` | HDMI output: `hdmi_tx`/`i2s_rx` of `firmware/common/ip/hdmi-tx`, symbol FIFO into the transceiver clock, GTH wizard, clock lane |
| `hdl/zcu106_hdmi_ctl.vhd` | HDMI_CTL I2C sequence after configuration: Si5324 free run 148.5 MHz, DP159 (HDMI 1.4) |
| `scripts/si5324_regs.py` | divider search of the Linux driver, makes the register ROM of `zcu106_hdmi_ctl.vhd` |
| `dts/zynqmp-zcu106-revA.dts` | board DTS of linux-xlnx plus the MiSTer nodes: 0x1FF0_0000-0x3FFF_FFFF reserved for the PL |
| `tb/` | GHDL testbench of `zcu106_hdmi_ctl` (with the generic `i2c_bit_engine`), part of `make test` |

Designs: `zcu106_<core>` for each core profile (menu, msx, snes, psx, n64). `zcu106_mister.tcl` makes all of them
(`PLATFORM=zcu106 FLOW=vivado CORE=snes make create build`). The designs use the same `mister_zynq` and core files as
the Zybo. The board part is different only in these items:

- PS: `zynq_ultra_ps_e`.
  - The register window is HPM0_FPD at 0xA000_0000. Main_MiSTer finds it at runtime (patch 0002).
  - HP0-HP3 are for DDR.
  - Each PS-PL port is 128 bit wide. This is the reset value of the AFI registers, thus the FSBL needs no setting.
  - SmartConnects convert the 64-bit AXI3 masters of `mister_zynq`.
- Clocks: the PL runs on the board oscillator CLK_125, not on a PS clock. The MMCM `clk_base` makes 100/25 MHz, then
  `clk_core` uses the dividers of the Zybo. Thus the load of a core does not depend on the FSBL or on the Linux clock
  settings.
- Video: fixed 720p60 (ascal). No direct video.
  - The TMDS symbols of `hdmi_tx` at 74.25 MHz pixel clock go through `async_word_fifo`
    (`firmware/common/mister/hdl`) into the 37.125 MHz TXUSRCLK2 of three GTH lanes.
  - The lanes run at 742.5 Mb/s (20 bit raw, CPLL from the 148.5 MHz of the Si5324).
  - The TMDS clock lane is an LVDS output (ODDRE1) into the DP159.
- LEDs 0-3 are as on the Zybo (user, disk, power, stage C error). LEDs 4-7 show the HDMI status (I2C done, I2C error,
  transceiver up, FIFO running). Buttons: GPIO_SW_C OSD, GPIO_SW_N user.
- HDMI init state without the LEDs: `devmem2 0xA0000054 w` on the board (aux word 17 of `hps_bus_axi`, `dbg` of
  `zcu106_hdmi`). The bits are:

  - 7:0: ROM index of `zcu106_hdmi_ctl` (33 = all written, waiting for lock).
  - 11:8: state (0 reset, 1 power-up, 2 fetch, 3 delay, 4 transfer, 5 wait, 6 evaluate, 7 lock, 8 done, 9 fail,
    10 error).
  - 14:12: attempt.
  - 15: LOL.
  - 21:16: the status of LEDs 4-7 (I2C done, I2C error, TX reset done, power good, FIFO running, underflow).
  - 25:22: cause of the last failed attempt (one-hot: SCL held low, NACK, check, no lock).
  - 26: SCL on the pins.
  - 27: SDA on the pins.
  - 30:28: byte of the failed transaction (0 START, 1 address, 2 register, 3 data or Sr, 4 address+R, 5 read,
    6 STOP).

  After an error, the index and the state are those of the step that failed. Read the word only while a MiSTer
  design is loaded.

Software: the board starts from its own SD card up to U-Boot. We never write the card. The kernel (`FLOW=kernel`,
linux-xlnx with this DTS) and the root come over the network:

    PLATFORM=zcu106 FLOW=kernel make build                 # Image, DTB, linux-image .deb
    PLATFORM=zcu106 FLOW=mister make build package         # Main_MiSTer (armhf) and /media/fat with the cores
    PLATFORM=zcu106 FLOW=boot make tftpboot                # /srv/tftp/mister-zcu106 (kernel, DTB, pl/*.bit.bin), NFS root (sudo), U-Boot commands

The NFS root is a copy of the armhf RootFS of the Zybo (`firmware/build/zybo-z7-20/ubuntu24.04-console-rootfs`).
The arm64 kernel runs it through `CONFIG_COMPAT`. Thus Main_MiSTer is the same binary on both boards.
`firmware/common/mister/scripts/nfs-rootfs.sh` does these steps:

- It adds the arm64 modules.
- It sets the host name `mister-zcu106`.
- It disables the codec setup of the Zybo.
- It copies `/media/fat` of the package. The user files and the saved `config/` that are already there stay.

The boot menu of the card (`uEnv.txt`) has an entry "MiSTer (TFTP/NFS, fpga-mister)". This entry does these steps:

1. It loads `pl/zcu106_menu.bit.bin` over TFTP into the PL (`fpga load`). Main_MiSTer reads the ID register of the
   design at the start. Without a MiSTer design, that read hangs the bus.
2. It loads the kernel and the DTB.
3. It starts the kernel with the NFS root. Then `mister.service` starts Main_MiSTer.

Without the entry, the commands that `tftpboot` prints start the board from the U-Boot prompt. The commands do
not use `saveenv`. In that case, load the menu design before Main_MiSTer starts.
