# Architecture: MiSTer on Zynq

Status: 2026-11-26.

- Boards: Zybo Z7-20 (Zynq-7020) and ZCU106 (Zynq UltraScale+ ZU7EV) run on the hardware. The KR260 (Kria K26) is a
  draft that did not run. The differences of the boards are in the board contract (`doc/PORTING.md` §7.1) and in
  `firmware/targets/<board>/README.md`. This document describes the Zybo, if it does not name a different board.
- Cores: menu, MSX2/2+, SNES, PSX and N64. All of them are the unmodified MiSTer cores of their authors (credits:
  `README.md`).

If the evidence level of a statement is not obvious, the level is in parentheses:

- (Code) = read from the sources.
- (Sim) = testbench.
- (Synth) = Vivado synthesis.
- (HW) = on the board.
- (Estimate).

## 1. Mapping DE10-Nano → Zynq

| DE10-Nano (Cyclone V SoC) | Zynq (Zybo Z7-20) | Remark |
|---|---|---|
| HPS: 2× Cortex-A9, armhf Linux, 1 GB DDR3 | PS: 2× Cortex-A9, armhf Linux, 1 GB DDR3 | same CPU architecture: Main_MiSTer runs as an armhf binary |
| upper 512 MB of DDR (0x2000_0000–0x3FFF_FFFF) for the FPGA, handover page 0x1FFF_F000 | 0x1FF0_0000–0x3FFF_FFFF reserved in the device tree (`reserved-memory`, `no-map`) | same physical addresses → addresses of the cores and of Main_MiSTer unchanged |
| f2sdram ports (Avalon-MM) | AXI3 HP ports HP0–HP3 (64 bit) | bridge `avl_axi_bridge` (§3.1) |
| HPS↔FPGA GPO/GPI registers (hps_io protocol) | AXI-Lite register block in the PL through M_AXI_GP0 | §2 |
| FPGA manager, `.rbf` | Linux `fpga_manager`, `.bit.bin` | core change through fpgautil/sysfs |
| SDRAM module (32–128 MB, 16 bit SDR) | **not present** → DDR through HP ports | §3: the central method of this repository |
| ADV7513 HDMI transmitter (configured through I2C) | TMDS directly through SelectIO (Digilent `rgb2dvi`, VHDL) | 720p in the data sheet, 1080p outside the specification of the -1 speed grade |
| Audio through HDMI/I2S/SPDIF | SSM2603 codec (I2S) of the Zybo; HDMI audio from our own transmitter `hdmi_out` (§4.1) | |
| USB hub, Bluetooth | PS USB0 (ULPI PHY) as host, Linux drivers (`hid-playstation`, `btusb`) | Main_MiSTer reads evdev |
| SD card on the HPS | SD0 of the PS, Linux | `/media/fat` with `games/MSX/…` as on MiSTer |

## 2. HPS bus (Main_MiSTer ↔ hps_io)

Source: analysis of Main_MiSTer `b57370d` and Template_MiSTer `5dda373` (Code).

Main_MiSTer talks to the core over a 16-bit parallel bus with handshake. On the Cyclone V, this bus uses two registers
of the FPGA manager: **GPO 0xFF70_6010** and **GPI 0xFF70_6014** (`fpga_io.cpp:510-519`). Main maps them through
`/dev/mem`. In the PL, `sys_top.v:234-283` decodes them and makes `HPS_BUS` for `hps_io` in the core.

| GPO bit | Meaning | | GPI bit | Meaning |
|---|---|---|---|---|
| 15:0 | data to the FPGA (`io_din`) | | 15:0 | data from the FPGA (`io_dout`) |
| 17 | strobe | | 16 | `io_wide` (16-bit transfers) |
| 18 | ss0 = FPGA_EN | | 17 | ack |
| 19 | ss1 = OSD_EN | | 19:18 | protocol version = 1 |
| 20 | ss2 = IO_EN | | 28 | io_dig |
| 29 | LED | | 29 / 30 | OSD / USER button |
| 30 | reset request of the core | | 31 | 0 = core running |
| 31 | 1 = read status, 0 = magic (`0x5CA623` + ID) | | | |

- `fpga_spi()` writes the data, sets strobe and waits for ack = 1. Then it clears strobe and waits for ack = 0. The
  PL holds back ack while `io_wait` (ioctl_wait) or `vs_wait` is active (`sys_top.v:254-263`).
- The fast block functions (SD/VHD sectors, `fpga_io.cpp:723-1028`) do **not** check ack. They expect that the PL
  reacts in a few `clk_sys` cycles.
- `HPS_BUS[48:0]`: [15:0] dout, [31:16] din, 32 wide, 33 strobe, 34 io_enable, 35 fp_enable, 36 clk_sys, 37 io_wait,
  38–45 video signals.

**Zynq:** `hps_bus_axi` (VHDL, `firmware/common/mister/hdl/`) is an AXI4-Lite slave on M_AXI_GP0
(0x4000_0000, 4 KB). It replaces the GPO/GPI registers. The logic behind it stays that of `sys_top.v`, because
`sys_top.v` itself stays the top level (§7). This logic contains:
- Strobe and ack with `io_wait`/`vs_wait`, chip selects, core magic, reset decoder, LED.
- The system command handler (`sys_top.v:352-540`, commands 0x20–0x44: video mode, scaler, gamma, …).

Thus, in the block design, `hps_bus_axi` runs in register mode `G_RAW = true`. In this mode, it passes GPO into the
`clk_sys` domain to `sys_top` (under the handshake). It reads GPI from there. The native mode (`G_RAW = false`)
implements the logic of `sys_top.v:234-283` again. This mode is checked, but only a top level without `sys_top.v`
needs it.

Main_MiSTer has changes only in the access functions (mmap of 0x4000_0000 instead of 0xFF70_6010, §5).

| Offset | Register | Content |
|---|---|---|
| 0x0 | GPO (RW) | as on Cyclone V |
| 0x4 | GPI (RO) | as on Cyclone V (bit 31 = 0: magic, otherwise status) |
| 0x8 | ID (RO) | `0x5A4D5354` ("ZMST"), no side effect: Main can find the block before the first GPI access |
| 0xC | STATUS (R) / CTRL (W) | Read: bit 0 access lost to timeout (sticky), bit 1 `clk_sys` domain lags behind, bit 2 HP ports quiet (idle), bit 3 quiesce. Write: bit 0 quiesce (reset 0) |
| 0x10 + 4·i | AUX (RO) | only with `G_ADDR_W` 7 (`mister_zynq`): event counters `perf_counters`, i = 0 window number, 1–16 cycles per event in the last window of 2²⁷ master clock cycles (cycles, core edges, stall, pacer wait time, bucket full, misses, reads (`ev_hit`, each read counted once), miss cycles, drain, write FIFO full, writes, reads and misses in the upper half, misses on the most recently evicted line, of these evicted from the other half, misses on the line after the previous miss); stable over one window, read: number, counter, number. i = 17 (0x54): `board_status` of the board (ZCU106: HDMI init state of `zcu106_hdmi`, 0 elsewhere). The block ignores writes. Designs with `G_ADDR_W` 6 (11 counters) mirror 0x0–0xC again from 0x40, older ones already from 0x10 |

Rules (all checked in `hps_bus_axi_tb`):
1. The AXI **write response** comes only after the `clk_sys` domain has taken the new GPO value. A toggle handshake
   makes sure of this. The block holds the value until then, and all 32 bits arrive together. Only this lets the
   block functions work without ack, also at 5 MHz, at 150 MHz and with gated `clk_sys` (§3.7, stage C). The CPU only
   waits for the write response.
