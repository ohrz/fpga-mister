# firmware/common/mister – the board-neutral MiSTer port

Everything here is shared by every board and every core. It is glue around the unmodified MiSTer framework and
cores (authors: `README.md`, section "Credits"), not a replacement for them. Board files live in
`firmware/targets/<platform>/`, upstream sources in `_Checkouts/` (pinned in
`firmware/common/checkouts.txt`, never edited). The HDMI transmitter with sound (`hdmi_out`) is the
separate component `firmware/common/ip/hdmi-tx`. How to port a further core: `doc/PORTING.md`;
how the parts work: `doc/ARCHITECTURE.md`.

## Layout

    hdl/                    own VHDL (VHDL-93 for Vivado), board- and core-neutral
      mister_zynq.vhd         module reference of the block design: sys_top_zynq + Zynq parts
      hps_bus_axi.vhd         HPS GPO/GPI bus of Main_MiSTer on AXI-Lite (GP0)
      sdram_emu.vhd           SDRAM pin emulator (stage C) ...
      sdram_region.vhd          ... region decoder: BRAM or DDR
      sdram_bram.vhd            ... BRAM backend
      sdram_cache.vhd           ... cache in front of the DDR
      avl_axi_bridge.vhd      Avalon-MM -> AXI3 HP port (SDRAM image, ascal frame buffer, DDRAM)
      core_clock_stall.vhd    BUFGCE enables and pacer of the gated core master clock
      clk_pulse_div.vhd       derived core clock (every Nth master pulse) and its mid clock for
                              falling-edge logic (used by the pll.vhd of a profile)
      perf_counters.vhd       stage C event counters (tools/perf.py)
      audio_i2s_simple.vhd    core audio straight to I2S instead of audio_out (MISTER_ZYNQ_SIMPLE_AUDIO)
      video_pll.vhd           pixel and serial clock from the core's CLK_VIDEO (direct video)
      pll_reset.vhd           reset sequencer of PLLs/MMCMs whose input starts late
      intel/                  replacements of Intel megafunctions, same name, generics and ports
        altsyncram.vhd          subset used by MiSTer (asserts on anything else)
        altdpram.vhd, lpm_mult.vhd, altddio_out.vhd
    cores/<core>/           core profile, one directory per core (see below)
      _template/              copy this for a new core
    patches/Main_MiSTer/    patches of Main_MiSTer (a core's patches are in cores/<core>/patches/)
    scripts/
      core_survey.py          step 1 of a port: what a core needs from Quartus (report)
      prepare_sources.py      copy of a checkout made readable for Vivado (rules, sys_top_zynq.sv, patches)
      mister_project.tcl      mister_core_add: profile + prepared sources into a Vivado project
      qip.tcl                 file lists of Quartus .qip files
      synth_core_ooc.tcl      out-of-context synthesis of a core or a part of it
      status.py               STATUS.md tables: check, matrix (make status, make status-update)
      build_matrix.py         build every board x core design, timing rows (make build-matrix)
      impl_at_clock.tcl       implementation of a built design at other core MMCM rates (diagnosis)
      timing_groups.py        failing paths of impl_at_clock.tcl grouped by module
    tb/                     GHDL testbenches of hdl/ (make -C tb, part of make test)
    tools/                  scripts for the board (fps.py, perf.py, vkbd.py, vpad.py, grab_frame.sh,
                            n64speed.py, pair-ds5.sh) and
                            hwtest.py (host: make hwtest CORE=<core>, reads cores/<core>/hwtest.cfg)
    files/rootfs/           systemd units of Main_MiSTer for the rootfs

## Core profile `cores/<core>/`

| File | Required | Content |
|---|---|---|
| `core.tcl` | yes | `core_name` (checkout), `core_exclude`, `core_add`, `core_xdc`, `core_master_mhz`, `core_defines`, `core_generics` (generics of `mister_zynq`); optional `core_vhdl_std 2008`, `core_expect_bram` |
| `rules.py` | if needed | Vivado source rules with expected counts (`RULES`, helpers from `RULE_API` of `prepare_sources.py`) |
| `pll.vhd` | usually | replacement of the core's Quartus PLL (same entity name and ports) |
| `core.xdc` | with derived clocks | `create_generated_clock` per derived clock of `pll.vhd` |
| other `.vhd` | if needed | further replacement files (same module name and ports as the excluded original) |
| `games.sh` | optional | builds the start medium of the core for `FLOW=mister make package` |
| `README.md` | yes | entry point: build, test, files, decisions, gaps |
| `patches/` | if needed | patches of the core's checkout (`NNNN-<topic>.patch`, applied in sorted order) |
| `STATUS.md` | yes | evidence per board and stage (`make status`, checked by `make test`) |
| `hwtest.cfg` | once on the card | game, input and nominal values of `make hwtest CORE=<core>` |

`make test` (step 7) checks every profile except `_template`: the files `core.tcl` names exist and
`prepare_sources.py` with the profile's `rules.py` passes on the pinned checkout.

## How a change to upstream code is made (in this order of preference)

1. **Nothing**: a replacement in `hdl/intel/` or the stage C chain covers it (no core change).
2. **Replacement file** in the profile (`core_exclude` + `core_add`): a whole module with the same
   name and ports (PLL, lcell ring, SDRAM controller in stage D).
3. **Rule** in `cores/<core>/rules.py`: a mechanical, countable source fix for a Quartus/Vivado
   difference (syntax, scope, port kind). Every rule has its expected count.
4. **Patch** in `cores/<core>/patches/NNNN-<topic>.patch` (Main_MiSTer: `patches/Main_MiSTer/`): a change of behaviour (Main_MiSTer Zynq
   backend, MSX_MiSTer game change). New logic goes into an own VHDL file of the profile with a
   testbench (`cores/msx/scc_rom_hide.vhd`, `tb/scc_rom_hide_tb.vhd`); the patch only wires it. Header lines before the diff: Title, Project (with the pin it applies to), Author,
   Company, Created, Description (why). The patches of a checkout apply in order to its pin
   (`make test` step 5); with a new pin, rebase them and update the Project line.

Rules for `sys/` (the framework copy in every core) are in `prepare_sources.py` (`SYS_RULES`,
`ZYNQ_HOIST`, `ZYNQ_LITERALS`): they hold for every core whose `sys/` matches the pinned
Template_MiSTer closely enough; an exact-text rule that does not match stops the build.

## Conventions

- Own HDL in VHDL, VHDL-93 compatible (`make -C tb vhdl93`); file header with Company OHRZ and
  Author `mr_pleasant@gmx.de`; English comments.
- Every testbench ends with `PASS` and has mutation probes (copies in a scratch directory, never in
  the repository).
- Evidence levels stay apart in the documentation: simulation, synthesis/timing, hardware.
