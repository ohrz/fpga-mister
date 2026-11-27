# KR260 — Kria K26 SOM on the KR260 carrier (Zynq UltraScale+)

AMD Kria KR260 Robotics Starter Kit: K26 SOM with an XCK26 (`xck26-sfvc784-2LV-c`) and 4 GB PS DDR4, arm64 Linux.
The console is on PS UART1 (`ttyPS1`). The board has **no HDMI output**. Its only video output is the DisplayPort
of the PS (DPSUB, one lane on PS-GTR lane 1, AUX on MIO 27 to 30). The board has no audio codec and no PL buttons
or PL LEDs.

**State (2026-11-27):** the cores menu, MSX, SNES, PSX and N64 run with picture and sound through the DisplayPort. The open items are at the end of this file.

| Path | Content |
|---|---|
| `platform.mk` | Board profile: flows `vivado kernel boot mister`, network boot, NFS root, `MISTER_CORES` |
| `board_files/` | AMD board files of the K26 SOM (`kr260_som`) and of the carrier (`kr260_carrier`) |
| `constraints/kr260_mister.xdc` | Pins (25 MHz oscillator, fan enable), clock groups |
| `constraints/kr260_mmcm_frame.xdc`, `kr260_mmcm_compact.xdc` | MMCM sites of the two clock variants |
| `constraints/kr260_core_buf.xdc` | Clock region of the gated core clocks (SNES) |
| `scripts/2025.2/kr260_mister.tcl` | Block design and generator of each MiSTer design (`CORE=<core>`). `kr260_menu` builds with timing PASS (2026-11-26) |
| `hdl/kr260_dp_live.vhd` | Video of `mister_zynq` into the live video input of the DisplayPort |
| `hdl/kr260_dp_audio.vhd` | I2S of `mister_zynq` into the live audio input of the DisplayPort, test tone, counters |
| `tb/` | GHDL testbenches of `kr260_dp_live` and `kr260_dp_audio` |
| `sw/kr260_dp_live.py` | Switches the video and the audio of the DisplayPort to the live inputs of the PL and back. `package` installs it into `/usr/local/bin` (`MISTER_ROOTFS_TOOLS`) |
| `files/mister-rootfs/` | systemd units: `kr260-fan.service` (fan speed), `kr260-dp-live.service` (`kr260_dp_live.py on` 5 s after Main, `off` at the stop) |
| `sw/soak.py` | Soak test: in each round a load, a start of Main and a check each second |

## Design

The designs are `kr260_<core>` for each core profile (menu, msx, snes, psx, n64). The generator
`kr260_mister.tcl` makes them, for example `PLATFORM=kr260 FLOW=vivado CORE=menu make create build`. The frame
(`mister_zynq`) and the core files are the same as on the Zybo and the ZCU106. These board parts are different:

| Item | KR260 |
|---|---|
| PS | `zynq_ultra_ps_e` with the board preset. The register window HPM0_FPD is at 0xA000_0000, as on the ZCU106. HP0 to HP3 are 128 bit wide. SmartConnects convert the 64-bit AXI3 masters of `mister_zynq` |
| Clocks | The 25 MHz carrier oscillator (SOM pin C3). The XCK26 has only four MMCMs in one column. Frame variant (menu, MSX, SNES): MMCM `clk_base` makes 100 MHz and 25 MHz. `clk_core` makes the clocks of the Zybo from 100 MHz. MMCM `clk_pix` makes 74.25 MHz exactly. `clk_core` is next to `clk_base`, `clk_pix` gets its 25 MHz through the clock backbone (`kr260_mmcm_frame.xdc`). Compact variant (PSX, N64, the cores with two MMCMs of their own): no `clk_base`. `clk_pix` and `clk_core` take the pin directly. `clk_core` makes 100 MHz, 50 MHz and 24.573 MHz audio (VCO 900 MHz). The core MMCMs are the two lower sites (`kr260_mmcm_compact.xdc`), and `pll2_us.vhd` of the core makes NTSC and PAL with one MMCM |
| Video | `ascal` gives a fixed 1280x720@60. `kr260_dp_live` puts `vid_*` into `dp_live_video_in_*` of the PS. The pixel clock goes to `dp_video_in_clk`. `kr260-dp-live.service` switches to the live input after the start of Main if the DP mode of Linux is 1280x720 |
| Sound | `kr260_dp_audio` puts the I2S of `mister_zynq` into `dp_s_axis_audio_*` of the PS (live audio input of the DisplayPort, 48 kHz, 2 channels). `kr260_dp_live.py on` sets the audio registers |
| Buttons, LEDs | None on the PL. Open the OSD with the keyboard (F12). The DE10-Nano LEDs and the stage C error go to `board_status` (aux word 17, `devmem2 0xA0000054 w`): bits 7:0 LED (bit 6 is always 0), bit 8 stage C error |
| Fan | PS TTC0 channel 2 through EMIO to the fan enable (SOM pin A12, active low). `kr260-fan.service` sets `pwm1` 12 |

### DisplayPort live input

The DPSUB has two video sources: frame buffers in DDR (DPDMA, non-live) and the live input from the PL. The driver
`zynqmp-dpsub` of linux-xlnx 6.12 accepts a live input only as a DRM bridge. A display driver in the PL must then
own the CRTC. MiSTer has no such driver. This sequence works on the hardware (2026-11-27):

1. Linux starts the DisplayPort in the non-live mode with the mode 1280x720@60. The driver does the link training
   through the AUX channel.