2. The block accepts a **GPI read** only when no write is pending. Writes have priority. The `clk_sys` domain samples
   the value `G_RD_WAIT` cycles after the request and returns it through a handshake.
   - Tolerance: the response latency of `io_dout` can be up to `G_RD_WAIT` + 5 `clk_sys` cycles after the strobe.
     With `G_RD_WAIT` = 2, this is 7 cycles. In register mode, `sys_top` itself costs 2 cycles (registers on GPO and
     GPI). Thus `G_RD_WAIT` = 4 gives the same tolerance of 7 cycles.
   - Measurement: sim sweep 0–3, worst case with back-to-back accesses in `fpga_spi_fast` and block reads.
   - `hps_io` itself has latency 0.
3. **`clk_sys` stopped** (core in reset without clock, gating stuck):
   - After `G_TIMEOUT` aclk cycles, the access ends anyway. GPI then reads `0xFFFFFFFF`, thus bit 31 = 1. Then
     Main_MiSTer reports "FPGA not ready" as on the Cyclone V.
   - While the domain lags behind, accesses end immediately and the block discards GPO writes. The pending value
     arrives when the clock runs again.
   - All responses are OKAY. SLVERR would be an external abort on the Cortex-A9 (SIGBUS in Main_MiSTer).
4. Main_MiSTer reads GPI only when the PL is configured (it checks the state of `fpga_manager`). On the Zynq, an
   access to an unconfigured PL hangs the bus. It does not return bit 31 = 1 as on the Cyclone V.

**CDC constraints:** The clock groups are asynchronous, as in the `sys_top.sdc` of MiSTer (§7). Vivado recognizes
these paths:
- 1-bit toggle synchronizers: `ASYNC_REG`, Vivado CDC-3.
- Data words `gpo_reg` → `gp_outr` and `gpi_snap` → `rdata`: the handshake holds them stable. Vivado reports them as
  CDC-15 ("clock enable controlled"). This is the intended pattern.

The counterpart in Main_MiSTer is the Zynq backend (`-DZYNQ`, §5).

Main_MiSTer uses these DDR addresses:
- 0x1FFF_F000: handover page (core environment, SDRAM configuration).
- 0x2000_0000: framebuffer of the scaler `ascal`.
- 0x2200_0000: Linux framebuffer and menu backgrounds.
- From 0x3000_0000: ROM load areas of some cores (`fpga_mem()`).

Thus the device tree reserves 0x1FF0_0000–0x3FFF_FFFF.

## 3. Method: SDRAM of the MiSTer cores → DDR of the Zynq (HP ports)

### 3.1 Starting point

MiSTer cores use external memory in two ways:

1. **`DDRAM_*`** (Avalon-MM, 64 bit, bursts up to 255, `waitrequest`): the HPS DDR through f2sdram. This path
   tolerates latency. The scaler `ascal` (VHDL) also uses an Avalon port for its framebuffers.
2. **`SDRAM_*`** (pins of a 16-bit SDR SDRAM module: CS/RAS/CAS/WE, BA, A, DQM, DQ): each core brings its own SDRAM
   controller. This controller often has **fixed timing** (fixed CAS latency, fixed time slots, no wait states).
   Example MSX (Code):
   - `emsx_top.vhd` splits each 10.7 MHz cycle into a CPU slot and a VDP slot at 85.9 MHz.
   - The controller captures the read data a fixed 3 cycles after the READ.
   - The CPU has no wait state for RAM accesses.

The Zynq has no SDRAM, only the PS DDR behind the HP ports. A read there takes 100–250 ns (Estimate). An SDRAM
access takes 20–60 ns. A bridge solves path 1. Path 2 needs a method.

### 3.2 Building blocks (board- and core-neutral, VHDL, `firmware/common/mister/hdl/`)

| Block | Task | Status |
|---|---|---|
| `avl_axi_bridge` | Avalon-MM (MiSTer `DDRAM_*`, `ascal`, SDRAM backend) → AXI3 HP; bursts ≤ 16 beats, never across 4 KB, read/write order kept; write buffer with 4 entries in front of the W channel, `avl_waitrequest` only from registers (no combinational path from `WREADY` into the core); a write command withdrawn before acceptance is discarded or completed with WSTRB-0 beats | done, testbench PASS with mutation probe (Sim), PSX boot series (HW) |
| `sdram_emu` | SDRAM **pin** emulator: decodes the commands of an unmodified core (ACT/READ/WRITE/PRE/BST/REF/MRS, bank, row, column, DQM, burst length 1/2/4/8 sequential/interleaved, write burst mode, CAS latency from the mode register) into word accesses on a generic backend port (req/ready, rvalid in order); delivers read data at the edge at which the core samples; `ce`/`stall` for clock stopping (stage C) | done: testbench PASS with mutation probe, with `ce`/`stall` in the stage C system test (Sim); 132 LUT, 72 FF, routed at 85.9 MHz WNS +2.7 ns (Timing, OOC) |
| `sdram_bram` | BRAM backend (stage B): always ready, read data one cycle after the request, byte writes | done (Sim); 128 KB = 32 BRAM36 |
| `sdram_region` | region decoder: mask/value on the flat word address (bank & row & column) → b0 **BRAM** (fixed latency) or b1 **DDR** through the cache; BRAM address from any scattered address bits (packed, `G_B0_SEL`); read data in request order, because a read goes to one backend only when the other has no outstanding read | done (Sim, in the system test) |
| `sdram_cache` | BRAM cache in front of the DDR: direct-mapped, on the word address in the order of the core (`mister_zynq` `G_CACHE_COL_HIGH`), line 32 bytes (`G_LINE_LOG2`), 512 lines = 16 KB (`G_INDEX_BITS`); `G_SPLIT` 1: top address bit as top index bit, each address half gets half of the lines (`mister_zynq` `G_CACHE_SPLIT`); miss classes for the event counters (victim tag RAM); hits with 1 cycle latency like `sdram_bram`, one request per cycle; write-through with write FIFO, no allocation on write miss; miss → drain FIFO, line as one Avalon burst through `avl_axi_bridge`, look up the request again | done: testbench PASS with mutation probe (Sim) |
| `core_clock_stall` | CE signals for BUFGCE on the free-running master clock: core edge only when no `stall` is present and the **pacer** has an earned edge (token bucket, rate `G_NUM/G_DEN`, with `alt` = 1 `G_NUM_ALT/G_DEN_ALT`: core clock change such as SNES PAL, port `ZYNQ_PACE_ALT`); derived core clocks as every N-th granted pulse (§3.7) | done: testbench PASS with mutation probe (Sim) |
| `clk_pulse_div` | derived core clock as every N-th master pulse (BUFGCE) plus an optional mid clock for logic on the falling edge of the original clock (§3.7); the replacement `pll.vhd` of a profile uses it | done: testbench PASS with mutation probe (Sim), HW (SNES pattern) |
| `video_pll`, `pll_reset` | PLLE2 for direct video from the `CLK_VIDEO` of the core (§4); reset sequencer for PLLs/MMCMs whose input clock starts only after the PL configuration (core MMCMs of the stage D profiles, `video_pll`) | done: testbenches PASS (Sim), HW (N64, PSX) |
| `audio_i2s_simple` | core audio directly to I2S instead of `audio_out` (macro `MISTER_ZYNQ_SIMPLE_AUDIO`, saves area) | done (Sim), HW (N64) |
| `perf_counters` | event counters in the master clock over windows of 2^`G_WIN_LOG2` cycles, snapshot + window number, readable through `hps_bus_axi` AUX (§2); `mister_zynq` counts 16 events of stage C, among them the miss classes of `sdram_cache` (victim tag RAM, next line, upper half) | done: testbench PASS with mutation probe (Sim), HW |

The system test `sdram_stagec_tb` uses a random SDRAM controller as the "core" on the gated clock. Behind it is the
full chain: emulator, region decoder, BRAM bank, cache, bridge, AXI DDR model with 20 cycles read latency, pacer
21/22. The core counts its own edges and sees an ideal SDRAM: each read beat comes at edge CL+1, also with stalls. The
test also checks the error flags, the phase of the derived clock and the real time (never more core edges than
earned).

