# HDMI transmitter with audio (`hdmi-tx`)

Own VHDL (VHDL-93 for synthesis) that sends HDMI 1.4 with 2-channel L-PCM sound straight from
FPGA pins: TMDS video plus data islands (audio samples, clock regeneration, InfoFrames) in the
blanking, 10:1 serializers on 7-series SelectIO. It replaces Digilent `rgb2dvi` (DVI only, no
sound) with the same video inputs and pins. Written for MiSTer on the Zybo Z7-20 (designs
`zybo-z7-20_<core>_hdmi`), kept as a self-contained component that other projects can use.

## Files

| File | Entity | Task |
|---|---|---|
| `src/hdmi_out.vhd` | `hdmi_out` | top for a block design (module reference): reset bridge from `locked`, `i2s_rx`, `hdmi_tx`, one OSERDESE2 master/slave pair (10:1, DDR, bit 0 first) + `OBUFDS` (TMDS_33) per channel, clock channel `1111100000` |
| `src/hdmi_tx.vhd` | `hdmi_tx` | symbol level, board-neutral: video delayed by 11 clocks (look-ahead for preamble 8 + guard band 2), one data island per line, packet ECC, outputs three 10-bit symbols per pixel clock |
| `src/hdmi_audio.vhd` | `hdmi_audio` | collects up to 4 samples per Audio Sample Packet, IEC 60958 channel status, B flag every 192 frames, parity; CTS = pixel clocks per N/128 samples |
| `src/i2s_rx.vhd` | `i2s_rx` | Philips I2S, oversampled in the pixel clock (no clock of its own, `clk` ≥ 4 × BCLK) |
| `src/tmds_enc.vhd` | `tmds_enc` | 8b/10b TMDS video coding with running disparity, pass-through of control/TERC4/guard symbols |
| `src/hdmi_pkg.vhd` | package | control tokens, TERC4 table, guard bands, BCH step |
| `tb/hdmi_tx_tb.vhd` | `hdmi_tx_tb` + variants | independent decoder of the symbol stream (see Verification) |

Analysis order: `hdmi_pkg`, `i2s_rx`, `tmds_enc`, `hdmi_audio`, `hdmi_tx`, `hdmi_out`
(`tb/Makefile`, `VHDL93_SRC`). Only `hdmi_out` uses `unisim` primitives; `hdmi_tx` and below are
device-neutral.

## Interface of `hdmi_out`

| Port / generic | Meaning |
|---|---|
| `G_HDMI` (true) | false: DVI as `rgb2dvi` (no data islands, sound ignored) |
| `G_VIC` (4) | CEA-861 video identification code in the AVI InfoFrame (4 = 1280×720p60) |
| `clk_pix`, `clk_ser` | pixel clock and 5 × pixel clock from the **same** MMCM (serial clock for DDR 10:1) |
| `locked` | MMCM locked; low resets everything (asynchronous assertion, release synchronous to `clk_pix`) |
| `vid_data(23:0)`, `vid_de`, `vid_hs`, `vid_vs` | video in `clk_pix`, pixel order of `rgb2dvi`: red 23:16, blue 15:8, green 7:0; sync polarity is measured, either is fine |
| `i2s_bclk`, `i2s_lrclk`, `i2s_data` | I2S, asynchronous to `clk_pix`; 16 bit, 32 BCLK per frame, 48 kHz, LRCLK 0 = left, data change at the falling BCLK edge |
| `tx_clk_p/n`, `tx_data_p/n(2:0)` | TMDS pins (channel 0 blue, 1 green, 2 red) |

Generic of `hdmi_tx` not brought out by `hdmi_out`: `G_N` (6144 = ACR N for 48 kHz).

Block design example (Tcl, from `zybo-z7-20_mister.tcl`):