2. A load of a MiSTer design starts `clk_pix` and the video of `ascal`.
3. A small tool changes the AV buffer manager of the DPSUB from the DPDMA to the live input. It also sets the PL
   video clock and the PL timing as sources (registers of the DisplayPort chapter of UG1085).

The driver uses the asynchronous clock mode (`SYNC_LOCK` off), so a small difference of the pixel clock does not
stop the stream.

The DP of the ZynqMP has no dual mode (DP++). Connect a DisplayPort monitor or an active DP to HDMI adapter. With a
passive adapter, HPD is high, but each AUX request times out, and the driver accepts no mode. `sw/kr260_dp_live.py`
does step 3: `on` sets the video layer to the live input (RGB, 8 bpc, PL clock and PL timing), `off` sets it back.
For step 1, add `video=DP-1:1280x720@60e` to the kernel arguments. The tool does two more things:

- It sets the global alpha of the blender to 0. The graphics layer is over the video layer and is black without a
  source. With alpha 255, the picture is black.
- It blanks and unblanks `fb0` first. The driver then trains the link again. A restart of the sink can drop the
  link without a message.
- It switches the main stream of the DP transmitter off and on. Without it, the transmitter keeps the frame
  position of the old source. Then the picture moves, and the vertical blanking of the PL shows as a flat band.

Alternatives, if the live input is not sufficient later:

- A small DRM driver for the PL source, with the DPSUB as a bridge (port@0 in the device tree).
- A video writer in the PL that writes the output of `ascal` into a frame buffer in DDR. The DPDMA then shows this
  frame buffer in the non-live mode, which the driver supports fully.

### Sound

The KR260 has no audio codec. The sound goes into the live audio input of the DPSUB. The driver ignores this input
(`live audio unsupported`), so `kr260_dp_live.py` sets it up by hand, as the live video.

- `kr260_dp_audio` (VHDL, `clk_audio`) receives the I2S with `i2s_rx` of `hdmi-tx`. It sends each sample pair as
  two AXI4-Stream beats: the sample in bits 27:12, the preamble 0 or 1/2/3 in bits 3:0, `tid` = channel.
- `clk_audio` also goes to `dp_s_axis_audio_clk`. `AV_BUF_CLK_SRC` bit 1 is 0 (audio clock from the PL).
- The live audio also needs the PS clock `dp_audio_ref`. The driver enables it only while a PCM is prepared.
  `kr260_dp_live.py on` opens and prepares the PCM in a background process and plays nothing. A PCM that plays
  makes the picture stop for a moment about each second.
- CTRL bits 7:3 of `hps_bus_axi` (`board_ctrl`) select test modes. Bit 3 is a 1 kHz test tone, bit 4 sets `tid` to
  0, bit 5 sets the preamble to 0. Main clears them at each core load. Use `kr260_dp_live.py tone on|off`.
- `board_status` bits 31:16 count the frames that the DPSUB took (48000/s), bits 15:9 count dropped frames. The core
  `menu` sends no audio (0 frames/s).
- After a stop of the audio of the transmitter, a receiver can need a mixer reset: `kr260_dp_live.py reset`.

## Software

**WARNING:** Never write the QSPI flash of the KR260. The Kria boot firmware and U-Boot are in it, and the board
does not start without them.

The proposal is the same as on the ZCU106: U-Boot of the QSPI stops at its prompt. Kernel and DTB come through TFTP,
and the RootFS comes through NFS. The U-Boot commands that `FLOW=boot make tftpboot` prints do not use `saveenv`.
The NFS root is a copy of the armhf RootFS of the Zybo. The arm64 kernel runs it through `CONFIG_COMPAT`, so Main is
the same binary on the three boards.

    PLATFORM=kr260 FLOW=kernel make build                 # Image, DTB, linux-image .deb
    PLATFORM=kr260 FLOW=mister make build package         # Main_MiSTer (armhf) and /media/fat with the cores
    PLATFORM=kr260 FLOW=boot make tftpboot                # /srv/tftp/mister-kr260, NFS root (sudo), U-Boot commands

The SD card of the carrier is a USB device (`/dev/sda`), not an SD controller of the PS.

## Open items

| Item | State |
|---|---|
| Generator Tcl | Done for all five cores. SNES (`kr260_core_buf.xdc`): WNS +1.510 ns. PSX and N64 (compact clocks): WNS +2.860 ns and +1.783 ns. The five cores run on the board |
| Clocks of PSX and N64 | Compact variant with 4 MMCMs. `pll2_us.vhd` passes its GHDL bench. `kr260_mister.tcl` processes `kr260_mmcm_compact.xdc` early, because the core XDC names the clocks of the core MMCMs. PSX and N64 give 48000 frames/s on the board |
| Device tree | Done: carrier overlay with the reserved memory |
| Live video | Done: `kr260_dp_live.py`, `kr260-dp-live.service`. The boot menu entry needs `video=DP-1:1280x720@60e` |
| Sound | Done: DP live audio. Open: a test on a TV (with the codes 1/2/3 the left channel can be one sample late) |
| Fan | Done: PWM from the PS TTC0 through EMIO. `kr260-fan.service` sets a fixed slow speed (`pwm1` 12 of 255) |
| Size | XCK26: 117 120 LUT, 144 BRAM36, 64 URAM, 1 248 DSP. The ZCU106 builds use 45 841 (SNES), 50 826 (PSX) and 55 552 (N64) LUT with the frame |