The HP ports have a static assignment. Thus the PL needs no arbiter of our own (the PS DDR controller arbitrates):
- HP0: SDRAM replacement (latency-critical).
- HP1: scaler.
- HP2: `DDRAM_*` of the core.
- HP3: free.

### 3.3 Stages of the method (from the most general to the most specific)

**Stage A – Avalon cores (`DDRAM_*`)**: `avl_axi_bridge` connects directly to an HP port. The core does not change.

**Stage B – pin emulation from BRAM**: `sdram_emu` with BRAM backend is behind the unmodified `SDRAM_*` pins. It
operates exactly like an SDRAM, and the core does not change. This stage is only for the memory that the core
actually uses and that fits into BRAM:
- Zybo: 300–400 KB next to the rest.
- ZCU106 with UltraRAM: several MB.

It is good for small cores and for single regions (for example the VRAM of the MSX).

**Stage C – pin emulation with DDR backend and clock stopping (default method)**: `sdram_emu` + `sdram_region` +
`sdram_bram` + `sdram_cache` + `core_clock_stall` (with pacer). The core does not change:
- Regions with a fixed, dense access pattern (video RAM) stay in BRAM permanently.
- All other regions are in the reserved DDR. Reads go through the cache. On a miss, the clocks of the core stop before
  the core captures the read data. From the view of the core, the SDRAM answered on time. Writes go through a buffer
  and do not stop the clocks, unless the buffer is full.
- Real time: the core runs faster than its nominal clock, for example at 105–110 %. The `pacer` distributes the
  headroom. While the miss time per frame stays below the headroom, the emulated core runs exactly in real time on
  average. Video and audio are decoupled anyway. Video goes through the framebuffer of the scaler (`ascal`), and audio
  goes through a FIFO.
- Preconditions, checked for each core:
  - All state of the core is in the stopped clock domains.
  - `hps_io` stops as well (the HPS bus has a handshake, and Main_MiSTer waits).
  - The core tolerates the increased clock (timing).
- Settings for each core:
  - The clock that drives the SDRAM.
  - The CAS latency.
  - The **sampling point** of the read data: CL or CL+1. It depends on the phase at which the original controller
    samples DQ.

**Stage D – controller replacement**: The SDRAM controller of the core can have a handshake interface (req/ack,
busy). Then a replacement file replaces only this module. The replacement file has the same name and the same ports,
and it goes to the DDR through cache/`avl_axi_bridge`. No clock stopping is necessary. Stage D uses a file
replacement instead of a patch. The upstream file stays as it is, and the file list from `files.qip` (`qip.tcl`)
gets the replacement file.
- For this stage, the framework changes to a free-running core clock with `G_FREE_CLK` = 1 (Sim). The core clock is
  then `clk_master` directly, and stage C and HP0 are off.
- With `G_DDRAM` = 1, `DDRAM_*` goes to HP2.
- The replacement controller has an Avalon master instead of the SDRAM pins. This master comes out of the core as the
  emu port `COREMEM_*` (names like `DDRAM_*`). The rules `add_port`/`connect_port` make this port.
- `sys_top_zynq` always has the ports `ZYNQ_coremem_*` for this purpose. The macro `MISTER_ZYNQ_COREMEM` connects them
  to emu. Without the macro, they are tied off.
- With `G_COREMEM` = 1, `mister_zynq` routes them through an `avl_axi_bridge` on their clock to HP3 (mapped from
  `G_SDRAM_BASE`).

Stage D is in use for N64 (`cores/n64/sdram.vhd`) and PSX (`cores/psx/sdram.vhd`), both HW.

**Stage E – minimal core patch**: The patch adds wait states at the place where the core already knows wait states.
MSX: `WAIT_n` of the Z80 for `RamReq and not RamAck`, like the existing OPLL wait state. Stage B is added for the
VRAM. This stage is only for a core for which stage C and stage D do not work.

Stages in use:
- Stage C: menu, MSX and SNES (HW).
- Stage D: PSX and N64 (HW).
- Stage B: the BRAM region inside stage C (MSX VRAM).
- Stage E: not necessary up to now.

### 3.4 Timing contract of the emulator (applies to every core)

The emulator runs on the clock with which the core operates its SDRAM controller. The controller registers its
command outputs on the rising edge. This is the rule in MiSTer cores. A core that outputs on the falling edge needs
its own setting.

In cycle *k* with a READ/WRITE, the beat goes combinationally to the backend. The emulator takes write data and DQM
from the same cycle. Read beat *i* is on DQ from edge `CL + G_RD_ADJ + i` (edge 1 ends cycle *k*). It stays until the
next beat.

`G_RD_ADJ = 0` fits cores that sample DQ at edge CL+1. MSX: `SDRAM_CLK` = inverted `clk_mem`, the chip delivers in
the middle of the cycle, and the core captures at the next edge. Find `G_RD_ADJ` in the controller of each core (core
port profile, §3.6).

### 3.5 Memory map of the MSX core (Code, `emsx_top.vhd`)

The MSX core has an 8 MB SDRAM address space (23-bit byte address, 16-bit words, burst length 1, CL 2):

| Range | Content | Target (stage C) |
|---|---|---|
| 000000–3FFFFF | memory mapper RAM 2048/4096 KB | DDR + cache |
| 400000–5FFFFF | ESE-SCC1/2 (virtual MegaSCC cartridges) | DDR + cache |
| 600000–67FFFF | ESE-RAM 512 KB: BIOS images (the IPL loads them from the VHD), Kanji | DDR + cache |
| 700000–7FFFFF | VRAM (128 KB used, pages through `vram_slot_ids`) | BRAM |

The core itself loads its BIOS (`OCM-BIOS.DAT`) and its programs from a VHD image. It uses the SD card emulation of
`hps_io` (Nextor/MegaSD). The game ROMs are in the FAT16 file system of this image (original MiSTer behavior).

### 3.6 Core port profile: more MiSTer cores (SNES, N64, …)

Goal: you can bring another MiSTer core to the Zybo or to another Xilinx board. The board design and the SDRAM
replacement do not change. `doc/PORTING.md` gives the procedure step by step. Each core has one profile with all
core-specific parts under `firmware/common/mister/cores/<core>/` (template `cores/_template/`):
- `core.tcl`: checkout, exclusions, replacement files, Verilog macros of the `.qsf` (`core_defines`), generics of
  `mister_zynq`, master clock.
- `rules.py`: Vivado source rules of the core with expected match count (`prepare_sources.py` reads them).
- `core.xdc`: derived clocks of the core.
- Replacement files (MSX, menu: `pll.vhd`).

The profiles are:
- `menu` (Menu_MiSTer, `menu.rbf`).
- `msx` (MSX_MiSTer).
- `snes` (SNES_MiSTer).
- `psx` (PSX_MiSTer).
- `n64` (N64_MiSTer).

`doc/PORTING.md` §6 compares all of them. The table below shows the two simplest profiles in detail.

`scripts/mister_project.tcl` reads the profile in the board script (§7). Board- and core-neutral replacements for
Intel megafunctions are in `hdl/intel/` (`altsyncram`, `altddio_out`):

