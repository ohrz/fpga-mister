-------------------------------------------------------------------------------
-- Title      : MiSTer framework and core on the Zynq (top of the PL part)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : mister_zynq.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Module reference of the block design: sys_top_zynq (sys_top.v of the
--   core's sys/ with the Cyclone V hard blocks as ports ZYNQ_*, made by
--   prepare_sources.py) with the core inside, connected to the Zynq parts
--   (doc/ARCHITECTURE.md §2-§4):
--     HPS GPO/GPI     hps_bus_axi (register-only mode) on s_axi (M_AXI_GP0)
--     SDRAM pins      stage C: core_clock_stall (BUFGCE of the core master
--                     clock), sdram_emu, sdram_region (b0 -> sdram_bram,
--                     b1 -> sdram_cache), avl_axi_bridge -> m_axi_sdram (HP0);
--                     G_FREE_CLK = 1: none of it, the core gets clk_master
--                     itself (its PLL replacement may put an MMCM on it),
--                     SDRAM_DQ is not driven, m_axi_sdram is idle, the perf
--                     counters see an edge every cycle
--     sysmem vbuf     ascal frame buffer: avl_axi_bridge -> m_axi_vbuf (HP1)
--     sysmem ram1     G_DDRAM = 1: DDRAM_* of the core: avl_axi_bridge on the
--                     core's DDRAM_CLK -> m_axi_ddram (HP2, its ACLK = ddram_clk);
--                     only for cores whose DDRAM_CLK runs free (stage D: the
--                     core waits on its memories, no gated clock), physical
--                     addresses as on the DE10-Nano (0x2000_0000-0x3FFF_FFFF)
--     COREMEM         G_COREMEM = 1: memory port of a core whose SDRAM controller
--                     is replaced (ZYNQ_coremem_*, stage D): avl_axi_bridge on its
--                     clock -> m_axi_coremem (HP3, ACLK = coremem_clk), byte
--                     address G_SDRAM_BASE + word * 8
--     perf            stage C event counters over windows of 2**G_PERF_WIN_LOG2
--                     master cycles, read as aux words of hps_bus_axi from
--                     0x10: seq, cycles, core edges, stall, pacer wait, bucket
--                     full, read misses, reads (ev_hit: every read once), miss
--                     cycles, drain cycles, write FIFO full, writes, reads in
--                     the upper half, misses there, misses on the replaced
--                     line, ... replaced from the other half, misses on the
--                     next line (sdram_cache)
--     quiesce         CTRL bit 0 of hps_bus_axi holds the HP bridges (no new
--                     command); STATUS bit 2 = all have closed every AXI
--                     transaction: Main_MiSTer waits for it before it
--                     reconfigures the PL.  The core stalls on its
--                     next SDRAM access meanwhile.
--     sysmem reset    reset_out = PL reset or core reset request (as sysmem)
--     sysmem clock    clk_100
--     PLLs            clocks of the block design: clk_hdmi (pixel clock of
--                     the fixed HDMI mode, both clock selects), clk_audio
--     PLL reconfig    not possible: the write is accepted, waitrequest
--                     pulses once as after a reconfiguration
--     HDMI TX         vid_* on clk_hdmi to rgb2dvi or hdmi_out (RBG order of
--                     rgb2dvi); G_DIRECT_VIDEO = 1 (sys_top without ascal,
--                     MISTER_DEBUG_NOHDMI): vid_* on the core's video clock
--                     (ZYNQ_CLK_HDMI_TX), video_pll makes vid_clk (= it) and
--                     vid_clk_ser (5x) for the transmitter, clk_hdmi is unused
--     audio           I2S of audio_out (MCLK = clk_audio)
--   Not connected yet (tied off): sysmem ram1 with G_DDRAM = 0 (the read data
--   stay 0, waitrequest 0), ram2 (ALSA, LFB palette), UART, ALSA
--   SPI, HDMI I2C, interrupts, IO board, VGA, SD card SPI.
--   Clocks: clk_100 (FCLK0: AXI-Lite, ascal memory side, sysmem clock),
--   clk_50 (FPGA_CLK1/2/3_50: framework), clk_master (the core master clock:
--   stage C and HP0; with G_FREE_CLK = 1 the core's clock), clk_master_gate
--   (unused with G_FREE_CLK = 1; the same MMCM frequency and phase on an
--   output without BUFG: input of the BUFGCE core_buf, so the core clocks
--   derived from it in the core profile form a BUFG cascade one stage shorter;
--   the placer cascades BUFGs only through adjacent sites, Place 30-120),
--   clk_hdmi, clk_audio.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity mister_zynq is
  generic (
    -- SDRAM of the core (core profile)
    G_SD_BANK_BITS   : natural := 2;
    G_SD_ROW_BITS    : natural := 13;
    G_SD_COL_BITS    : natural := 9;
    G_SD_RD_ADJ      : integer := 0;
    -- region b0 -> BRAM (sdram_region), the rest -> cache -> DDR;
    -- G_B0_BITS = 0: no region, every access goes through the cache
    G_B0_MASK        : natural := 0;
    G_B0_MATCH       : natural := 0;
    G_B0_SEL         : natural := 16#FFFF#;
    G_B0_BITS        : natural := 16;
    -- cache and DDR window of the SDRAM image; G_CACHE_COL_HIGH = 1: cache and DDR word address
    -- bank & col & row instead of bank & row & col (cores that put the low address bits on the row)
    G_CACHE_COL_HIGH   : natural := 0;
    G_CACHE_LINE_LOG2  : natural := 2;
    G_CACHE_INDEX_BITS : natural := 9;
    -- G_CACHE_SPLIT = 1: top address bit (bank MSB) = top cache index bit, each half of the
    -- SDRAM image gets half of the cache lines (SNES: ROM / WRAM ports)
    G_CACHE_SPLIT      : natural := 0;
    G_SDRAM_BASE     : std_logic_vector(31 downto 0) := x"38000000";
    -- core clock pacer: G_PACE_NUM / G_PACE_DEN of clk_master on average
    G_PACE_NUM       : positive := 1;
    G_PACE_DEN       : positive := 1;
    G_PACE_BUCKET    : positive := 64;
    -- second ratio while the core sets ZYNQ_PACE_ALT (macro MISTER_ZYNQ_PACE_ALT, e.g. SNES PAL);
    -- 0: the same as G_PACE_NUM / G_PACE_DEN
    G_PACE_NUM_ALT   : natural := 0;
    G_PACE_DEN_ALT   : natural := 0;
    -- stage C event counters (perf_counters), window 2**G_PERF_WIN_LOG2 master cycles
    G_PERF_WIN_LOG2  : positive := 27;
    -- GPI snapshot wait (hps_bus_axi register-only mode: 4)
    G_RD_WAIT        : natural := 4;
    -- DDRAM_* of the core on m_axi_ddram (HP2): 1 only with a free-running DDRAM_CLK (stage D)
    G_DDRAM          : natural := 0;
    -- 1: the core runs on the free clk_master (no pacer, no BUFGCE), stage C and HP0 are off and
    -- SDRAM_* is left open (cores whose memories wait by handshake: stage D)
    G_FREE_CLK       : natural := 0;
    -- memory port of a core that replaces its SDRAM controller (ZYNQ_coremem_*, macro
    -- MISTER_ZYNQ_COREMEM): avl_axi_bridge on its clock -> m_axi_coremem (HP3), byte address
    -- G_SDRAM_BASE + word * 8
    G_COREMEM        : natural := 0;
    -- 1: direct video (macro MISTER_DEBUG_NOHDMI): vid_* on the core's video clock, video_pll
    -- (period G_DV_CLKIN_PS, VCO = video clock * G_DV_MULT) -> vid_clk, vid_clk_ser, vid_locked
    G_DIRECT_VIDEO   : natural := 0;
    G_DV_CLKIN_PS    : positive := 20542;
    G_DV_MULT        : positive := 20;
    G_DV_RST_CYCLES  : positive := 65536        -- video_pll reset (clk_50 cycles; shorter in simulation)
  );
  port (
    clk_100       : in  std_logic;
    aresetn       : in  std_logic;       -- clk_100 domain, synchronous
    clk_50        : in  std_logic;
    clk_master    : in  std_logic;
    clk_master_gate : in  std_logic;     -- clk_master without BUFG (same MMCM divider)
    clk_hdmi      : in  std_logic;
    clk_audio     : in  std_logic;

    -- AXI4-Lite slave: GPO/GPI (clk_100)
    s_axi_awaddr  : in  std_logic_vector(6 downto 0);
    s_axi_awprot  : in  std_logic_vector(2 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_araddr  : in  std_logic_vector(6 downto 0);
    s_axi_arprot  : in  std_logic_vector(2 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;

    -- AXI3 master: SDRAM image (clk_master, HP0)
    m_axi_sdram_awid    : out std_logic_vector(5 downto 0);
    m_axi_sdram_awaddr  : out std_logic_vector(31 downto 0);
    m_axi_sdram_awlen   : out std_logic_vector(3 downto 0);
    m_axi_sdram_awsize  : out std_logic_vector(2 downto 0);
    m_axi_sdram_awburst : out std_logic_vector(1 downto 0);
    m_axi_sdram_awlock  : out std_logic_vector(1 downto 0);
    m_axi_sdram_awcache : out std_logic_vector(3 downto 0);
    m_axi_sdram_awprot  : out std_logic_vector(2 downto 0);
    m_axi_sdram_awqos   : out std_logic_vector(3 downto 0);
    m_axi_sdram_awvalid : out std_logic;
    m_axi_sdram_awready : in  std_logic;
    m_axi_sdram_wid     : out std_logic_vector(5 downto 0);
    m_axi_sdram_wdata   : out std_logic_vector(63 downto 0);
    m_axi_sdram_wstrb   : out std_logic_vector(7 downto 0);
    m_axi_sdram_wlast   : out std_logic;
    m_axi_sdram_wvalid  : out std_logic;
    m_axi_sdram_wready  : in  std_logic;
    m_axi_sdram_bid     : in  std_logic_vector(5 downto 0);
    m_axi_sdram_bresp   : in  std_logic_vector(1 downto 0);
    m_axi_sdram_bvalid  : in  std_logic;
    m_axi_sdram_bready  : out std_logic;
    m_axi_sdram_arid    : out std_logic_vector(5 downto 0);
    m_axi_sdram_araddr  : out std_logic_vector(31 downto 0);
    m_axi_sdram_arlen   : out std_logic_vector(3 downto 0);
    m_axi_sdram_arsize  : out std_logic_vector(2 downto 0);
    m_axi_sdram_arburst : out std_logic_vector(1 downto 0);
    m_axi_sdram_arlock  : out std_logic_vector(1 downto 0);
    m_axi_sdram_arcache : out std_logic_vector(3 downto 0);
    m_axi_sdram_arprot  : out std_logic_vector(2 downto 0);
    m_axi_sdram_arqos   : out std_logic_vector(3 downto 0);
    m_axi_sdram_arvalid : out std_logic;
    m_axi_sdram_arready : in  std_logic;
    m_axi_sdram_rid     : in  std_logic_vector(5 downto 0);
    m_axi_sdram_rdata   : in  std_logic_vector(63 downto 0);
    m_axi_sdram_rresp   : in  std_logic_vector(1 downto 0);
    m_axi_sdram_rlast   : in  std_logic;
    m_axi_sdram_rvalid  : in  std_logic;
    m_axi_sdram_rready  : out std_logic;

    -- AXI3 master: ascal frame buffer (clk_100, HP1)
    m_axi_vbuf_awid    : out std_logic_vector(5 downto 0);
    m_axi_vbuf_awaddr  : out std_logic_vector(31 downto 0);
    m_axi_vbuf_awlen   : out std_logic_vector(3 downto 0);
    m_axi_vbuf_awsize  : out std_logic_vector(2 downto 0);
    m_axi_vbuf_awburst : out std_logic_vector(1 downto 0);
    m_axi_vbuf_awlock  : out std_logic_vector(1 downto 0);
    m_axi_vbuf_awcache : out std_logic_vector(3 downto 0);
    m_axi_vbuf_awprot  : out std_logic_vector(2 downto 0);
    m_axi_vbuf_awqos   : out std_logic_vector(3 downto 0);
    m_axi_vbuf_awvalid : out std_logic;
    m_axi_vbuf_awready : in  std_logic;
    m_axi_vbuf_wid     : out std_logic_vector(5 downto 0);
    m_axi_vbuf_wdata   : out std_logic_vector(63 downto 0);
    m_axi_vbuf_wstrb   : out std_logic_vector(7 downto 0);
    m_axi_vbuf_wlast   : out std_logic;
    m_axi_vbuf_wvalid  : out std_logic;
    m_axi_vbuf_wready  : in  std_logic;
    m_axi_vbuf_bid     : in  std_logic_vector(5 downto 0);
    m_axi_vbuf_bresp   : in  std_logic_vector(1 downto 0);
    m_axi_vbuf_bvalid  : in  std_logic;
    m_axi_vbuf_bready  : out std_logic;
    m_axi_vbuf_arid    : out std_logic_vector(5 downto 0);
    m_axi_vbuf_araddr  : out std_logic_vector(31 downto 0);
    m_axi_vbuf_arlen   : out std_logic_vector(3 downto 0);
    m_axi_vbuf_arsize  : out std_logic_vector(2 downto 0);
    m_axi_vbuf_arburst : out std_logic_vector(1 downto 0);
    m_axi_vbuf_arlock  : out std_logic_vector(1 downto 0);
    m_axi_vbuf_arcache : out std_logic_vector(3 downto 0);
    m_axi_vbuf_arprot  : out std_logic_vector(2 downto 0);
    m_axi_vbuf_arqos   : out std_logic_vector(3 downto 0);
    m_axi_vbuf_arvalid : out std_logic;
    m_axi_vbuf_arready : in  std_logic;
    m_axi_vbuf_rid     : in  std_logic_vector(5 downto 0);
    m_axi_vbuf_rdata   : in  std_logic_vector(63 downto 0);
    m_axi_vbuf_rresp   : in  std_logic_vector(1 downto 0);
    m_axi_vbuf_rlast   : in  std_logic;
    m_axi_vbuf_rvalid  : in  std_logic;
    m_axi_vbuf_rready  : out std_logic;

    -- AXI3 master: DDRAM_* of the core (ddram_clk = the core's DDRAM_CLK, HP2), G_DDRAM = 1
    ddram_clk          : out std_logic;
    m_axi_ddram_awid    : out std_logic_vector(5 downto 0);
    m_axi_ddram_awaddr  : out std_logic_vector(31 downto 0);
    m_axi_ddram_awlen   : out std_logic_vector(3 downto 0);
    m_axi_ddram_awsize  : out std_logic_vector(2 downto 0);
    m_axi_ddram_awburst : out std_logic_vector(1 downto 0);
    m_axi_ddram_awlock  : out std_logic_vector(1 downto 0);
    m_axi_ddram_awcache : out std_logic_vector(3 downto 0);
    m_axi_ddram_awprot  : out std_logic_vector(2 downto 0);
    m_axi_ddram_awqos   : out std_logic_vector(3 downto 0);
    m_axi_ddram_awvalid : out std_logic;
    m_axi_ddram_awready : in  std_logic;
    m_axi_ddram_wid     : out std_logic_vector(5 downto 0);
    m_axi_ddram_wdata   : out std_logic_vector(63 downto 0);
    m_axi_ddram_wstrb   : out std_logic_vector(7 downto 0);
    m_axi_ddram_wlast   : out std_logic;
    m_axi_ddram_wvalid  : out std_logic;
    m_axi_ddram_wready  : in  std_logic;
    m_axi_ddram_bid     : in  std_logic_vector(5 downto 0);
    m_axi_ddram_bresp   : in  std_logic_vector(1 downto 0);
    m_axi_ddram_bvalid  : in  std_logic;
    m_axi_ddram_bready  : out std_logic;
    m_axi_ddram_arid    : out std_logic_vector(5 downto 0);
    m_axi_ddram_araddr  : out std_logic_vector(31 downto 0);
    m_axi_ddram_arlen   : out std_logic_vector(3 downto 0);
    m_axi_ddram_arsize  : out std_logic_vector(2 downto 0);
    m_axi_ddram_arburst : out std_logic_vector(1 downto 0);
    m_axi_ddram_arlock  : out std_logic_vector(1 downto 0);
    m_axi_ddram_arcache : out std_logic_vector(3 downto 0);
    m_axi_ddram_arprot  : out std_logic_vector(2 downto 0);
    m_axi_ddram_arqos   : out std_logic_vector(3 downto 0);
    m_axi_ddram_arvalid : out std_logic;
    m_axi_ddram_arready : in  std_logic;
    m_axi_ddram_rid     : in  std_logic_vector(5 downto 0);
    m_axi_ddram_rdata   : in  std_logic_vector(63 downto 0);
    m_axi_ddram_rresp   : in  std_logic_vector(1 downto 0);
    m_axi_ddram_rlast   : in  std_logic;
    m_axi_ddram_rvalid  : in  std_logic;
    m_axi_ddram_rready  : out std_logic;

    -- AXI3 master: memory port of the core (coremem_clk = its clock, HP3), G_COREMEM = 1
    coremem_clk        : out std_logic;
    m_axi_coremem_awid  : out std_logic_vector(5 downto 0);
    m_axi_coremem_awaddr : out std_logic_vector(31 downto 0);
    m_axi_coremem_awlen : out std_logic_vector(3 downto 0);
    m_axi_coremem_awsize : out std_logic_vector(2 downto 0);
    m_axi_coremem_awburst : out std_logic_vector(1 downto 0);
    m_axi_coremem_awlock : out std_logic_vector(1 downto 0);
    m_axi_coremem_awcache : out std_logic_vector(3 downto 0);
    m_axi_coremem_awprot : out std_logic_vector(2 downto 0);
    m_axi_coremem_awqos : out std_logic_vector(3 downto 0);
    m_axi_coremem_awvalid : out std_logic;
    m_axi_coremem_awready : in  std_logic;
    m_axi_coremem_wid   : out std_logic_vector(5 downto 0);
    m_axi_coremem_wdata : out std_logic_vector(63 downto 0);
    m_axi_coremem_wstrb : out std_logic_vector(7 downto 0);
    m_axi_coremem_wlast : out std_logic;
    m_axi_coremem_wvalid : out std_logic;
    m_axi_coremem_wready : in  std_logic;
    m_axi_coremem_bid   : in  std_logic_vector(5 downto 0);
    m_axi_coremem_bresp : in  std_logic_vector(1 downto 0);
    m_axi_coremem_bvalid : in  std_logic;
    m_axi_coremem_bready : out std_logic;
    m_axi_coremem_arid  : out std_logic_vector(5 downto 0);
    m_axi_coremem_araddr : out std_logic_vector(31 downto 0);
    m_axi_coremem_arlen : out std_logic_vector(3 downto 0);
    m_axi_coremem_arsize : out std_logic_vector(2 downto 0);
    m_axi_coremem_arburst : out std_logic_vector(1 downto 0);
    m_axi_coremem_arlock : out std_logic_vector(1 downto 0);
    m_axi_coremem_arcache : out std_logic_vector(3 downto 0);
    m_axi_coremem_arprot : out std_logic_vector(2 downto 0);
    m_axi_coremem_arqos : out std_logic_vector(3 downto 0);
    m_axi_coremem_arvalid : out std_logic;
    m_axi_coremem_arready : in  std_logic;
    m_axi_coremem_rid   : in  std_logic_vector(5 downto 0);
    m_axi_coremem_rdata : in  std_logic_vector(63 downto 0);
    m_axi_coremem_rresp : in  std_logic_vector(1 downto 0);
    m_axi_coremem_rlast : in  std_logic;
    m_axi_coremem_rvalid : in  std_logic;
    m_axi_coremem_rready : out std_logic;

    -- video to rgb2dvi (clk_hdmi; G_DIRECT_VIDEO = 1: vid_clk): R & B & G
    vid_data      : out std_logic_vector(23 downto 0);
    vid_de        : out std_logic;
    vid_hs        : out std_logic;
    vid_vs        : out std_logic;
    -- G_DIRECT_VIDEO = 1: pixel clock (= the core's video clock), 5x serial clock, PLL locked
    vid_clk       : out std_logic;
    vid_clk_ser   : out std_logic;
    vid_locked    : out std_logic;

    -- audio (I2S of audio_out, clk_audio)
    i2s_mclk      : out std_logic;
    i2s_bclk      : out std_logic;
    i2s_lrclk     : out std_logic;
    i2s_data      : out std_logic;

    -- board
    btn_osd       : in  std_logic;       -- active high
    btn_user      : in  std_logic;
    sw            : in  std_logic_vector(3 downto 0);  -- SW of the DE10-Nano
    led           : out std_logic_vector(7 downto 0);  -- LED of the DE10-Nano (DE10 layout)
    status_err    : out std_logic        -- sticky: a stage C error (emulator, region, cache, AXI)
  );
end entity mister_zynq;

architecture rtl of mister_zynq is

  -- block design: clocks and their AXI interfaces (the interfaces are inferred from the names;
  -- Vivado reads these attributes in the architecture only)
  attribute X_INTERFACE_INFO : string;
  attribute X_INTERFACE_PARAMETER : string;
  attribute X_INTERFACE_INFO of clk_100 : signal is "xilinx.com:signal:clock:1.0 clk_100 CLK";
  attribute X_INTERFACE_PARAMETER of clk_100 : signal is
    "ASSOCIATED_BUSIF s_axi:m_axi_vbuf, ASSOCIATED_RESET aresetn";
  attribute X_INTERFACE_INFO of clk_master : signal is "xilinx.com:signal:clock:1.0 clk_master CLK";
  attribute X_INTERFACE_PARAMETER of clk_master : signal is "ASSOCIATED_BUSIF m_axi_sdram";
  attribute X_INTERFACE_INFO of ddram_clk : signal is "xilinx.com:signal:clock:1.0 ddram_clk CLK";
  -- FREQ_HZ only for the block design (an output clock needs one, IP_Flow 19-4751); the real
  -- frequency is the core's DDRAM_CLK, timed through its MMCM constraints (same for coremem_clk,
  -- vid_clk, vid_clk_ser)
  attribute X_INTERFACE_PARAMETER of ddram_clk : signal is "ASSOCIATED_BUSIF m_axi_ddram, FREQ_HZ 100000000";
  attribute X_INTERFACE_INFO of coremem_clk : signal is "xilinx.com:signal:clock:1.0 coremem_clk CLK";
  attribute X_INTERFACE_PARAMETER of coremem_clk : signal is "ASSOCIATED_BUSIF m_axi_coremem, FREQ_HZ 100000000";
  attribute X_INTERFACE_INFO of vid_clk : signal is "xilinx.com:signal:clock:1.0 vid_clk CLK";
  attribute X_INTERFACE_PARAMETER of vid_clk : signal is "FREQ_HZ 100000000";
  attribute X_INTERFACE_INFO of vid_clk_ser : signal is "xilinx.com:signal:clock:1.0 vid_clk_ser CLK";
  attribute X_INTERFACE_PARAMETER of vid_clk_ser : signal is "FREQ_HZ 100000000";
  attribute X_INTERFACE_INFO of clk_master_gate : signal is "xilinx.com:signal:clock:1.0 clk_master_gate CLK";
  attribute X_INTERFACE_INFO of aresetn : signal is "xilinx.com:signal:reset:1.0 aresetn RST";
  attribute X_INTERFACE_PARAMETER of aresetn : signal is "POLARITY ACTIVE_LOW";

  component sys_top_zynq is
    port (
      ZYNQ_h2f_gp_gp_in                   : out std_logic_vector(31 downto 0);
      ZYNQ_h2f_gp_gp_out                  : in  std_logic_vector(31 downto 0);
      ZYNQ_uart_ri                        : out std_logic;
      ZYNQ_uart_dsr                       : out std_logic;
      ZYNQ_uart_dcd                       : out std_logic;
      ZYNQ_uart_dtr                       : in  std_logic;
      ZYNQ_uart_cts                       : out std_logic;
      ZYNQ_uart_rts                       : in  std_logic;
      ZYNQ_uart_rxd                       : out std_logic;
      ZYNQ_uart_txd                       : in  std_logic;
      ZYNQ_interrupts_irq                 : out std_logic_vector(63 downto 0);
      ZYNQ_sysmem_reset_core_req          : out std_logic;
      ZYNQ_sysmem_reset_out               : in  std_logic;
      ZYNQ_sysmem_clock                   : in  std_logic;
      ZYNQ_sysmem_reset_hps_cold_req      : out std_logic;
      ZYNQ_sysmem_ram1_clk                : out std_logic;
      ZYNQ_sysmem_ram1_address            : out std_logic_vector(28 downto 0);
      ZYNQ_sysmem_ram1_burstcount         : out std_logic_vector(7 downto 0);
      ZYNQ_sysmem_ram1_waitrequest        : in  std_logic;
      ZYNQ_sysmem_ram1_readdata           : in  std_logic_vector(63 downto 0);
      ZYNQ_sysmem_ram1_readdatavalid      : in  std_logic;
      ZYNQ_sysmem_ram1_read               : out std_logic;
      ZYNQ_sysmem_ram1_writedata          : out std_logic_vector(63 downto 0);
      ZYNQ_sysmem_ram1_byteenable         : out std_logic_vector(7 downto 0);
      ZYNQ_sysmem_ram1_write              : out std_logic;
      ZYNQ_sysmem_ram2_clk                : out std_logic;
      ZYNQ_sysmem_ram2_address            : out std_logic_vector(28 downto 0);
      ZYNQ_sysmem_ram2_burstcount         : out std_logic_vector(7 downto 0);
      ZYNQ_sysmem_ram2_waitrequest        : in  std_logic;
      ZYNQ_sysmem_ram2_readdata           : in  std_logic_vector(63 downto 0);
      ZYNQ_sysmem_ram2_readdatavalid      : in  std_logic;
      ZYNQ_sysmem_ram2_read               : out std_logic;
      ZYNQ_sysmem_ram2_writedata          : out std_logic_vector(63 downto 0);
      ZYNQ_sysmem_ram2_byteenable         : out std_logic_vector(7 downto 0);
      ZYNQ_sysmem_ram2_write              : out std_logic;
      ZYNQ_sysmem_vbuf_clk                : out std_logic;
      ZYNQ_sysmem_vbuf_address            : out std_logic_vector(28 downto 0);
      ZYNQ_sysmem_vbuf_burstcount         : out std_logic_vector(7 downto 0);
      ZYNQ_sysmem_vbuf_waitrequest        : in  std_logic;
      ZYNQ_sysmem_vbuf_writedata          : out std_logic_vector(63 downto 0);
      ZYNQ_sysmem_vbuf_byteenable         : out std_logic_vector(7 downto 0);
      ZYNQ_sysmem_vbuf_write              : out std_logic;
      ZYNQ_sysmem_vbuf_readdata           : in  std_logic_vector(63 downto 0);
      ZYNQ_sysmem_vbuf_readdatavalid      : in  std_logic;
      ZYNQ_sysmem_vbuf_read               : out std_logic;
      ZYNQ_pll_hdmi_refclk                : out std_logic;
      ZYNQ_pll_hdmi_rst                   : out std_logic;
      ZYNQ_pll_hdmi_reconfig_to_pll       : out std_logic_vector(63 downto 0);
      ZYNQ_pll_hdmi_reconfig_from_pll     : in  std_logic_vector(63 downto 0);
      ZYNQ_pll_hdmi_outclk_0              : in  std_logic;
      ZYNQ_pll_cfg_hdmi_mgmt_clk          : out std_logic;
      ZYNQ_pll_cfg_hdmi_mgmt_reset        : out std_logic;
      ZYNQ_pll_cfg_hdmi_mgmt_waitrequest  : in  std_logic;
      ZYNQ_pll_cfg_hdmi_mgmt_write        : out std_logic;
      ZYNQ_pll_cfg_hdmi_mgmt_address      : out std_logic_vector(5 downto 0);
      ZYNQ_pll_cfg_hdmi_mgmt_writedata    : out std_logic_vector(31 downto 0);
      ZYNQ_pll_cfg_hdmi_reconfig_to_pll   : in  std_logic_vector(63 downto 0);
      ZYNQ_pll_cfg_hdmi_reconfig_from_pll : out std_logic_vector(63 downto 0);
      ZYNQ_hdmi_i2c_out_clk               : in  std_logic;
      ZYNQ_hdmi_i2c_scl                   : out std_logic;
      ZYNQ_hdmi_i2c_out_data              : in  std_logic;
      ZYNQ_hdmi_i2c_sda                   : out std_logic;
      ZYNQ_hdmi_clk_sw_clkselect          : out std_logic_vector(1 downto 0);
      ZYNQ_hdmi_clk_sw_inclk              : out std_logic_vector(3 downto 0);
      ZYNQ_hdmi_clk_sw_outclk             : in  std_logic;
      ZYNQ_vga_clk_sw_clkselect           : out std_logic_vector(1 downto 0);
      ZYNQ_vga_clk_sw_inclk               : out std_logic_vector(3 downto 0);
      ZYNQ_vga_clk_sw_outclk              : in  std_logic;
      ZYNQ_pll_audio_refclk               : out std_logic;
      ZYNQ_pll_audio_rst                  : out std_logic;
      ZYNQ_pll_audio_outclk_0             : in  std_logic;
      ZYNQ_spi_sclk_out                   : in  std_logic;
      ZYNQ_spi_txd                        : in  std_logic;
      ZYNQ_spi_rxd                        : out std_logic;
      ZYNQ_spi_ss_0_n                     : in  std_logic;
      ZYNQ_spi_ss_in_n                    : out std_logic;
      ZYNQ_CLK_CORE                       : in  std_logic;
      ZYNQ_CLK_SYS                        : out std_logic;
      ZYNQ_CLK_HDMI_TX                    : out std_logic;
      ZYNQ_PACE_ALT                       : out std_logic;
      ZYNQ_coremem_clk                    : out std_logic;
      ZYNQ_coremem_address                : out std_logic_vector(28 downto 0);
      ZYNQ_coremem_burstcount             : out std_logic_vector(7 downto 0);
      ZYNQ_coremem_waitrequest            : in  std_logic;
      ZYNQ_coremem_readdata               : in  std_logic_vector(63 downto 0);
      ZYNQ_coremem_readdatavalid          : in  std_logic;
      ZYNQ_coremem_read                   : out std_logic;
      ZYNQ_coremem_writedata              : out std_logic_vector(63 downto 0);
      ZYNQ_coremem_byteenable             : out std_logic_vector(7 downto 0);
      ZYNQ_coremem_write                  : out std_logic;
      FPGA_CLK1_50                        : in  std_logic;
      FPGA_CLK2_50                        : in  std_logic;
      FPGA_CLK3_50                        : in  std_logic;
      HDMI_I2C_SCL                        : out std_logic;
      HDMI_I2C_SDA                        : inout std_logic;
      HDMI_MCLK                           : out std_logic;
      HDMI_SCLK                           : out std_logic;
      HDMI_LRCLK                          : out std_logic;
      HDMI_I2S                            : out std_logic;
      HDMI_TX_CLK                         : out std_logic;
      HDMI_TX_DE                          : out std_logic;
      HDMI_TX_D                           : out std_logic_vector(23 downto 0);
      HDMI_TX_HS                          : out std_logic;
      HDMI_TX_VS                          : out std_logic;
      HDMI_TX_INT                         : in  std_logic;
      SDRAM_A                             : out std_logic_vector(12 downto 0);
      SDRAM_DQ                            : inout std_logic_vector(15 downto 0);
      SDRAM_DQML                          : out std_logic;
      SDRAM_DQMH                          : out std_logic;
      SDRAM_nWE                           : out std_logic;
      SDRAM_nCAS                          : out std_logic;
      SDRAM_nRAS                          : out std_logic;
      SDRAM_nCS                           : out std_logic;
      SDRAM_BA                            : out std_logic_vector(1 downto 0);
      SDRAM_CLK                           : out std_logic;
      SDRAM_CKE                           : out std_logic;
      VGA_R                               : out std_logic_vector(5 downto 0);
      VGA_G                               : out std_logic_vector(5 downto 0);
      VGA_B                               : out std_logic_vector(5 downto 0);
      VGA_HS                              : inout std_logic;
      VGA_VS                              : out std_logic;
      VGA_EN                              : in  std_logic;
      AUDIO_L                             : out std_logic;
      AUDIO_R                             : out std_logic;
      AUDIO_SPDIF                         : out std_logic;
      SDIO_DAT                            : inout std_logic_vector(3 downto 0);
      SDIO_CMD                            : inout std_logic;
      SDIO_CLK                            : out std_logic;
      LED_USER                            : out std_logic;
      LED_HDD                             : out std_logic;
      LED_POWER                           : out std_logic;
      BTN_USER                            : in  std_logic;
      BTN_OSD                             : in  std_logic;
      BTN_RESET                           : in  std_logic;
      SD_SPI_CS                           : out std_logic;
      SD_SPI_MISO                         : in  std_logic;
      SD_SPI_CLK                          : out std_logic;
      SD_SPI_MOSI                         : out std_logic;
      SDCD_SPDIF                          : inout std_logic;
      IO_SCL                              : out std_logic;
      IO_SDA                              : inout std_logic;
      ADC_SCK                             : out std_logic;
      ADC_SDO                             : in  std_logic;
      ADC_SDI                             : out std_logic;
      ADC_CONVST                          : out std_logic;
      KEY                                 : in  std_logic_vector(1 downto 0);
      SW                                  : in  std_logic_vector(3 downto 0);
      LED                                 : out std_logic_vector(7 downto 0);
      USER_IO                             : inout std_logic_vector(6 downto 0)
    );
  end component;

  constant C_ADDR_BITS : natural := G_SD_BANK_BITS + G_SD_ROW_BITS + G_SD_COL_BITS;

  signal rst_100       : std_logic;
  signal rst_m_s       : std_logic_vector(1 downto 0) := "11";   -- reset synchronizer, clk_master
  signal rst_m         : std_logic;
  signal clk_sys       : std_logic;
  signal clk_core      : std_logic;
  signal gp_out_sys    : std_logic_vector(31 downto 0);
  signal gp_in_sys     : std_logic_vector(31 downto 0);
  signal reset_core_req : std_logic;
  signal sysmem_reset  : std_logic;
  signal key_n         : std_logic_vector(1 downto 0);
  signal cfg_write     : std_logic;
  signal cfg_wait      : std_logic := '0';

  -- SDRAM pins of the core
  signal sd_dq         : std_logic_vector(15 downto 0);
  signal sd_a          : std_logic_vector(12 downto 0);
  signal sd_ba         : std_logic_vector(1 downto 0);
  signal sd_dqm        : std_logic_vector(1 downto 0);   -- DQMH & DQML
  signal sd_dqml, sd_dqmh, sd_we_n, sd_cas_n, sd_ras_n, sd_cs_n : std_logic;
  signal dq_o          : std_logic_vector(15 downto 0);
  signal dq_oe         : std_logic;

  -- stage C
  signal ce, stall     : std_logic;
  signal err_late, err_mode, err_region, err_cache, err_axi : std_logic;
  signal be_req, be_we, be_ready, be_rvalid : std_logic;
  signal be_addr       : std_logic_vector(C_ADDR_BITS - 1 downto 0);
  signal be_wdata, be_rdata : std_logic_vector(15 downto 0);
  signal be_wstrb      : std_logic_vector(1 downto 0);
  signal b0_req, b0_we, b0_ready, b0_rvalid : std_logic;
  signal b0_addr       : std_logic_vector(G_B0_BITS - 1 downto 0);
  signal b0_wdata, b0_rdata : std_logic_vector(15 downto 0);
  signal b0_wstrb      : std_logic_vector(1 downto 0);
  signal b1_req, b1_we, b1_ready, b1_rvalid : std_logic;
  signal b1_addr       : std_logic_vector(C_ADDR_BITS - 1 downto 0);
  signal b1_wdata, b1_rdata : std_logic_vector(15 downto 0);
  signal b1_wstrb      : std_logic_vector(1 downto 0);
  signal c_addr        : std_logic_vector(C_ADDR_BITS - 1 downto 0);
  signal c_waitrequest, c_read, c_readdatavalid, c_write : std_logic;
  signal c_burstcount  : std_logic_vector(7 downto 0);
  signal c_address     : std_logic_vector(28 downto 0);
  signal c_readdata, c_writedata : std_logic_vector(63 downto 0);
  signal c_byteenable  : std_logic_vector(7 downto 0);

  -- ascal frame buffer
  signal v_waitrequest, v_read, v_readdatavalid, v_write : std_logic;
  signal v_burstcount  : std_logic_vector(7 downto 0);
  signal v_address     : std_logic_vector(28 downto 0);
  signal v_readdata, v_writedata : std_logic_vector(63 downto 0);
  signal v_byteenable  : std_logic_vector(7 downto 0);
  signal v_error       : std_logic;

  -- DDRAM_* of the core (sysmem ram1, ddram_clk domain)
  signal dd_clk        : std_logic;
  signal dd_waitrequest, dd_read, dd_readdatavalid, dd_write : std_logic;
  signal dd_burstcount : std_logic_vector(7 downto 0);
  signal dd_address    : std_logic_vector(28 downto 0);
  signal dd_readdata, dd_writedata : std_logic_vector(63 downto 0);
  signal dd_byteenable : std_logic_vector(7 downto 0);
  signal dd_idle       : std_logic := '1';
  signal dd_error      : std_logic := '0';

  -- memory port of the core (ZYNQ_coremem_*, coremem_clk domain)
  signal cm_clk        : std_logic;
  signal clk_tx        : std_logic;                       -- clock of HDMI_TX_*
  signal pace_alt      : std_logic;                       -- core asks for the second pacer ratio
  signal cm_waitrequest, cm_read, cm_readdatavalid, cm_write : std_logic;
  signal cm_burstcount : std_logic_vector(7 downto 0);
  signal cm_address    : std_logic_vector(28 downto 0);
  signal cm_readdata, cm_writedata : std_logic_vector(63 downto 0);
  signal cm_byteenable : std_logic_vector(7 downto 0);
  signal cm_idle       : std_logic := '1';
  signal cm_error      : std_logic := '0';

  signal hdmi_d        : std_logic_vector(23 downto 0);
  signal err_m         : std_logic := '0';                        -- stage C error, registered (clk_master)
  signal err_s         : std_logic_vector(1 downto 0) := "00";  -- err_m in the clk_100 domain

  -- quiescing of the HP ports (clk_100: quiesce, v_idle, hp_idle; clk_master: sd_hold, sd_idle)
  signal quiesce       : std_logic;
  signal sd_hold_s     : std_logic_vector(1 downto 0) := "00";
  signal sd_idle       : std_logic;
  signal sd_idle_s     : std_logic_vector(1 downto 0) := "00";
  signal v_idle        : std_logic;
  signal hp_idle       : std_logic := '0';
  -- ddram_clk: dd_rst_s, dd_hold_s; clk_100: dd_idle_s, dd_err_s
  signal dd_rst_s      : std_logic_vector(1 downto 0) := "11";
  signal dd_hold_s     : std_logic_vector(1 downto 0) := "00";
  signal dd_idle_s     : std_logic_vector(1 downto 0) := "00";
  signal dd_err_s      : std_logic_vector(1 downto 0) := "00";
  -- coremem_clk: cm_rst_s, cm_hold_s; clk_100: cm_idle_s, cm_err_s
  signal cm_rst_s      : std_logic_vector(1 downto 0) := "11";
  signal cm_hold_s     : std_logic_vector(1 downto 0) := "00";
  signal cm_idle_s     : std_logic_vector(1 downto 0) := "00";
  signal cm_err_s      : std_logic_vector(1 downto 0) := "00";

  -- stage C event counters (clk_master)
  constant C_PERF_N    : natural := 16;
  signal ev_hit, ev_miss, ev_busy, ev_drain, ev_wfull, ev_write : std_logic;
  signal ev_miss_hi, ev_miss_vict, ev_miss_vict_x, ev_miss_seq, ev_rd_hi : std_logic;
  signal lag           : std_logic_vector(15 downto 0);
  signal perf_ev       : std_logic_vector(C_PERF_N - 1 downto 0) := (others => '0');
  signal perf_snap     : std_logic_vector(32 * (C_PERF_N + 1) - 1 downto 0);

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of rst_m_s, err_s, sd_hold_s, sd_idle_s : signal is "TRUE";
  attribute ASYNC_REG of dd_rst_s, dd_hold_s, dd_idle_s, dd_err_s : signal is "TRUE";

begin

  rst_100 <= not aresetn;

  process (clk_master)
  begin
    if rising_edge(clk_master) then
      rst_m_s <= rst_m_s(0) & rst_100;
    end if;
  end process;
  rst_m <= rst_m_s(1);

  ------------------------------------------------------------------------------
  -- MiSTer framework with the core
  ------------------------------------------------------------------------------
  sys : sys_top_zynq
    port map (
      ZYNQ_h2f_gp_gp_in                   => gp_in_sys,
      ZYNQ_h2f_gp_gp_out                  => gp_out_sys,
      ZYNQ_uart_ri                        => open,
      ZYNQ_uart_dsr                       => open,
      ZYNQ_uart_dcd                       => open,
      ZYNQ_uart_dtr                       => '1',
      ZYNQ_uart_cts                       => open,
      ZYNQ_uart_rts                       => '1',
      ZYNQ_uart_rxd                       => open,
      ZYNQ_uart_txd                       => '1',
      ZYNQ_interrupts_irq                 => open,
      ZYNQ_sysmem_reset_core_req          => reset_core_req,
      ZYNQ_sysmem_reset_out               => sysmem_reset,
      ZYNQ_sysmem_clock                   => clk_100,
      ZYNQ_sysmem_reset_hps_cold_req      => open,
      ZYNQ_sysmem_ram1_clk                => dd_clk,
      ZYNQ_sysmem_ram1_address            => dd_address,
      ZYNQ_sysmem_ram1_burstcount         => dd_burstcount,
      ZYNQ_sysmem_ram1_waitrequest        => dd_waitrequest,
      ZYNQ_sysmem_ram1_readdata           => dd_readdata,
      ZYNQ_sysmem_ram1_readdatavalid      => dd_readdatavalid,
      ZYNQ_sysmem_ram1_read               => dd_read,
      ZYNQ_sysmem_ram1_writedata          => dd_writedata,
      ZYNQ_sysmem_ram1_byteenable         => dd_byteenable,
      ZYNQ_sysmem_ram1_write              => dd_write,
      ZYNQ_sysmem_ram2_clk                => open,
      ZYNQ_sysmem_ram2_address            => open,
      ZYNQ_sysmem_ram2_burstcount         => open,
      ZYNQ_sysmem_ram2_waitrequest        => '0',
      ZYNQ_sysmem_ram2_readdata           => (others => '0'),
      ZYNQ_sysmem_ram2_readdatavalid      => '0',
      ZYNQ_sysmem_ram2_read               => open,
      ZYNQ_sysmem_ram2_writedata          => open,
      ZYNQ_sysmem_ram2_byteenable         => open,
      ZYNQ_sysmem_ram2_write              => open,
      ZYNQ_sysmem_vbuf_clk                => open,
      ZYNQ_sysmem_vbuf_address            => v_address,
      ZYNQ_sysmem_vbuf_burstcount         => v_burstcount,
      ZYNQ_sysmem_vbuf_waitrequest        => v_waitrequest,
      ZYNQ_sysmem_vbuf_writedata          => v_writedata,
      ZYNQ_sysmem_vbuf_byteenable         => v_byteenable,
      ZYNQ_sysmem_vbuf_write              => v_write,
      ZYNQ_sysmem_vbuf_readdata           => v_readdata,
      ZYNQ_sysmem_vbuf_readdatavalid      => v_readdatavalid,
      ZYNQ_sysmem_vbuf_read               => v_read,
      ZYNQ_pll_hdmi_refclk                => open,
      ZYNQ_pll_hdmi_rst                   => open,
      ZYNQ_pll_hdmi_reconfig_to_pll       => open,
      ZYNQ_pll_hdmi_reconfig_from_pll     => (others => '0'),
      ZYNQ_pll_hdmi_outclk_0              => clk_hdmi,
      ZYNQ_pll_cfg_hdmi_mgmt_clk          => open,
      ZYNQ_pll_cfg_hdmi_mgmt_reset        => open,
      ZYNQ_pll_cfg_hdmi_mgmt_waitrequest  => cfg_wait,
      ZYNQ_pll_cfg_hdmi_mgmt_write        => cfg_write,
      ZYNQ_pll_cfg_hdmi_mgmt_address      => open,
      ZYNQ_pll_cfg_hdmi_mgmt_writedata    => open,
      ZYNQ_pll_cfg_hdmi_reconfig_to_pll   => (others => '0'),
      ZYNQ_pll_cfg_hdmi_reconfig_from_pll => open,
      ZYNQ_hdmi_i2c_out_clk               => '0',
      ZYNQ_hdmi_i2c_scl                   => open,
      ZYNQ_hdmi_i2c_out_data              => '0',
      ZYNQ_hdmi_i2c_sda                   => open,
      ZYNQ_hdmi_clk_sw_clkselect          => open,
      ZYNQ_hdmi_clk_sw_inclk              => open,
      ZYNQ_hdmi_clk_sw_outclk             => clk_hdmi,
      ZYNQ_vga_clk_sw_clkselect           => open,
      ZYNQ_vga_clk_sw_inclk               => open,
      ZYNQ_vga_clk_sw_outclk              => clk_hdmi,
      ZYNQ_pll_audio_refclk               => open,
      ZYNQ_pll_audio_rst                  => open,
      ZYNQ_pll_audio_outclk_0             => clk_audio,
      ZYNQ_spi_sclk_out                   => '0',
      ZYNQ_spi_txd                        => '0',
      ZYNQ_spi_rxd                        => open,
      ZYNQ_spi_ss_0_n                     => '1',
      ZYNQ_spi_ss_in_n                    => open,
      ZYNQ_CLK_CORE                       => clk_core,
      ZYNQ_CLK_SYS                        => clk_sys,
      ZYNQ_CLK_HDMI_TX                    => clk_tx,
      ZYNQ_PACE_ALT                       => pace_alt,
      ZYNQ_coremem_clk                    => cm_clk,
      ZYNQ_coremem_address                => cm_address,
      ZYNQ_coremem_burstcount             => cm_burstcount,
      ZYNQ_coremem_waitrequest            => cm_waitrequest,
      ZYNQ_coremem_readdata               => cm_readdata,
      ZYNQ_coremem_readdatavalid          => cm_readdatavalid,
      ZYNQ_coremem_read                   => cm_read,
      ZYNQ_coremem_writedata              => cm_writedata,
      ZYNQ_coremem_byteenable             => cm_byteenable,
      ZYNQ_coremem_write                  => cm_write,
      FPGA_CLK1_50                        => clk_50,
      FPGA_CLK2_50                        => clk_50,
      FPGA_CLK3_50                        => clk_50,
      HDMI_I2C_SCL                        => open,
      HDMI_I2C_SDA                        => open,
      HDMI_MCLK                           => i2s_mclk,
      HDMI_SCLK                           => i2s_bclk,
      HDMI_LRCLK                          => i2s_lrclk,
      HDMI_I2S                            => i2s_data,
      HDMI_TX_CLK                         => open,
      HDMI_TX_DE                          => vid_de,
      HDMI_TX_D                           => hdmi_d,
      HDMI_TX_HS                          => vid_hs,
      HDMI_TX_VS                          => vid_vs,
      HDMI_TX_INT                         => '1',          -- no ADV7513 interrupt
      SDRAM_A                             => sd_a,
      SDRAM_DQ                            => sd_dq,
      SDRAM_DQML                          => sd_dqml,
      SDRAM_DQMH                          => sd_dqmh,
      SDRAM_nWE                           => sd_we_n,
      SDRAM_nCAS                          => sd_cas_n,
      SDRAM_nRAS                          => sd_ras_n,
      SDRAM_nCS                           => sd_cs_n,
      SDRAM_BA                            => sd_ba,
      SDRAM_CLK                           => open,
      SDRAM_CKE                           => open,
      VGA_R                               => open,
      VGA_G                               => open,
      VGA_B                               => open,
      VGA_HS                              => open,
      VGA_VS                              => open,
      VGA_EN                              => '1',          -- active low: no VGA, IO board buttons off
      AUDIO_L                             => open,
      AUDIO_R                             => open,
      AUDIO_SPDIF                         => open,
      SDIO_DAT                            => open,
      SDIO_CMD                            => open,
      SDIO_CLK                            => open,
      LED_USER                            => open,
      LED_HDD                             => open,
      LED_POWER                           => open,
      BTN_USER                            => '1',          -- IO board buttons, active low
      BTN_OSD                             => '1',
      BTN_RESET                           => '1',
      SD_SPI_CS                           => open,
      SD_SPI_MISO                         => '1',
      SD_SPI_CLK                          => open,
      SD_SPI_MOSI                         => open,
      SDCD_SPDIF                          => open,
      IO_SCL                              => open,
      IO_SDA                              => open,
      ADC_SCK                             => open,
      ADC_SDO                             => '0',
      ADC_SDI                             => open,
      ADC_CONVST                          => open,
      KEY                                 => key_n,
      SW                                  => sw,
      LED                                 => led,
      USER_IO                             => open
    );

  -- sysmem.sv: reset_out = power-up reset or HPS reset or core reset request (combinational)
  sysmem_reset <= rst_100 or reset_core_req;
  key_n        <= not (btn_user & btn_osd);   -- DE10-Nano KEY: active low, KEY(1) user, KEY(0) OSD

  vid_data <= hdmi_d(23 downto 16) & hdmi_d(7 downto 0) & hdmi_d(15 downto 8);   -- RGB -> RBG

  -- PLL reconfiguration of the HDMI clock: no PLL to reconfigure, waitrequest pulses once
  -- after a write (sys_top waits for its falling edge, pll_hdmi_adj for it being low)
  process (clk_50)
  begin
    if rising_edge(clk_50) then
      cfg_wait <= cfg_write;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- HPS bus: GPO/GPI registers, sys_top's own logic behind them
  ------------------------------------------------------------------------------
  hps : entity work.hps_bus_axi
    generic map (G_CORE_TYPE => x"A4", G_RD_WAIT => G_RD_WAIT, G_RAW => true, G_ADDR_W => 7,
                 G_AUX => C_PERF_N + 1)
    port map (
      aclk => clk_100, aresetn => aresetn,
      s_axi_awaddr => s_axi_awaddr, s_axi_awprot => s_axi_awprot, s_axi_awvalid => s_axi_awvalid,
      s_axi_awready => s_axi_awready, s_axi_wdata => s_axi_wdata, s_axi_wstrb => s_axi_wstrb,
      s_axi_wvalid => s_axi_wvalid, s_axi_wready => s_axi_wready, s_axi_bresp => s_axi_bresp,
      s_axi_bvalid => s_axi_bvalid, s_axi_bready => s_axi_bready, s_axi_araddr => s_axi_araddr,
      s_axi_arprot => s_axi_arprot, s_axi_arvalid => s_axi_arvalid, s_axi_arready => s_axi_arready,
      s_axi_rdata => s_axi_rdata, s_axi_rresp => s_axi_rresp, s_axi_rvalid => s_axi_rvalid,
      s_axi_rready => s_axi_rready,
      reset_in => '0', reset_req => open, quiesce => quiesce, idle => hp_idle, led_disk => open,
      clk_sys => clk_sys, io_din => open, io_strobe => open, io_fpga => open, io_uio => open,
      io_osd_hdmi => open, io_osd_vga => open, io_dout => (others => '0'), io_wide => '0', io_wait => '0',
      gp_out_sys => gp_out_sys, gp_in_sys => gp_in_sys, aux => perf_snap);

  ------------------------------------------------------------------------------
  -- stage C: gated core master clock, SDRAM emulator, BRAM region, cache, HP0
  ------------------------------------------------------------------------------
  g_stage_c : if G_FREE_CLK = 0 generate
  pacer : entity work.core_clock_stall
    generic map (G_NUM => G_PACE_NUM, G_DEN => G_PACE_DEN, G_BUCKET => G_PACE_BUCKET, G_DIV1 => 0, G_DIV2 => 0,
                 G_NUM_ALT => G_PACE_NUM_ALT, G_DEN_ALT => G_PACE_DEN_ALT)
    port map (clk => clk_master, rst => rst_m, stall => stall, alt => pace_alt, ce => ce, ce_div1 => open,
              ce_div2 => open, lag => lag);

  -- ce comes from clk_master; clk_master_gate has the same edges (same MMCM divider, no BUFG)
  core_buf : BUFGCE
    port map (I => clk_master_gate, CE => ce, O => clk_core);

  -- SDRAM_DQ: the core drives it when writing, the emulator in the cycle after a read beat
  sd_dqm <= sd_dqmh & sd_dqml;
  sd_dq  <= dq_o when dq_oe = '1' else (others => 'Z');

  emu : entity work.sdram_emu
    generic map (G_BANK_BITS => G_SD_BANK_BITS, G_ROW_BITS => G_SD_ROW_BITS, G_COL_BITS => G_SD_COL_BITS,
                 G_RD_ADJ => G_SD_RD_ADJ)
    port map (
      clk => clk_master, rst => rst_m, ce => ce,
      sd_cs_n => sd_cs_n, sd_ras_n => sd_ras_n, sd_cas_n => sd_cas_n, sd_we_n => sd_we_n,
      sd_ba => sd_ba(G_SD_BANK_BITS - 1 downto 0), sd_a => sd_a, sd_dqm => sd_dqm,
      sd_dq_i => sd_dq, sd_dq_o => dq_o, sd_dq_oe => dq_oe,
      be_req => be_req, be_we => be_we, be_addr => be_addr, be_wdata => be_wdata, be_wstrb => be_wstrb,
      be_ready => be_ready, be_rvalid => be_rvalid, be_rdata => be_rdata,
      stall => stall, err_late => err_late, err_mode => err_mode);

  g_region : if G_B0_BITS > 0 generate
  region : entity work.sdram_region
    generic map (G_ADDR_BITS => C_ADDR_BITS, G_B0_MASK => G_B0_MASK, G_B0_MATCH => G_B0_MATCH,
                 G_B0_SEL => G_B0_SEL, G_B0_BITS => G_B0_BITS)
    port map (
      clk => clk_master, rst => rst_m,
      req => be_req, we => be_we, addr => be_addr, wdata => be_wdata, wstrb => be_wstrb,
      ready => be_ready, rvalid => be_rvalid, rdata => be_rdata,
      b0_req => b0_req, b0_we => b0_we, b0_addr => b0_addr, b0_wdata => b0_wdata, b0_wstrb => b0_wstrb,
      b0_ready => b0_ready, b0_rvalid => b0_rvalid, b0_rdata => b0_rdata,
      b1_req => b1_req, b1_we => b1_we, b1_addr => b1_addr, b1_wdata => b1_wdata, b1_wstrb => b1_wstrb,
      b1_ready => b1_ready, b1_rvalid => b1_rvalid, b1_rdata => b1_rdata,
      err => err_region);

  bram : entity work.sdram_bram
    generic map (G_ADDR_BITS => G_B0_BITS)
    port map (clk => clk_master, req => b0_req, we => b0_we, addr => b0_addr, wdata => b0_wdata,
              wstrb => b0_wstrb, ready => b0_ready, rvalid => b0_rvalid, rdata => b0_rdata);
  end generate;

  g_no_region : if G_B0_BITS = 0 generate
    b1_req   <= be_req;
    b1_we    <= be_we;
    b1_addr  <= be_addr;
    b1_wdata <= be_wdata;
    b1_wstrb <= be_wstrb;
    be_ready <= b1_ready;
    be_rvalid <= b1_rvalid;
    be_rdata <= b1_rdata;
    err_region <= '0';
  end generate;

  -- word address of the cache and the DDR image: the cache lines must hold neighbouring words of
  -- the core.  A core whose controller puts its low address bits on the row (MSX: CpuAdr(13:1) on
  -- the row, (22:14) on the column) would otherwise get the same offset of 2**G_CACHE_LINE_LOG2 * 4
  -- different segments in one line, and nearly every new address would miss
  g_col_high : if G_CACHE_COL_HIGH /= 0 generate
    c_addr <= b1_addr(C_ADDR_BITS - 1 downto G_SD_ROW_BITS + G_SD_COL_BITS) &
              b1_addr(G_SD_COL_BITS - 1 downto 0) &
              b1_addr(G_SD_ROW_BITS + G_SD_COL_BITS - 1 downto G_SD_COL_BITS);
  end generate;
  g_row_high : if G_CACHE_COL_HIGH = 0 generate
    c_addr <= b1_addr;
  end generate;

  cache : entity work.sdram_cache
    generic map (G_ADDR_BITS => C_ADDR_BITS, G_LINE_LOG2 => G_CACHE_LINE_LOG2,
                 G_INDEX_BITS => G_CACHE_INDEX_BITS, G_SPLIT => G_CACHE_SPLIT, G_AVL_ADDR_W => 29)
    port map (
      clk => clk_master, rst => rst_m,
      req => b1_req, we => b1_we, addr => c_addr, wdata => b1_wdata, wstrb => b1_wstrb,
      ready => b1_ready, rvalid => b1_rvalid, rdata => b1_rdata,
      avl_waitrequest => c_waitrequest, avl_burstcount => c_burstcount, avl_address => c_address,
      avl_read => c_read, avl_readdata => c_readdata, avl_readdatavalid => c_readdatavalid,
      avl_write => c_write, avl_writedata => c_writedata, avl_byteenable => c_byteenable,
      ev_hit => ev_hit, ev_miss => ev_miss, ev_busy => ev_busy, ev_drain => ev_drain, ev_wfull => ev_wfull,
      ev_write => ev_write, ev_miss_hi => ev_miss_hi, ev_miss_vict => ev_miss_vict,
      ev_miss_vict_x => ev_miss_vict_x, ev_miss_seq => ev_miss_seq, ev_rd_hi => ev_rd_hi, err => err_cache);

  sdram_bridge : entity work.avl_axi_bridge
    generic map (G_BYTE_OFFSET => G_SDRAM_BASE)
    port map (
      clk => clk_master, rst => rst_m, hold => sd_hold_s(1), idle => sd_idle,
      avl_waitrequest => c_waitrequest, avl_burstcount => c_burstcount, avl_address => c_address,
      avl_read => c_read, avl_readdata => c_readdata, avl_readdatavalid => c_readdatavalid,
      avl_write => c_write, avl_writedata => c_writedata, avl_byteenable => c_byteenable,
      m_axi_awid => m_axi_sdram_awid, m_axi_awaddr => m_axi_sdram_awaddr, m_axi_awlen => m_axi_sdram_awlen,
      m_axi_awsize => m_axi_sdram_awsize, m_axi_awburst => m_axi_sdram_awburst,
      m_axi_awlock => m_axi_sdram_awlock, m_axi_awcache => m_axi_sdram_awcache,
      m_axi_awprot => m_axi_sdram_awprot, m_axi_awqos => m_axi_sdram_awqos,
      m_axi_awvalid => m_axi_sdram_awvalid, m_axi_awready => m_axi_sdram_awready,
      m_axi_wid => m_axi_sdram_wid, m_axi_wdata => m_axi_sdram_wdata, m_axi_wstrb => m_axi_sdram_wstrb,
      m_axi_wlast => m_axi_sdram_wlast, m_axi_wvalid => m_axi_sdram_wvalid, m_axi_wready => m_axi_sdram_wready,
      m_axi_bid => m_axi_sdram_bid, m_axi_bresp => m_axi_sdram_bresp, m_axi_bvalid => m_axi_sdram_bvalid,
      m_axi_bready => m_axi_sdram_bready,
      m_axi_arid => m_axi_sdram_arid, m_axi_araddr => m_axi_sdram_araddr, m_axi_arlen => m_axi_sdram_arlen,
      m_axi_arsize => m_axi_sdram_arsize, m_axi_arburst => m_axi_sdram_arburst,
      m_axi_arlock => m_axi_sdram_arlock, m_axi_arcache => m_axi_sdram_arcache,
      m_axi_arprot => m_axi_sdram_arprot, m_axi_arqos => m_axi_sdram_arqos,
      m_axi_arvalid => m_axi_sdram_arvalid, m_axi_arready => m_axi_sdram_arready,
      m_axi_rid => m_axi_sdram_rid, m_axi_rdata => m_axi_sdram_rdata, m_axi_rresp => m_axi_sdram_rresp,
      m_axi_rlast => m_axi_sdram_rlast, m_axi_rvalid => m_axi_sdram_rvalid, m_axi_rready => m_axi_sdram_rready,
      axi_error => err_axi);
  end generate;

  -- free-running core clock: clk_master through its BUFG (its generated clocks stay in the
  -- clock group of clk_master in the board constraints)
  g_core_free : if G_FREE_CLK /= 0 generate
    clk_core   <= clk_master;
    ce         <= '1';
    stall      <= '0';
    lag        <= (others => '0');
    sd_dq      <= (others => 'Z');
    err_late   <= '0'; err_mode <= '0'; err_region <= '0'; err_cache <= '0'; err_axi <= '0';
    ev_hit     <= '0'; ev_miss <= '0'; ev_busy <= '0'; ev_drain <= '0'; ev_wfull <= '0'; ev_write <= '0';
    ev_miss_hi <= '0'; ev_miss_vict <= '0'; ev_miss_vict_x <= '0'; ev_miss_seq <= '0'; ev_rd_hi <= '0';
    sd_idle    <= '1';
    m_axi_sdram_awid <= (others => '0'); m_axi_sdram_awaddr <= (others => '0');
    m_axi_sdram_awlen <= (others => '0'); m_axi_sdram_awsize <= "011"; m_axi_sdram_awburst <= "01";
    m_axi_sdram_awlock <= "00"; m_axi_sdram_awcache <= "0011"; m_axi_sdram_awprot <= "000";
    m_axi_sdram_awqos <= "0000"; m_axi_sdram_awvalid <= '0';
    m_axi_sdram_wid <= (others => '0'); m_axi_sdram_wdata <= (others => '0');
    m_axi_sdram_wstrb <= (others => '0'); m_axi_sdram_wlast <= '0'; m_axi_sdram_wvalid <= '0';
    m_axi_sdram_bready <= '1';
    m_axi_sdram_arid <= (others => '0'); m_axi_sdram_araddr <= (others => '0');
    m_axi_sdram_arlen <= (others => '0'); m_axi_sdram_arsize <= "011"; m_axi_sdram_arburst <= "01";
    m_axi_sdram_arlock <= "00"; m_axi_sdram_arcache <= "0011"; m_axi_sdram_arprot <= "000";
    m_axi_sdram_arqos <= "0000"; m_axi_sdram_arvalid <= '0';
    m_axi_sdram_rready <= '1';
  end generate;

  ------------------------------------------------------------------------------
  -- ascal frame buffer: HP1 on clk_100 (ascal's avl_clk = sysmem clock)
  ------------------------------------------------------------------------------
  vbuf_bridge : entity work.avl_axi_bridge
    port map (
      clk => clk_100, rst => rst_100, hold => quiesce, idle => v_idle,
      avl_waitrequest => v_waitrequest, avl_burstcount => v_burstcount, avl_address => v_address,
      avl_read => v_read, avl_readdata => v_readdata, avl_readdatavalid => v_readdatavalid,
      avl_write => v_write, avl_writedata => v_writedata, avl_byteenable => v_byteenable,
      m_axi_awid => m_axi_vbuf_awid, m_axi_awaddr => m_axi_vbuf_awaddr, m_axi_awlen => m_axi_vbuf_awlen,
      m_axi_awsize => m_axi_vbuf_awsize, m_axi_awburst => m_axi_vbuf_awburst,
      m_axi_awlock => m_axi_vbuf_awlock, m_axi_awcache => m_axi_vbuf_awcache,
      m_axi_awprot => m_axi_vbuf_awprot, m_axi_awqos => m_axi_vbuf_awqos,
      m_axi_awvalid => m_axi_vbuf_awvalid, m_axi_awready => m_axi_vbuf_awready,
      m_axi_wid => m_axi_vbuf_wid, m_axi_wdata => m_axi_vbuf_wdata, m_axi_wstrb => m_axi_vbuf_wstrb,
      m_axi_wlast => m_axi_vbuf_wlast, m_axi_wvalid => m_axi_vbuf_wvalid, m_axi_wready => m_axi_vbuf_wready,
      m_axi_bid => m_axi_vbuf_bid, m_axi_bresp => m_axi_vbuf_bresp, m_axi_bvalid => m_axi_vbuf_bvalid,
      m_axi_bready => m_axi_vbuf_bready,
      m_axi_arid => m_axi_vbuf_arid, m_axi_araddr => m_axi_vbuf_araddr, m_axi_arlen => m_axi_vbuf_arlen,
      m_axi_arsize => m_axi_vbuf_arsize, m_axi_arburst => m_axi_vbuf_arburst,
      m_axi_arlock => m_axi_vbuf_arlock, m_axi_arcache => m_axi_vbuf_arcache,
      m_axi_arprot => m_axi_vbuf_arprot, m_axi_arqos => m_axi_vbuf_arqos,
      m_axi_arvalid => m_axi_vbuf_arvalid, m_axi_arready => m_axi_vbuf_arready,
      m_axi_rid => m_axi_vbuf_rid, m_axi_rdata => m_axi_vbuf_rdata, m_axi_rresp => m_axi_vbuf_rresp,
      m_axi_rlast => m_axi_vbuf_rlast, m_axi_rvalid => m_axi_vbuf_rvalid, m_axi_rready => m_axi_vbuf_rready,
      axi_error => v_error);

  ------------------------------------------------------------------------------
  -- DDRAM_* of the core: HP2 on the core's DDRAM_CLK (G_DDRAM = 1), physical addresses
  ------------------------------------------------------------------------------
  ddram_clk <= dd_clk;

  g_ddram_on : if G_DDRAM /= 0 generate
    -- reset and hold into the DDRAM_CLK domain; dd_idle and dd_error go back in the clk_100 process
    process (dd_clk)
    begin
      if rising_edge(dd_clk) then
        dd_rst_s  <= dd_rst_s(0) & rst_100;
        dd_hold_s <= dd_hold_s(0) & quiesce;
      end if;
    end process;

    ddram_bridge : entity work.avl_axi_bridge
      port map (
        clk => dd_clk, rst => dd_rst_s(1), hold => dd_hold_s(1), idle => dd_idle,
        avl_waitrequest => dd_waitrequest, avl_burstcount => dd_burstcount, avl_address => dd_address,
        avl_read => dd_read, avl_readdata => dd_readdata, avl_readdatavalid => dd_readdatavalid,
        avl_write => dd_write, avl_writedata => dd_writedata, avl_byteenable => dd_byteenable,
        m_axi_awid => m_axi_ddram_awid, m_axi_awaddr => m_axi_ddram_awaddr, m_axi_awlen => m_axi_ddram_awlen,
        m_axi_awsize => m_axi_ddram_awsize, m_axi_awburst => m_axi_ddram_awburst,
        m_axi_awlock => m_axi_ddram_awlock, m_axi_awcache => m_axi_ddram_awcache,
        m_axi_awprot => m_axi_ddram_awprot, m_axi_awqos => m_axi_ddram_awqos,
        m_axi_awvalid => m_axi_ddram_awvalid, m_axi_awready => m_axi_ddram_awready,
        m_axi_wid => m_axi_ddram_wid, m_axi_wdata => m_axi_ddram_wdata, m_axi_wstrb => m_axi_ddram_wstrb,
        m_axi_wlast => m_axi_ddram_wlast, m_axi_wvalid => m_axi_ddram_wvalid, m_axi_wready => m_axi_ddram_wready,
        m_axi_bid => m_axi_ddram_bid, m_axi_bresp => m_axi_ddram_bresp, m_axi_bvalid => m_axi_ddram_bvalid,
        m_axi_bready => m_axi_ddram_bready,
        m_axi_arid => m_axi_ddram_arid, m_axi_araddr => m_axi_ddram_araddr, m_axi_arlen => m_axi_ddram_arlen,
        m_axi_arsize => m_axi_ddram_arsize, m_axi_arburst => m_axi_ddram_arburst,
        m_axi_arlock => m_axi_ddram_arlock, m_axi_arcache => m_axi_ddram_arcache,
        m_axi_arprot => m_axi_ddram_arprot, m_axi_arqos => m_axi_ddram_arqos,
        m_axi_arvalid => m_axi_ddram_arvalid, m_axi_arready => m_axi_ddram_arready,
        m_axi_rid => m_axi_ddram_rid, m_axi_rdata => m_axi_ddram_rdata, m_axi_rresp => m_axi_ddram_rresp,
        m_axi_rlast => m_axi_ddram_rlast, m_axi_rvalid => m_axi_ddram_rvalid, m_axi_rready => m_axi_ddram_rready,
        axi_error => dd_error);
  end generate;

  g_ddram_off : if G_DDRAM = 0 generate
    -- the core gets no data (as before HP2): waitrequest 0, read data 0, no valid
    dd_waitrequest   <= '0';
    dd_readdata      <= (others => '0');
    dd_readdatavalid <= '0';
    dd_idle          <= '1';
    dd_error         <= '0';
    m_axi_ddram_awid <= (others => '0'); m_axi_ddram_awaddr <= (others => '0');
    m_axi_ddram_awlen <= (others => '0'); m_axi_ddram_awsize <= "011"; m_axi_ddram_awburst <= "01";
    m_axi_ddram_awlock <= "00"; m_axi_ddram_awcache <= "0011"; m_axi_ddram_awprot <= "000";
    m_axi_ddram_awqos <= "0000"; m_axi_ddram_awvalid <= '0';
    m_axi_ddram_wid <= (others => '0'); m_axi_ddram_wdata <= (others => '0');
    m_axi_ddram_wstrb <= (others => '0'); m_axi_ddram_wlast <= '0'; m_axi_ddram_wvalid <= '0';
    m_axi_ddram_bready <= '1';
    m_axi_ddram_arid <= (others => '0'); m_axi_ddram_araddr <= (others => '0');
    m_axi_ddram_arlen <= (others => '0'); m_axi_ddram_arsize <= "011"; m_axi_ddram_arburst <= "01";
    m_axi_ddram_arlock <= "00"; m_axi_ddram_arcache <= "0011"; m_axi_ddram_arprot <= "000";
    m_axi_ddram_arqos <= "0000"; m_axi_ddram_arvalid <= '0';
    m_axi_ddram_rready <= '1';
  end generate;

  ------------------------------------------------------------------------------
  -- memory port of the core: HP3 on its clock (G_COREMEM = 1), SDRAM image at G_SDRAM_BASE
  ------------------------------------------------------------------------------
  coremem_clk <= cm_clk;

  g_coremem_on : if G_COREMEM /= 0 generate
    -- reset and hold into the coremem_clk domain; cm_idle and cm_error go back in the clk_100 process
    process (cm_clk)
    begin
      if rising_edge(cm_clk) then
        cm_rst_s  <= cm_rst_s(0) & rst_100;
        cm_hold_s <= cm_hold_s(0) & quiesce;
      end if;
    end process;

    coremem_bridge : entity work.avl_axi_bridge
      generic map (G_BYTE_OFFSET => G_SDRAM_BASE)
      port map (
        clk => cm_clk, rst => cm_rst_s(1), hold => cm_hold_s(1), idle => cm_idle,
        avl_waitrequest => cm_waitrequest, avl_burstcount => cm_burstcount, avl_address => cm_address,
        avl_read => cm_read, avl_readdata => cm_readdata, avl_readdatavalid => cm_readdatavalid,
        avl_write => cm_write, avl_writedata => cm_writedata, avl_byteenable => cm_byteenable,
        m_axi_awid => m_axi_coremem_awid, m_axi_awaddr => m_axi_coremem_awaddr, m_axi_awlen => m_axi_coremem_awlen,
        m_axi_awsize => m_axi_coremem_awsize, m_axi_awburst => m_axi_coremem_awburst,
        m_axi_awlock => m_axi_coremem_awlock, m_axi_awcache => m_axi_coremem_awcache,
        m_axi_awprot => m_axi_coremem_awprot, m_axi_awqos => m_axi_coremem_awqos,
        m_axi_awvalid => m_axi_coremem_awvalid, m_axi_awready => m_axi_coremem_awready,
        m_axi_wid => m_axi_coremem_wid, m_axi_wdata => m_axi_coremem_wdata, m_axi_wstrb => m_axi_coremem_wstrb,
        m_axi_wlast => m_axi_coremem_wlast, m_axi_wvalid => m_axi_coremem_wvalid, m_axi_wready => m_axi_coremem_wready,
        m_axi_bid => m_axi_coremem_bid, m_axi_bresp => m_axi_coremem_bresp, m_axi_bvalid => m_axi_coremem_bvalid,
        m_axi_bready => m_axi_coremem_bready,
        m_axi_arid => m_axi_coremem_arid, m_axi_araddr => m_axi_coremem_araddr, m_axi_arlen => m_axi_coremem_arlen,
        m_axi_arsize => m_axi_coremem_arsize, m_axi_arburst => m_axi_coremem_arburst,
        m_axi_arlock => m_axi_coremem_arlock, m_axi_arcache => m_axi_coremem_arcache,
        m_axi_arprot => m_axi_coremem_arprot, m_axi_arqos => m_axi_coremem_arqos,
        m_axi_arvalid => m_axi_coremem_arvalid, m_axi_arready => m_axi_coremem_arready,
        m_axi_rid => m_axi_coremem_rid, m_axi_rdata => m_axi_coremem_rdata, m_axi_rresp => m_axi_coremem_rresp,
        m_axi_rlast => m_axi_coremem_rlast, m_axi_rvalid => m_axi_coremem_rvalid, m_axi_rready => m_axi_coremem_rready,
        axi_error => cm_error);
  end generate;

  g_coremem_off : if G_COREMEM = 0 generate
    -- tied off in sys_top_zynq without MISTER_ZYNQ_COREMEM: answer nothing
    cm_waitrequest   <= '0';
    cm_readdata      <= (others => '0');
    cm_readdatavalid <= '0';
    cm_idle          <= '1';
    cm_error         <= '0';
    m_axi_coremem_awid <= (others => '0'); m_axi_coremem_awaddr <= (others => '0');
    m_axi_coremem_awlen <= (others => '0'); m_axi_coremem_awsize <= "011"; m_axi_coremem_awburst <= "01";
    m_axi_coremem_awlock <= "00"; m_axi_coremem_awcache <= "0011"; m_axi_coremem_awprot <= "000";
    m_axi_coremem_awqos <= "0000"; m_axi_coremem_awvalid <= '0';
    m_axi_coremem_wid <= (others => '0'); m_axi_coremem_wdata <= (others => '0');
    m_axi_coremem_wstrb <= (others => '0'); m_axi_coremem_wlast <= '0'; m_axi_coremem_wvalid <= '0';
    m_axi_coremem_bready <= '1';
    m_axi_coremem_arid <= (others => '0'); m_axi_coremem_araddr <= (others => '0');
    m_axi_coremem_arlen <= (others => '0'); m_axi_coremem_arsize <= "011"; m_axi_coremem_arburst <= "01";
    m_axi_coremem_arlock <= "00"; m_axi_coremem_arcache <= "0011"; m_axi_coremem_arprot <= "000";
    m_axi_coremem_arqos <= "0000"; m_axi_coremem_arvalid <= '0';
    m_axi_coremem_rready <= '1';
  end generate;

  ------------------------------------------------------------------------------
  -- direct video: pixel and serial clock of the transmitter from the core's video clock
  ------------------------------------------------------------------------------
  g_dv_on : if G_DIRECT_VIDEO /= 0 generate
    pll : entity work.video_pll
      generic map (G_CLKIN_PS => G_DV_CLKIN_PS, G_MULT => G_DV_MULT, G_RST_CYCLES => G_DV_RST_CYCLES)
      port map (clk_free => clk_50, clk_in => clk_tx, clk_pix => vid_clk, clk_ser => vid_clk_ser,
                locked => vid_locked);
  end generate;

  g_dv_off : if G_DIRECT_VIDEO = 0 generate
    vid_clk     <= '0';
    vid_clk_ser <= '0';
    vid_locked  <= '0';
  end generate;

  -- one sticky error flag for a board LED (stage C errors are sticky in their blocks); the OR is
  -- registered before the synchronizer, so no glitch of the gates reaches it
  process (clk_master)
  begin
    if rising_edge(clk_master) then
      err_m <= err_late or err_mode or err_region or err_cache or err_axi;
    end if;
  end process;

  process (clk_100)
  begin
    if rising_edge(clk_100) then
      err_s <= err_s(0) & err_m;
    end if;
  end process;
  status_err <= err_s(1) or v_error or dd_err_s(1) or cm_err_s(1);

  -- stage C event counters: events registered (ce and the cache events lie on the critical
  -- path tag RAM -> stall -> BUFGCE CE), snapshot read over hps_bus_axi (quasi-static)
  process (clk_master)
  begin
    if rising_edge(clk_master) then
      perf_ev(0)  <= '1';                                         -- cycles
      perf_ev(1)  <= ce;                                          -- core edges
      perf_ev(2)  <= stall;
      perf_ev(3)  <= not stall and not ce;                        -- pacer has no edge
      perf_ev(4)  <= '0';                                         -- earned edges lost
      if unsigned(lag) = G_PACE_BUCKET then
        perf_ev(4) <= '1';
      end if;
      perf_ev(5)  <= ev_miss;
      perf_ev(6)  <= ev_hit;
      perf_ev(7)  <= ev_busy;
      perf_ev(8)  <= ev_drain;
      perf_ev(9)  <= ev_wfull;
      perf_ev(10) <= ev_write;
      perf_ev(11) <= ev_rd_hi;                                    -- reads in the upper half
      perf_ev(12) <= ev_miss_hi;
      perf_ev(13) <= ev_miss_vict;                                -- miss on the replaced line
      perf_ev(14) <= ev_miss_vict_x;                              -- ... replaced from the other half
      perf_ev(15) <= ev_miss_seq;                                 -- miss on the next line
    end if;
  end process;

  perf : entity work.perf_counters
    generic map (G_N => C_PERF_N, G_WIN_LOG2 => G_PERF_WIN_LOG2)
    port map (clk => clk_master, rst => rst_m, ev => perf_ev, snap => perf_snap);

  -- quiescing: hold to the HP0 bridge, the idle flags back to hps_bus_axi (synchronizes again)
  process (clk_master)
  begin
    if rising_edge(clk_master) then
      sd_hold_s <= sd_hold_s(0) & quiesce;
    end if;
  end process;

  process (clk_100)
  begin
    if rising_edge(clk_100) then
      sd_idle_s <= sd_idle_s(0) & sd_idle;
      dd_idle_s <= dd_idle_s(0) & dd_idle;
      dd_err_s  <= dd_err_s(0) & dd_error;
      cm_idle_s <= cm_idle_s(0) & cm_idle;
      cm_err_s  <= cm_err_s(0) & cm_error;
      hp_idle   <= v_idle and sd_idle_s(1) and dd_idle_s(1) and cm_idle_s(1);
    end if;
  end process;

end architecture rtl;