```tcl
add_files -norecurse [glob <repo>/firmware/common/ip/hdmi-tx/src/*.vhd]
set tx [create_bd_cell -type module -reference hdmi_out hdmi_tx_hdmi]
connect_bd_net [get_bd_pins clk_hdmi/clk_out1] [get_bd_pins hdmi_tx_hdmi/clk_pix]   ;# 74.25 MHz
connect_bd_net [get_bd_pins clk_hdmi/clk_out2] [get_bd_pins hdmi_tx_hdmi/clk_ser]   ;# 371.25 MHz
connect_bd_net [get_bd_pins clk_hdmi/locked]   [get_bd_pins hdmi_tx_hdmi/locked]
```

The pins keep the constraints of an `rgb2dvi` design (`IOSTANDARD TMDS_33`); `hdmi_out` declares
the `OBUFDS` itself, so the ports are plain `std_logic` (no `tmds_rtl` interface).

## How the stream is built

Data island (76 clocks): preamble 8 (CTL0..3 = 1010), guard band 2, two packets of 32
characters, guard band 2.

- Packet 1: Audio Clock Regeneration when a new CTS value is due (about every ms), otherwise the
  AVI or Audio InfoFrame (each every 64 lines), otherwise a Null packet.
- Packet 2: Audio Sample Packet (up to 4 samples), Null without samples.
- Channel 0: TERC4 {D3 = 0 only on the first character of the island, D2 = header bit / ECC,
  VSYNC, HSYNC}; channels 1/2: bit i = even/odd bit of subpacket i. ECC BCH(64,56) and (32,24),
  generator x⁸+x⁷+x⁶+1.
- AVI InfoFrame: RGB, 16:9, full range (Q = 2), VIC `G_VIC`. Audio InfoFrame: 2 channels,
  coding and rate from the stream.

Placement: the island starts 2 clocks after the active HSYNC edge (polarity from the level
lengths) when at least 4 control characters have run since DE fell and the measured DE start of
the lines leaves room for island, 4 control characters and the video preamble (92 clocks after the
edge; 720p has 260). Before the first active line and with too short a blanking there is no
island: the output is then DVI-like and sound is missing.

Audio clock: the I2S source need not be locked to the pixel clock. CTS is measured (pixel clocks
per 48 samples, nominal 74 250 at 74.25 MHz), the sink regenerates the audio clock from N/CTS.
At 48 kHz and 720p (one island per 22.2 µs line, a sample every 20.8 µs) a packet carries at most
2 samples.

## Verification

    make -C firmware/common/ip/hdmi-tx/tb          # vhdl93 + 4 benches, ~20 s; part of make test

`hdmi_tx_tb` decodes the symbol stream on its own (TMDS, inverse TERC4 table, BCH by polynomial
division) and checks pixels and sync at fixed latency, running disparity, video and island
preambles, guard bands, the D3 rule, ECC, every sample in order (none lost or doubled), channel
status, B flag, parity, CTS, InfoFrame checksums and the packet counts. Variants:
`hdmi_tx_neg_tb` (HSYNC active low), `hdmi_tx_fast_tb` (8 × the audio rate: several samples per
packet, samples in the load clock), `hdmi_tx_short_tb` (blanking too short: no island, video
right).

Evidence levels:

| Level | State |
|---|---|
| RTL simulation | PASS (GHDL, the four benches; 17 mutation probes, 16 caught, 1 equivalent) |
| Timing | `zybo-z7-20_msx_hdmi` routed: WNS +0.763 ns, WHS +0.012 ns (xc7z020-1, 74.25/371.25 MHz) |
| Hardware | Zybo Z7-20, 1280×720@60: picture as with DVI, 48 kHz sound over HDMI, headphone codec in parallel on the same I2S (2026-10-29) |

The serializer (`OSERDESE2`) has no local simulation model; only hardware checks it.

## Limits and extension points

Open items:

- one fixed video mode per bitstream (`G_VIC`), 16:9 RGB full range in the AVI InfoFrame;
- audio 48 kHz, 16 bit, 2 channels (N 6144, channel status for 48 kHz/16 bit);
- 7-series only (`OSERDESE2`, `TMDS_33`); UltraScale+ needs `OSERDESE3` or a GT/HDMI PHY;
- 1080p60 means 1.485 Gb/s per lane, above the 7-series HR-bank data rate of the -1 grade: not tried.