| Entry | MSX | Menu |
|---|---|---|
| Checkout, file list, exclusions | `MSX_MiSTer`, `files.qip`, `*/VM2413/*` | `Menu_MiSTer`, `files.qip`, `*/rtl/pll*` |
| Rules/patches | `cores/msx/rules.py` (3); patch `cores/msx/patches/0001` + `cores/msx/scc_rom_hide.vhd` (game switching, §5.3) | `cores/menu/rules.py` (4: `inout reg SDRAM_DQ` in `rtl/sdram.sv`; clock for the LFSR) |
| Macros | – | `MENU_CORE=1` (OSD header line, `ascal` `N_BURST` 2048 → 1024) |
| Core clocks (replacement of the Quartus PLL) | `cores/msx/pll.vhd`: `clk_mem` = gated master clock (`CLK_50M`), `clk_sys` = every 4th pulse (§3.7) | `cores/menu/pll.vhd`: `clk_sys` = `CLK_VIDEO` = gated master clock (original 100 MHz, here 85 MHz, pacer 1/1; at 90 MHz the `ascal` downscaler input fails timing); `cores/menu/lfsr.vhd` clocked instead of an `lcell` ring |
| SDRAM: clock, geometry, sampling phase | `clk_mem`, 2/13/9 bits (bank/row/column), `G_RD_ADJ` 0 | `clk_sys`, 2/13/9 bits (size detection reports 32 MB), `G_RD_ADJ` 0 |
| Regions | VRAM (column bits 8:6 = `111`) → BRAM 128 KB; rest → DDR + cache | none (`G_B0_BITS` 0), all through the cache |
| Address order of cache and DDR image (`G_CACHE_COL_HIGH`) | 1: bank·column·row = CPU address(22:1), because the controller maps CPU address(13:1) to the row | 0: bank·row·column |
| second SDRAM (`MISTER_DUAL_SDRAM`), `DDRAM_*` | no / no | no / yes (clearing and Linux console, still tied off, §5.2) |
| Special features | `hps_io` options, audio width, video clock | frame rate ≈ 51 Hz instead of 60 Hz (pixel clock `clk_sys`/8); at 85 MHz the wizard hits audio exactly (24.5773 MHz), master 84.79 MHz, 50 MHz clock 49.88 MHz |

For each core, these items remain to check:
- Quartus special features in the sources.
- Intel megafunctions.
- Phase and CAS latency of the SDRAM controller.
- Size compared with the FPGA of the board.

Size on the XC7Z020 (measured, `STATUS.md` of each core):
- MSX fits with headroom.
- SNES fits without the SPC7110 and with 128 KB backup RAM.
- PSX fits without savestates and other options.
- N64 fits with most options fixed. But it closes timing only at 2/3 of its clocks (80 %: −0.029 ns on two
  endpoints). At 100 %, it runs on the test board outside its constraints.

Larger devices (XC7Z100, ZynqMP) would remove these compromises.

### 3.7 Clock stopping (stage C): a gated master clock

A core often has more than one clock. MSX: `clk_mem` 85.9 MHz for the SDRAM controller, `clk_sys` = `clk_mem`/4, both
at phase 0. If two MMCM outputs stopped separately, their phase relation would not be correct after a pause. Thus:

- **Master clock** = the fastest core clock (MSX `clk_mem`). It is free-running from the MMCM, a few percent above
  nominal. MSX: VCO 945 MHz / 10.5 = 90.0 MHz instead of / 11 = 85.909 MHz, pacer `G_NUM/G_DEN` = 21/22, exact.
- Emulator, region decoder, BRAM, cache and bridge run on the **free-running** master clock.
- The core gets the master clock through **BUFGCE** (CE = `ce`). A stopped edge is a missing pulse, without glitches.
  - `ce = not stall and token`. `stall` is the OR of the `stall` outputs of all `sdram_emu` instances.
  - `clk_master_gate` drives the BUFGCE `core_buf`. `clk_master_gate` is a second MMCM output with the divider and
    phase of the master clock, but without a BUFG.
  - Thus the BUFG cascade of the core clocks starts only at `core_buf` (adjacent BUFGCTRL sites). Logic and HP0 stay
    on the buffered `clk_master`.
- **Derived clocks** (MSX `clk_sys`): BUFGCE on the **same** master clock, CE = every N-th granted pulse. There are
  two equivalent places:
  - `ce_div1` of `core_clock_stall` (counter in the free-running clock), if the top level supplies the clocks.
  - A **replacement `pll` in the core profile** (`cores/msx/pll.vhd`). This is the normal case, because almost every
    core instantiates its PLL itself. The top puts the gated master clock on `CLK_50M`. The replacement `pll` passes
    it through as `clk_mem`. It makes `clk_sys` with a BUFGCE on this clock. The CE comes from a counter in the same
    gated domain (it counts exactly the granted pulses). The core needs no patch.

  The core sees the same edge sequence for all clocks as with the original PLL. This is true at each point where the
  core stops.

  Cost: the high time of the derived clock is that of the master clock (5.6 ns instead of 23 ns). Thus falling edges
  of derived clocks need their own mid clock. Example SNES `clk_sys_mid`: the master pulses at which the original
  clock falls. A patch changes each falling edge into a rising edge of that clock. MSX does not need it: the only
  falling edge is `emsx_top.vhd:599` on `memclk` = master clock. Constraint:
  `create_generated_clock -source <BUFGCE>/I0 -edges {1 2 9}` (N = 4: edges 1, 2, 2N+1).
- During `rst`, `ce = not stall` applies, because synchronous resets in the core need edges. The dividers continue
  to count.
- Combinational path: cache tag RAM → compare → `ready`/`rvalid` → `stall` of the emulator → BUFGCE CE. This path
  sets the master clock frequency. The token arithmetic of the pacer is not in this path. The logic calculates both
  next values in advance, and `ce` selects one.
- All logic that talks to the core treats its clocks as separate clock domains:
  - `hps_io` runs on `clk_sys` (gated). Thus the HPS bus has a handshake across the domain boundary (`hps_bus_axi`,
    §2).
  - `ascal` takes video with `i_clk` = gated clock (asynchronous framebuffer).
  - Audio goes through a FIFO.

## 4. Video

The video path has these parts, in this sequence:
1. Core (15 kHz).
2. Scandoubler/OSD (MiSTer `sys/`).
3. `ascal` (framebuffer in the reserved DDR, HP1).
4. 720p60 (fixed mode, §6).
5. `rgb2dvi` (DVI) or `hdmi_out` (HDMI with sound, §4.1).
6. HDMI connector.

`ascal` is VHDL and has an Avalon port. This port connects to `avl_axi_bridge`.

The memory side of `ascal` (Code):
- Word addresses.
- Fixed bursts of 16.
- Byte enables always 1.
- One command at a time.
- Read data without backpressure.

With `N_DW=64`, `N_BURST=128`, each `ascal` burst is exactly one 16-beat AXI3 burst on the 64-bit HP port (trial
synthesis). Audio: `rgb2dvi` does not carry audio. Thus audio goes through I2S to the SSM2603 of the Zybo. The
`_hdmi` designs also send it in data islands over HDMI (§4.1).

**Direct video without `ascal`** (N64, profile `G_DIRECT_VIDEO` 1 and macro `MISTER_DEBUG_NOHDMI`):
- `sys_top` then has no scaler and no HDMI PLL. `HDMI_TX_*` come from the VGA branch (scanlines, VGA OSD) with the
  video clock of the core (`CLK_VIDEO`). This saves the area of `ascal`, and HP1 stays quiet.
- The core must supply 31 kHz itself. The N64 profile puts the `video_mixer` from `sys/` behind the VI, with the
  scandoubler always on. This changes 15.7 kHz → 31.5 kHz: 1547 × 525 cycles at 48.68 MHz, one pixel = 2 cycles. The
  line and frame rate are like 480p60.
- `prepare_sources.py` replaces the DE of `sys_top` with the DE of the picture (`vga_de_osd`, delayed by 6 cycles like
  the data). The DE of `sys_top` is high outside the sync pulses, for VGA DACs. Without this change, `hdmi_out` would
  find no blanking interval for its data islands.
- `sys_top_zynq` outputs the clock of `HDMI_TX_*` as `ZYNQ_CLK_HDMI_TX`. `mister_zynq` uses `video_pll` to derive
  `vid_clk` and the 5× clock `vid_clk_ser` from it. `video_pll` is a PLLE2 with feedback through BUFG. Thus its clocks
  are phase-aligned, and Vivado times them synchronously.
- The PLL stays in reset until its input is stable. The video clock comes only after the core PLL, and it can
  disappear during a core change.
- The generator Tcl then connects the transmitter to `mister/vid_clk`, `vid_clk_ser`, `vid_locked` instead of
  `clk_hdmi`. The AVI InfoFrame has no VIC (`G_VIC` 0), because 1547 × 525 at 48.68 MHz is not a CEA mode. Only
  hardware can show if a sink accepts this.

