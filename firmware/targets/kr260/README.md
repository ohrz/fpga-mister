# KR260 — Kria K26 SOM on the KR260 carrier (Zynq UltraScale+)

AMD Kria KR260 Robotics Starter Kit: K26 SOM with an XCK26 (`xck26-sfvc784-2LV-c`) and 4 GB PS DDR4, arm64 Linux.
The console is on PS UART1 (`ttyPS1`). The board has **no HDMI output**. Its only video output is the DisplayPort
of the PS (DPSUB, one lane on PS-GTR lane 1, AUX on MIO 27 to 30). The board has no audio codec and no PL buttons
or PL LEDs.

**State (2026-11-26): draft.** No design of this board was built, and nothing ran on the hardware. The generator
Tcl and the board profile are a proposal that follows the ZCU106 (`../zcu106/README.md`). The open items are at the
end of this file.

| Path | Content |
|---|---|
| `platform.mk` | Board profile: flows `vivado kernel boot mister`, network boot, NFS root, `MISTER_CORES` |
| `board_files/` | AMD board files of the K26 SOM (`kr260_som`) and of the carrier (`kr260_carrier`) |
| `constraints/kr260_mister.xdc` | Pins (25 MHz oscillator, fan enable), clock groups |
| `scripts/2025.2/kr260_mister.tcl` | Block design and generator of each MiSTer design (`CORE=<core>`), not run yet |
| `hdl/kr260_dp_live.vhd` | Video of `mister_zynq` into the live video input of the DisplayPort |
| `tb/` | GHDL testbench of `kr260_dp_live`, part of `make test` |

## Design

The designs are `kr260_<core>` for each core profile (menu, msx, snes, psx, n64). The generator
`kr260_mister.tcl` makes them, for example `PLATFORM=kr260 FLOW=vivado CORE=menu make create build`. The frame
(`mister_zynq`) and the core files are the same as on the Zybo and the ZCU106. These board parts are different:

| Item | KR260 |
|---|---|
| PS | `zynq_ultra_ps_e` with the board preset. The register window HPM0_FPD is at 0xA000_0000, as on the ZCU106. HP0 to HP3 are 128 bit wide. SmartConnects convert the 64-bit AXI3 masters of `mister_zynq` |
| Clocks | The 25 MHz carrier oscillator (SOM pin C3). MMCM `clk_base` makes 100 MHz and 25 MHz. `clk_core` makes the clocks of the Zybo from 100 MHz. MMCM `clk_pix` makes 74.25 MHz exactly (M 37.125, D 1, O 12.5) |
| Video | `ascal` gives a fixed 1280x720@60. `kr260_dp_live` puts `vid_*` into `dp_live_video_in_*` of the PS. The pixel clock goes to `dp_video_in_clk` |
| Sound | Open. The I2S of `mister_zynq` stays open in the draft |
| Buttons, LEDs | None on the PL. Open the OSD with the keyboard (F12). The DE10-Nano LEDs and the stage C error go to `board_status` (aux word 17, `devmem2 0xA0000054 w`): bits 7:0 LED, bit 8 stage C error |
| Fan | The fan enable (SOM pin A12, active low) stays low. The fan runs at full speed |

### DisplayPort live input

The DPSUB has two video sources: frame buffers in DDR (DPDMA, non-live) and the live input from the PL. The driver
`zynqmp-dpsub` of linux-xlnx 6.12 accepts a live input only as a DRM bridge. A display driver in the PL must then
own the CRTC. MiSTer has no such driver. This is the proposed sequence for the first test:

1. Linux starts the DisplayPort in the non-live mode with the mode 1280x720@60. The driver does the link training
   through the AUX channel.
2. A load of a MiSTer design starts `clk_pix` and the video of `ascal`.
3. A small tool changes the AV buffer manager of the DPSUB from the DPDMA to the live input. It also sets the PL
   video clock and the PL timing as sources (registers of the DisplayPort chapter of UG1085).

The driver uses the asynchronous clock mode (`SYNC_LOCK` off), so a small difference of the pixel clock does not
stop the stream. Alternatives if this sequence does not work:

- A small DRM driver for the PL source, with the DPSUB as a bridge (port@0 in the device tree).
- A video writer in the PL that writes the output of `ascal` into a frame buffer in DDR. The DPDMA then shows this
  frame buffer in the non-live mode, which the driver supports fully.

### Sound

The KR260 has no audio codec. The driver ignores the live audio input of the DPSUB (`live audio unsupported`).
These are the options:

- An I2S DAC on a PMOD connector of the carrier. It uses the I2S of `mister_zynq` as it is.
- The live audio input of the DPSUB (`dp_s_axis_audio_*`) with a converter from I2S to AXI4-Stream, set up by hand
  as the live video.
- USB audio through Linux.

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
| Generator Tcl | Not run in Vivado. Check the names `PSU__USE__VIDEO` and `dp_live_video_in_*`, the clock wizards and the clock region of the gated core clocks (`zcu106_core_buf.xdc`) |
| Device tree | A board DTS with the MiSTer nodes (reserved PL DDR from 0x1FF0_0000, `cma`), as `../zcu106/dts/` |
| AFI widths | Read the AFI registers under the Kria boot firmware before the first load (ZCU106: reset value 128 bit) |
| Live video | The tool of step 3 above. Component order of `dp_live_video_in_pixel1` (`G_ORDER` of `kr260_dp_live`) with color bars |
| Sound | Choose one of the options above |
| Fan | PWM from the PS TTC0 through EMIO, as the other designs of this board, instead of full speed |
| Size | XCK26: 117 120 LUT, 144 BRAM36, 64 URAM, 1 248 DSP. N64 and PSX must fit with the frame |