Audio to the SSM2603 (Code `audio_out.sv`, `i2s.v`):
- The PL is the I2S master. MCLK is `clk_audio` (24.576 MHz nominal, −110 ppm). BCLK is 1.536 MHz (32 bits per
  frame). The format is Philips I2S, 16 bit, 48 kHz.
- `hdmi_audio_96k=1` in `MiSTer.ini` would send 96 kHz. This does not agree with the codec setting.
- Linux configures the codec once at boot through PS I2C0 (EMIO, `/dev/i2c-0`, address 0x1a). It uses
  `ssm2603-init.sh` (`ssm2603.service`, board files `firmware/targets/zybo-z7-20/files/mister-rootfs/`).
- Codec setting: slave, I2S, 16 bit, MCLK/2 = 12.288 MHz (256 fs, normal mode) → 48 kHz. The DAC goes to the
  headphone output at 0 dB (`SSM2603_HP_VOL`). The power-up sequence is as the data sheet specifies.
- There is no codec node in the device tree and no Linux sound card.
- `make test` checks the register sequence (step 6, golden values).
- On the board, the sound at the headphone output is clean (listening test with an SCC game, 2026-10-29, boot from
  the card with `ssm2603.service`).

### 4.1 HDMI with sound (`hdmi-tx`, designs `zybo-z7-20_<core>_hdmi`)

The Zybo HDMI connector connects directly to FPGA pins (bank 35, TMDS_33). There is no HDMI transmitter chip.
`rgb2dvi` sends only DVI (video and control characters). For sound, HDMI needs data islands in the blanking interval.
Our own VHDL transmitter `hdmi_out` makes them. It is the component `firmware/common/ip/hdmi-tx`
(sources `src/`, testbench `tb/`). Its README describes the
structure, the data stream, the tests and the limits. This section describes only the integration:

- The generator Tcl selects the transmitter with `video_tx`. `dvi` is the default. `hdmi` comes with `VIDEO=hdmi` or
  with the design `zybo-z7-20_<core>_hdmi`. The DVI designs stay the same. Both use the same pins (`hdmi_out_*`) and
  the same XDC. With `hdmi`, the sources come from `firmware/common/ip/hdmi-tx/src`.
- Video: `vid_*` from `mister_zynq` (order of `rgb2dvi`), pixel clock 74.25 MHz and 371.25 MHz from `clk_hdmi`. AVI
  InfoFrame VIC 4 (720p60) and full quantization range (MiSTer sends 0–255).
- Sound: the I2S stream from `sys_top` (`mister/i2s_*`, the same nets as to the SSM2603). Thus the headphone output
  continues to work in parallel. `clk_audio` (−110 ppm) is not locked to the pixel clock. The transmitter measures
  CTS.
- Blanking: at 720p, there are 260 cycles between the HSYNC edge and the start of the line. An island with its guard
  spacing needs 92. Thus each line carries an island.

Hardware (2026-10-29, `zybo-z7-20_msx_hdmi`): the picture is 1280×720@60 as with DVI.
The sound of an SCC game comes over HDMI (48 kHz) and at the same time on the headphones (listening test).

### 4.2 Video output of the ZynqMP boards

`mister_zynq` gives the same video on each board: `vid_*` on `clk_hdmi` (order of `rgb2dvi`), 1280×720@60, and the
I2S of `sys_top`. Only the output stage after it is board-specific:

| Board | Output stage | Sound |
|---|---|---|
| ZCU106 | `zcu106_hdmi`: the symbol generator `hdmi_tx` (`hdmi-tx`, as in §4.1), three GTH lanes and the DP159 retimer. The pixel clock comes from the Si5324 | In the HDMI data islands |
| KR260 (draft) | `kr260_dp_live`: `vid_*` into the live video input of the PS DisplayPort (`dp_live_video_in_*`). The PL gives the pixel clock and the timing. Linux trains the link | Open |

The KR260 has no HDMI output. Its DisplayPort is a part of the PS (DPSUB). Linux starts it from a frame buffer in
DDR. A tool then changes the source of the DPSUB to the live input. The sequence and the alternatives are in
`firmware/targets/kr260/README.md`.

## 5. Software

Linux (linux-xlnx 6.12, Ubuntu 24.04, armhf) comes from the Linux and RootFS flows of the repository. It uses the
kernel fragment `firmware/common/linux/kernel.config` of every board (UIO, evdev, uinput, HID PlayStation/Sony,
Bluetooth over USB). `fpga_manager` (`CONFIG_FPGA_MGR_ZYNQ_FPGA`) and `/dev/mem` without `STRICT_DEVMEM` come with the
Xilinx defconfig.

### 5.1 Main_MiSTer with Zynq backend

The patches are in `firmware/common/mister/patches/Main_MiSTer/`. They apply against the pin `b57370d`.
`prepare_sources.py` applies them. Without `ZYNQ`, the Cyclone V code stays the same:

| Patch | Content |
|---|---|
| 0001 | `make ZYNQ=1`: `-DZYNQ`, `-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard` |
| 0002 | `fpga_io.cpp`, `main.cpp`: Zynq backend (below) |
| 0003 | `input.cpp`: `input_event_sec/usec` instead of `.time`, so that the build also works with 64-bit `time_t` (Ubuntu armhf) |
| 0004 | `fpga_io.cpp`: quiesce the HP ports before a load (CTRL/STATUS, below) |

Zynq backend (`fpga_io.cpp`, `#ifdef ZYNQ`):
- **Registers:** mmap of 0x4000_0000 (4 KB): GPO +0x0, GPI +0x4, ID +0x8 (§2). All functions above
  `fpga_gpo_write`/`fpga_gpi_read` (SPI, block functions, buttons, LED, reset) stay the same.
- **Bus protection:** `pl_ok` = `fpga_manager` reports `operating` **and** the ID register returns `0x5A4D5354`.
  - Without `pl_ok`, Main discards GPO writes, GPI reads −1 (bit 31 = "not ready"), and `fpga_spi` returns
    immediately. Thus Main never accesses GP0 without a MiSTer design (rule 4 in §2).
  - The ID check itself requires that a configured design has a slave at 0x4000_0000. Thus the boot design must be a
    MiSTer design.
- **Quiesce of the HP ports** (patch 0004): before a load, `zynq_load` sets CTRL bit 0 and waits up to 200 ms for
  STATUS bit 2.
  - `mister_zynq` then holds both bridges (`avl_axi_bridge` `hold`: no new command, a running one completes).
  - It reports idle when no transaction is outstanding on HP0 and HP1 (and HP2). The core stalls at its next SDRAM
    access.
  - Without the quiesce, an outstanding transaction would stay in the AFI of the port and cripple the next design.
  - Designs without the register never report idle. The 200 ms give the core time for all that `fpga_core_reset(1)`
    starts (the MSX clears its memory through HP0).
- **Load of a core** (`fpga_load_rbf`):
  - Main writes the payload (without the `MiSTer` header, if present) to `/lib/firmware/mister/core.bin` (tmpfs).
  - Then it sets `flags` = 0 and `firmware` = `mister/core.bin` in the sysfs of `/sys/class/fpga_manager/fpga0`
    (linux-xlnx). The write returns only after the configuration.
  - Then `app_restart` follows, as on the Cyclone V.
  - The driver requires a **byte-swapped `.bin`** with sync word (`bootgen -process_bitstream bin`, the `.bit.bin` of
    the vivado flow). The file name stays `<core>.rbf`, because Main hard-codes the extension.
- **Start without a MiSTer design:** Main loads `menu.rbf` and restarts on it. It does not exit. If the start already
  follows a load of `menu.rbf`, Main exits as before (no load loop).
- **JTAG/bus lost** (`fpga_wait_to_reset`): Main waits until `pl_ok` is true and GPI responds. Then it does
  `app_restart` without a core path. There is no U-Boot that rescues the design across a warm reset.
- **`reboot`:** `systemctl --no-block reboot`, otherwise the `reboot` system call. The handover page 0x1FFF_F000 stays
  reserved, but the restart does not need it. A core with an alternative configuration (U-Boot core loader) loads
  without it.
- No ADV7513: `video.cpp` finds this and skips it. Without EDID, a fixed `video_mode` in `MiSTer.ini` is necessary
  (§6).

Evidence:
- Code: linux-xlnx `fpga-mgr.c` (`firmware` WO, `flags` RW, `state`), `zynq-fpga.c` (sync word check).
- Build: cross build with and without `ZYNQ` without errors, no warning in the modified files. The `.bit.bin` of the
  MSX design has the sync word in driver order at offset 48.
- On the board: the load through sysfs, the ID check and the restart work. A core change with quiesce while a core
  runs: 10 out of 10.

### 5.2 Build and installation (`FLOW=mister`)

    PLATFORM=zybo-z7-20 FLOW=mister make setup build package

- `build`:
  - It makes a copy with patches in `firmware/build/<p>/mister/Main_MiSTer`.
  - It does a cross build with the armhf gcc of Vitis 2025.2 (`MISTER_CROSS_COMPILE`, gcc 13.4, glibc 2.39, 32-bit
    `time_t`).
  - The result needs GLIBC ≤ 2.38 and GLIBCXX ≤ 3.4.32. Ubuntu 24.04 has both.
  - At run time, the result needs the packages `libimlib2t64`, `libfreetype6`, `libpng16-16t64`, `libbz2-1.0`,
    `zlib1g`, `libbluetooth3`.
- `package` makes two outputs:
  - `firmware/build/<p>/mister/rootfs/media/fat` (the FAT partition of the SD card image).
  - `firmware/build/<p>/mister-rootfs.tgz` (the rest). `FLOW=rootfs make build` unpacks it in the RootFS under `/`.

| Path | Content |
|---|---|
| `/media/fat/MiSTer` | Main_MiSTer |
| `/media/fat/MiSTer.ini` | `MiSTer.ini` of Main_MiSTer with `video_mode=0` (720p60) |
| `/media/fat/<folder>/<core>.rbf` | `.bit.bin` of the designs from `MISTER_CORES` `<design>:<core>[:<folder>]`, folder default `_Computer` (Zybo: `MSX.rbf` in `_Computer`, `SNES.rbf`, `PSX.rbf`, `N64.rbf` in `_Console`) |
| `/media/fat/menu.rbf` | menu core (`MISTER_CORES` entry with core `menu`, Zybo: `zybo-z7-20_menu`) |
| `/media/fat/games/<core>/`, `config/` | directories for images (Main mounts `boot.rom`, `boot.vhd` automatically) and settings; the `games.sh` of the core profile fills them, if there is one |
| `/media/fat/games/MSX/boot.vhd` | SD card of the MSX core (below) |
| `/media/fat/games/N64/N64-database.txt` | save types of the N64 games, Main_MiSTer reads it |
| `/usr/local/sbin/ssm2603-init.sh`, `ssm2603.service` | codec init (board files `MISTER_ROOTFS_FILES`, §4) |
| `/etc/systemd/system/mister.service` | starts `/media/fat/MiSTer` as root; `ExitType=cgroup`, because Main restarts itself through a double fork after each core load |
| `/etc/systemd/system/usr-lib-firmware-mister.mount` | tmpfs on `/lib/firmware/mister` (Ubuntu: `/lib` → `/usr/lib`) |

- `FLOW=rootfs make build` unpacks the archive if it exists (`--no-overwrite-dir`). `build-all.sh` calls
  `FLOW=mister` before the RootFS.
- `/media/fat` is the first partition of the SD card (FAT32, label `MISTER`). `/etc/fstab` mounts it with `flush`,
  because the user usually switches off the board without shutdown. `mister.service` waits for it
  (`RequiresMountsFor`). The boot files share the partition. Thus you can copy ROMs, BIOS files and cores there from
  any PC (§5.4).
- The boot design (FSBL, `BOOT_DEFAULT_TOPLEVEL`) is the MSX core. At startup, Main finds a MiSTer design and starts
  the MSX core directly. Main loads `menu.rbf` on a cold reset and when the user leaves a core.
- `MISTER_CORES` of the Zybo packages all cores of the board: menu, MSX, SNES, PSX and N64.
- Menu core without `DDRAM_*`: `mister_zynq` ties the port off (`waitrequest` 0, no read data). The profile has no
  `G_DDRAM`, and the menu core runs on the gated clock of stage C.
  - The background picture (LFSR/cosine pattern) and the OSD work.
  - The framebuffer mode of the menu (Linux console, background pictures from Main) shows nothing.
  - Remember this for a later connection to HP2. The `rtl/ddram.sv` of the menu clears byte by byte from
    0x2000_0000 (`DDRAM_ADDR` = `001` & address). This is the full PL area, with the SDRAM replacement and the scaler
    buffers. It does the same on the DE10-Nano. HP2 must not reach beyond the PL area.
- Host tools for `package`: `unzip`, `sfdisk`, `mkfs.fat`, `mtools` (MSX boot medium).

### 5.3 Boot medium of the MSX core (`cores/msx/games.sh`)

MSX_MiSTer has no ROM loader in the OSD, only "Mount VHD". The OCM/KdL core boots from an SD card (FAT16 with
`OCM-BIOS.DAT`, MSX-DOS2/Nextor). The user starts ROMs inside the MSX from this card with one of two commands:
- `EXECROM` runs the ROM in the RAM mapper.
- `ROMLOAD` needs slot 1 "MegaSCC+" in the OSD.

`games.sh` builds the card of `sdcreate.cmd` (`MSX_MiSTer/Utils/sdcreate.zip`) again, without Windows and without
root. The card has these parts:
- Size 64 MiB (`MSX_VHD_MB`), MBR with one primary FAT16 partition from 1 MiB, label `MSXFAT16`.
- `OCM-BIOS.DAT` is the first file. The script checks that it is at the start of the data area, because the IPL of
  the core reads it there. Then come `MSXDOS2.SYS`, `NEXTOR.SYS`, `COMMAND2.COM`, the remaining OS files, `UTILS\`,
  `MM\`.
- The `*.rom` files from `MISTER_ROMS` (default `roms/`, not in Git) go into the root directory with unique 8.3 names.
  - With exactly one ROM, `AUTOEXEC.BAT` loads it with `romload <name> /r` into the ESE-SCC and resets. The BIOS then
    starts it like a cartridge (test: `roms/Some_Game.rom` → `SOME_GAM.ROM`).
  - With more than one ROM, `boot.vhd` lists them. The script also makes a separate card `<ROM name>.vhd` for each
    ROM. This card contains only this ROM and starts it (selection in the OSD, "Mount *.VHD").
- `config/MSX.CFG` (OSD settings, 16 bytes `cur_status`) has slot 1 = "MegaSCC+ 1MB" (bit 4). Without this setting,
  `ROMLOAD` reports "No Sound-Cartridges detected". The file also has "Reset after Mount" = Yes (bit 14). The script
  keeps an existing file.

Game switching: a reset leaves the ROM from `ROMLOAD` in the RAM of the ESE-SCC. The BIOS then starts it again before
MSX-DOS (HW 2026-10-29). Thus, without a fix, the old game would start after "Mount *.VHD". The fix:
- The patch `cores/msx/patches/0001-scc-rom-hide-after-mount.patch` adds `cores/msx/scc_rom_hide.vhd` into
  `emsx_top`.
- From `img_mounted` on, the header bytes 4000h/4001h/8000h/8001h of slot 1 read FFh. This continues until the first
  write to page 1 of slot 1 after the next reset (`ROMLOAD` sets the bank registers 5000h/7000h).
- The BIOS finds no cartridge, and MSX-DOS boots the new card. Its `AUTOEXEC.BAT` loads and starts the new game.
- Operation: F12 → select card.

Evidence:
- Sim: `scc_rom_hide_tb`, 6 mutation probes.
- Timing: `zybo-z7-20_msx_hdmi` WNS +0.793 ns, WHS +0.018 ns.
- HW 2026-10-29: core start with a game in the SCC → MSX-DOS. A change through three games in sequence with only F12
  and the card selection.

Without the patch, the change worked only through slot 1 = Empty → card → slot 1 = MegaSCC+ → `autoexec`. The cards
still mention this path for the case that `ROMLOAD` finds no SCC. Through the OSD, `romload … /h` (hold GRAPH during
boot) did not change the game reliably.

Main mounts `games/MSX/boot.vhd` itself when the core starts. Sequence on the board (HW):
1. The OCM IPL loads the BIOS.
2. MSX-DOS2 starts.
3. `AUTOEXEC.BAT` loads the game through `ROMLOAD`.
4. A reset occurs.
5. The BIOS starts the game.

`EXECROM` (from MSX-DOS) also starts the test game. But it leaves VRAM 0x2000–0x201F at `F4` (color table of the
SCREEN 1 initialization). The result is green stripes in the upper third of the picture.

DualSense over Bluetooth works through plain evdev (`input.cpp` treats PID 0x0ce6 like a DS4). You pair it once with
`bluetoothctl`, because the pairing scripts of the MiSTer menu are specific to MiSTer.

### 5.4 Root file system and SD card image (`FLOW=rootfs`)

    PLATFORM=zybo-z7-20 FLOW=rootfs make build image

`build` (sudo) makes a minimal Ubuntu 24.04 armhf with `debootstrap --variant=minbase` and a chroot through
`binfmt_misc` + qemu-user (`firmware/common/scripts/create-ubuntu-rootfs.sh`, `build-ubuntu24.04-console-rootfs.sh`).
It contains only what a headless MiSTer board needs:

| Part | Packages, settings |
|---|---|
| base | systemd, udev, kmod, OpenSSH, sudo; `systemd-networkd` (DHCP on `eth0`, not with an NFS root), `systemd-resolved`, `systemd-timesyncd`; locale `C.UTF-8`, time zone UTC, host name `mister-<platform>` |
| kernel | `linux-image-*.deb` of `FLOW=kernel make build` (modules of the same build as `zImage`) |
| MiSTer | runtime libraries of Main_MiSTer (§5.2), BlueZ, the units of `mister-rootfs.tgz` |
| board | `i2c-tools` (codec init), `dosfstools`, `python3` (test tools), `busybox-static` (`make flash`) |
| users | `root` and `fpga` (in `sudo`), password `ROOTFS_PASSWORD` (default `fpga`); `mister`, password `ROOTFS_MISTER_PASSWORD` (default `mister`); root logs in over SSH with a key only |
| first boot | empty `/etc/machine-id`, `ssh-host-keys.service` makes the SSH host keys (no two cards share them) |
| SSH keys | `ssh-authorized-keys.service` copies `/media/fat/linux/authorized_keys` to `/root/.ssh/` at every boot |

`image` (`firmware/common/scripts/make-sd-image.sh`) writes `firmware/build/<p>/fpga-mister-<p>-<version>.img` and
`.img.xz` (+ `.sha256`):

| Partition | Size | Content |
|---|---|---|
| 1, FAT32 `MISTER`, bootable | `SDIMAGE_FAT_MB` (4096) | `BOOT.bin`, `boot.scr`, `uEnv.txt`, `zImage`, board DTB of `FLOW=boot make copy`; `/media/fat` of `FLOW=mister make package` |
| 2, ext4 `rootfs` | contents + 25 % + 512 MiB | the RootFS (`mke2fs -d`) |

The script makes the FAT image without root (`mkfs.vfat`, `mcopy`). It makes the partition table with `sfdisk` on
the image file. For the release, these settings apply:
- `BOOT_NETBOOT=0` makes `uEnv.txt` boot the card at once (no boot menu, no lab addresses).
- `MISTER_ROMS=` keeps local game images out (§5.3).

`write` copies the image to a card in a card reader (`dd`).

`tftpboot` (`FLOW=boot`) serves the kernel and DTB from `/srv/tftp/mister-<platform>`. It exports a copy of the
RootFS over NFS (`nfs-rootfs`). It makes this copy once, because a booted root writes SSH host keys and `machine-id`.
These must not get into the tree from which the script makes the image.

`tftpboot` prints the U-Boot commands of a network boot. These commands need nothing of the card except U-Boot
itself. Thus they also work on a release image and when the RootFS of the card is broken. With `BOOT_NETBOOT=1`, the
boot menu of `uEnv.txt` gives the same.

After each copy, `NFS_ROOT_SETUP` of the profile (`firmware/common/mister/scripts/nfs-rootfs.sh`, as root) makes it a
MiSTer root that needs no file of the card:
- `/media/fat` is a directory of the NFS root (the fstab line of the card is removed). It has the package of
  `FLOW=mister`: the script replaces the core folders, keeps other files and keeps a newer `config/` file.
- The NFS root gets the modules of the TFTP kernel.
- The NFS root gets the host name.
- `NFS_ROOT_DATA=<dir>` adds user files and overwrites no file.

The ZCU106 takes the armhf RootFS of the Zybo in this way (`firmware/targets/zcu106/README.md`).

`flash` (`firmware/common/scripts/flash-sd-over-network.sh`) writes the card in the board again over Ethernet. It is
for a board without a monitor or physical access. It refuses a board whose `/` is not NFS. The reason: a kernel with
its root on the card continues to write to the card while the card is overwritten, also with `/` frozen. That left
the superblock and journal blocks of the old file system on the new one. Then the card did not boot
(`ext4_check_descriptors: Checksum for group 0 failed`).

The write has these steps:
1. The script stops Main_MiSTer and unmounts the partitions of the card.
2. A script in `/dev/shm` runs on a static busybox and receives the image (TCP 5555).
3. It writes `/dev/mmcblk0` (`dd conv=fsync`) and drops the page cache.
4. It reads the card back with `dd`. Then it gives a report (TCP 5556): the end of the `dd` log and an MD5 for each
   64 MiB chunk.
5. If each chunk agrees with the image, the host sends the restart command (TCP 5557, `reboot -f -n`). If not, the
   host lists the chunks that differ (offset, partition). The board then waits for `reboot` or `abort` on that port.

The board gets a new DHCP lease and new SSH host keys. If the router registers DHCP names, you can reach the board
under its host name `mister-<platform>`. Before the write, `SSH_KEYS` (default `~/.ssh/id_ed25519.pub`) goes to
`/linux/authorized_keys` of the new FAT partition. Thus the root login with a key stays after the write. After an
interrupted transfer, the board still runs from NFS, and you can do the write again.

## 6. Clocks (Zybo, from FCLK0 = 100 MHz)

Block design `zybo-z7-20_msx`. The values come from the dividers of the Clocking Wizards (output of `make create`):

| Clock | Source | Value | Users |
|---|---|---|---|
| FCLK0 | PS | 100 MHz | AXI-Lite (GP0), HP1 (`ascal` framebuffer, `avl_clk`), `sysmem` clock of `sys_top` |
| Master clock | MMCM `clk_core` `clk_out2` (BUFG) and `clk_out4` (without BUFG, same divider) | 90.0 MHz (profile value) | `clk_out2`: stage C, HP0; `clk_out4` → BUFGCE `core_buf`: the core (MSX `clk_mem`, on average 85.909 MHz with pacer 21/22) |
| MSX `clk_sys` | BUFGCE in the replacement `pll` | every 4th pulse, on average 21.477 MHz | core, `hps_io`, `hps_bus_axi` |
| 50 MHz | MMCM `clk_core` | 50.0 MHz | `FPGA_CLK1/2/3_50` (framework: `pll_hdmi_adj`, buttons, …) |
| Audio | MMCM `clk_core` (CLKOUT0 fractional) | 24.5734 MHz (−110 ppm relative to 24.576) | `audio_out`, I2S MCLK |
| Pixel clock / TMDS 5× | MMCM `clk_hdmi` | 74.25 / 371.25 MHz | HDMI side of `sys_top`/`ascal`, `rgb2dvi` or `hdmi_out` (external serial clock) |
| Pixel clock / TMDS 5× with direct video | PLLE2 `video_pll` in `mister_zynq` from the `CLK_VIDEO` of the core | N64 48.68 / 243.4 MHz | `rgb2dvi` or `hdmi_out` (`G_DIRECT_VIDEO` 1, `clk_hdmi` without load) |

The pixel clock is fixed (1280×720@60). `sys_top` reconfigures the HDMI PLL as the video mode requires. On the Zynq,
`mister_zynq` only acknowledges this, without effect. Thus `MiSTer.ini` needs `video_mode=0` (720p60) until a
reconfigurable pixel clock is available (Clocking Wizard with DRP).

## 7. Top level and block design

**`sys_top.v` remains the MiSTer top.** It contains the system commands, OSD, scandoubler, `ascal`, `audio_out` and
the HPS bus logic. We do not develop any of these again. `prepare_sources.py` writes `sys/sys_top_zynq.sv` (module
`sys_top_zynq`). In this file, 11 Cyclone V hard blocks and Quartus PLLs become ports `ZYNQ_<instance>_<port>` (Code,
generator output, values below from the code of `sys_top.v`):
- `h2f_gp`, `uart`, `interrupts`, `spi`: HPS parts.
- `sysmem`: Avalon ports `ram1`/`ram2`/`vbuf`, resets, clock.
- `pll_hdmi`, `pll_cfg_hdmi`, `pll_audio`: PLL and reconfiguration.
- `hdmi_i2c`, `hdmi_clk_sw`, `vga_clk_sw`.

There are two more changes:
- The core gets `CLK_50M` from `ZYNQ_CLK_CORE` (gated master clock). `ZYNQ_CLK_SYS` outputs its `clk_sys`.
- `ascal` runs with `N_DW` 64 and `N_AW` 29. Thus its Avalon port fits directly onto a 64-bit HP port.

**`mister_zynq`** (VHDL, `hdl/`, board- and core-neutral) is the module reference in the block design. It connects
the ports:

| Ports of `sys_top_zynq` | Connection |
|---|---|
| `h2f_gp` (GPO/GPI) | `hps_bus_axi` (`G_RAW`) on `s_axi` |
| `SDRAM_*` | stage C: `core_clock_stall` + BUFGCE → `ZYNQ_CLK_CORE`, `sdram_emu`, `sdram_region` (b0 → `sdram_bram`, b1 → `sdram_cache`), `avl_axi_bridge` → `m_axi_sdram`. With `G_FREE_CLK` = 1: `ZYNQ_CLK_CORE` = `clk_master`, `SDRAM_*` open, `m_axi_sdram` quiet |
| `sysmem` `vbuf` | `avl_axi_bridge` on `clk_100` → `m_axi_vbuf` |
| `ZYNQ_coremem_*` (Avalon master of a replaced SDRAM controller, stage D) | only with `G_COREMEM` = 1: `avl_axi_bridge` on `ZYNQ_coremem_clk` → `m_axi_coremem` (HP3, clock `coremem_clk`), byte address `G_SDRAM_BASE` + word · 8; quiesce, reset, idle, errors as for `ram1` |
| `sysmem` `ram1` (`DDRAM_*`) | only with `G_DDRAM` = 1: `avl_axi_bridge` on the `DDRAM_CLK` of the core → `m_axi_ddram`; output `ddram_clk` clocks HP2. Quiesce and reset synchronized into this domain, idle and errors back to `clk_100`. Only for a free-running `DDRAM_CLK` (stage D) |
| `sysmem` reset/clock | `reset_out` = PL reset OR `reset_core_req` (as in `sysmem.sv:45`), clock `clk_100` |
| `pll_hdmi`, both clock switches | `clk_hdmi` |
| `pll_cfg_hdmi` | `waitrequest` pulses for one cycle after each write (`sys_top` waits for the falling edge) |
| `pll_audio` | `clk_audio` |
| `HDMI_TX_*` | `vid_*` for `rgb2dvi`/`hdmi_out` in the order of `rgb2dvi` R, B, G |
| `ZYNQ_CLK_HDMI_TX` (clock of `HDMI_TX_*`) | only with `G_DIRECT_VIDEO` = 1: `video_pll` → `vid_clk`, `vid_clk_ser`, `vid_locked` (direct video, §4) |
| `HDMI_MCLK/SCLK/LRCLK/I2S` | I2S to the codec (and to `hdmi_out`) |
| `KEY`, `LED`, `SW` | board (KEY active low) |
| not connected | `ram1` without `G_DDRAM` (its clock is a core clock and is gated in stage C, CDC open), `ram2` (ALSA, palette), UART, SPI, HDMI I2C, interrupts, VGA, IO board, SD SPI |

The generics (SDRAM geometry, BRAM region, cache, pacer, `G_SDRAM_BASE` 0x3800_0000) come from the core profile.
An error flag (`status_err`) combines the sticky errors of stage C and of the bridges (HP0–HP3).

**Block design:** `firmware/targets/zybo-z7-20/scripts/2025.2/zybo-z7-20_mister.tcl` (board part) makes it together
with `scripts/mister_project.tcl` (core part). It makes each MiSTer design of the board. `FLOW=vivado` gives the core
and the video output as Tcl arguments: `CORE=<core> VIDEO=dvi|hdmi`, or from the name
`TOPLEVEL=zybo-z7-20_<core>[_hdmi]`. The Vivado project has the name `zybo-z7-20_<core>[_hdmi]`. No core has its own
wrapper.
- PS7 from the board preset: FCLK0, GP0, HP0/HP1 64 bit, I2C0 through EMIO for the codec.
  - If the profile sets `G_DDRAM` 1, the PS7 also has HP2 with 64 bit (`mister_ddram`).
  - With `G_COREMEM` 1, the PS7 also has HP3 with 64 bit (`mister_coremem`).
- Two Clocking Wizards (§6).
- `proc_sys_reset` on FCLK0 (`dcm_locked` = core MMCM).
- SmartConnect GP0 → `s_axi`.
- `m_axi_sdram` → HP0, `m_axi_vbuf` → HP1. Where applicable, also `m_axi_ddram` → HP2 (clock `ddram_clk`) and
  `m_axi_coremem` → HP3 (clock `coremem_clk`). All connect directly (AXI3, 64 bit, ID 6).
- `rgb2dvi` 1.4 with external serial clock.
- I2S and `ac_muten` = 1 to the SSM2603.
- Buttons BTN0 = OSD, BTN1 = user. `SW` is fixed to 0 (`SW[3]` would select the buttons of the IO board).
- LEDs 0–2 = DE10 LED 0/2/4 (user, disk, power), LED 3 = `status_err`.

**Constraints:** `cores/<core>/core.xdc` comes first, so that its derived clocks go into the groups of the board XDC.
The board XDC is `firmware/targets/zybo-z7-20/constraints/zybo-z7-20_mister.xdc`. It has the pins and
`set_clock_groups -asynchronous` over the clock inputs of `mister_zynq`. This agrees with `sys_top.sdc`, where all PLL
groups are `exclusive`. The framework synchronizes between them itself. Gated and derived core clocks stay
synchronous to the master clock: stage C talks to the core clock-synchronously.

**Status:**

| Level | Result |
|---|---|
| Sim | `mister_zynq_tb` with a stub for `sys_top_zynq`: wiring, stage C, bridges, HPS bus |
| Synth | `make create` makes the Vivado project |
| Timing after route | `build` delivers a bitstream with met constraints |
| HW | on the Zybo Z7-20 for the menu, MSX, SNES, PSX and N64 profiles; results for each core in `firmware/common/mister/cores/<core>/STATUS.md` |
