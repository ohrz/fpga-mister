-------------------------------------------------------------------------------
-- Title      : Testbench of mister_zynq (wiring of sys_top_zynq to the Zynq parts)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : mister_zynq_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   mister_zynq with the generics of the MSX core profile around a stub of
--   sys_top_zynq (sys_top_zynq_stub.vhd: checks clocks, PLL reconfiguration,
--   SDRAM pins through stage C and the frame buffer port from the inside).
--   AXI3 memory models on m_axi_sdram (master clock) and m_axi_vbuf (clk_100),
--   BUFGCE from the Xilinx unisim library.  The testbench checks:
--     - AXI-Lite: ID register of hps_bus_axi, GPO -> sys_top -> GPI including
--       the sysmem reset (reset_out = PL reset or reset_core_req);
--     - DDR side of the SDRAM image: address G_SDRAM_BASE + word, byte strobes
--       of full and DQMH-masked writes, only DDR-region writes reach HP0; the
--       word is col & row (G_CACHE_COL_HIGH of the MSX profile), row & col in
--       the bench without region;
--     - frame buffer address on HP1 (Avalon word address * 8);
--     - quiescing: CTRL bit 0 sets STATUS bit 2 (both HP bridges idle);
--     - stage C event counters from 0x10: consistent snapshot, cycles = window,
--       edges + stall + pacer wait = cycles; aux words are read only;
--     - video in rgb2dvi order (R, B, G) with DE/HS/VS, I2S bits and MCLK,
--       KEY (active low) and SW through LED, no stage C error; then SW = 0101
--       makes the stub write an unsupported SDRAM mode, which must show up as
--       status_err.
--     - DDRAM_* (G_DDRAM = 1): ddram_clk = the core's DDRAM_CLK (same edges),
--       HP2 memory model on it, physical address DD_ADDR * 8 of the first burst, the
--       burst split at the 4 KB boundary and after 16 beats (3 write bursts
--       with the byte-masked single write), the stub checks the read data;
--       quiescing while the stub's DDRAM read is open: STATUS bit 2 stays 0
--       until the read has returned.
--   G_REGION = false (bench mister_zynq_noreg_tb) runs mister_zynq without
--   the BRAM region (G_B0_BITS = 0, profile of the menu core): all six writes of
--   both columns must reach HP0, and the stub's read checks then read both
--   columns back from DDR through the cache; and with G_DDRAM = 0: the stub's
--   DDRAM read is accepted and never answered, HP2 stays silent.
--   G_FREE = true (bench mister_zynq_free_tb, with G_DDRAM and G_COREMEM: the
--   N64 profile) runs mister_zynq with G_FREE_CLK = 1: the stub sees the free
--   master clock (every period T_MASTER) and an SDRAM read nobody answers, HP0
--   stays silent, the perf counters count an edge every cycle, an unsupported
--   SDRAM mode sets no error.  G_COREMEM: coremem_clk = the stub's COREMEM
--   clock, HP3 address G_SDRAM_BASE + CM_ADDR * 8, the 2-beat burst split at
--   4 KB, quiescing while the COREMEM read is open; without it HP3 is silent.
--   G_DIRECT (also in mister_zynq_free_tb): the stub's HDMI_TX_* run on its
--   CLK_VIDEO (T_VIDEO), video_pll must lock and the video pattern must come
--   with one pixel per vid_clk; without it vid_clk, vid_clk_ser and vid_locked
--   stay 0.
--   G_HP_ERR (mister_zynq_hp2err_tb, mister_zynq_hp3err_tb, N64 profile): every
--   read beat of HP2 (1) or HP3 (2) comes back as SLVERR: the
--   read must still finish with its data and quiescing must still work,
--   status_err is 0 before and 1 after it (the bridge's sticky axi_error
--   through the clk_100 synchroniser).
--   Ends with "PASS" or a failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mister_zynq_tb_pkg.all;

entity mister_zynq_tb is
  generic (G_REGION : boolean := true; G_DDRAM : boolean := true; G_FREE : boolean := false;
           G_COREMEM : boolean := false; G_DIRECT : boolean := false; G_HP_ERR : natural := 0);
end entity;

architecture tb of mister_zynq_tb is

  signal clk_100, clk_50, clk_master, clk_hdmi, clk_audio : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal done    : boolean := false;

  signal awaddr, araddr : std_logic_vector(6 downto 0) := (others => '0');
  signal awvalid, awready, wvalid, wready, bvalid, bready : std_logic := '0';
  signal arvalid, arready, rvalid, rready : std_logic := '0';
  signal wdata, rdata : std_logic_vector(31 downto 0) := (others => '0');
  signal bresp, rresp : std_logic_vector(1 downto 0);

  -- AXI3 ports (one record of signals per port would hide nothing here)
  signal s_awaddr, s_araddr, v_awaddr, v_araddr : std_logic_vector(31 downto 0);
  signal s_awlen, s_arlen, v_awlen, v_arlen : std_logic_vector(3 downto 0);
  signal s_awsize, s_arsize, v_awsize, v_arsize : std_logic_vector(2 downto 0);
  signal s_awburst, s_arburst, v_awburst, v_arburst : std_logic_vector(1 downto 0);
  signal s_awvalid, s_awready, s_wlast, s_wvalid, s_wready, s_bvalid, s_bready : std_logic;
  signal s_arvalid, s_arready, s_rlast, s_rvalid, s_rready : std_logic;
  signal v_awvalid, v_awready, v_wlast, v_wvalid, v_wready, v_bvalid, v_bready : std_logic;
  signal v_arvalid, v_arready, v_rlast, v_rvalid, v_rready : std_logic;
  signal s_wdata, s_rdata, v_wdata, v_rdata : std_logic_vector(63 downto 0);
  signal s_wstrb, v_wstrb : std_logic_vector(7 downto 0);
  signal ddram_clk, dd_clk_tb : std_logic;
  signal d_awaddr, d_araddr : std_logic_vector(31 downto 0);
  signal d_awlen, d_arlen : std_logic_vector(3 downto 0);
  signal d_awsize, d_arsize : std_logic_vector(2 downto 0);
  signal d_awburst, d_arburst : std_logic_vector(1 downto 0);
  signal d_awvalid, d_awready, d_wlast, d_wvalid, d_wready, d_bvalid, d_bready : std_logic;
  signal d_arvalid, d_arready, d_rlast, d_rvalid, d_rready : std_logic;
  -- read responses of HP2/HP3: SLVERR on every beat with G_HP_ERR 1/2
  signal d_rresp : std_logic_vector(1 downto 0) := "00";
  signal c_rresp : std_logic_vector(1 downto 0) := "00";
  signal d_wdata, d_rdata : std_logic_vector(63 downto 0);
  signal d_wstrb : std_logic_vector(7 downto 0);
  signal dd_aw_n, dd_ar_n : natural := 0;
  signal coremem_clk, cm_clk_tb : std_logic;
  signal c_awaddr, c_araddr : std_logic_vector(31 downto 0);
  signal c_awlen, c_arlen : std_logic_vector(3 downto 0);
  signal c_awsize, c_arsize : std_logic_vector(2 downto 0);
  signal c_awburst, c_arburst : std_logic_vector(1 downto 0);
  signal c_awvalid, c_awready, c_wlast, c_wvalid, c_wready, c_bvalid, c_bready : std_logic;
  signal c_arvalid, c_arready, c_rlast, c_rvalid, c_rready : std_logic;
  signal c_wdata, c_rdata : std_logic_vector(63 downto 0);
  signal c_wstrb : std_logic_vector(7 downto 0);
  signal cm_aw_n, cm_ar_n : natural := 0;

  signal vid_data : std_logic_vector(23 downto 0);
  signal vid_de, vid_hs, vid_vs : std_logic;
  signal vid_clk, vid_clk_ser, vid_locked : std_logic;
  signal video_done : boolean := false;
  signal i2s_mclk, i2s_bclk, i2s_lrclk, i2s_data : std_logic;
  signal btn_osd  : std_logic := '0';
  signal btn_user : std_logic := '1';
  signal sw       : std_logic_vector(3 downto 0) := "1010";
  signal led      : std_logic_vector(7 downto 0);
  signal status_err : std_logic;

  -- DDR-side writes of the SDRAM image (monitor)
  signal sd_aw_n, sd_w_n, vb_aw_n : natural := 0;

  -- SDRAM writes expected on HP0: the DDR-region column only, or both columns without region
  -- (none with G_FREE: stage C is off)
  constant N_SD_COLS : natural := 2 - boolean'pos(G_REGION);
  constant N_SD_EXP  : natural := 3 * N_SD_COLS * (1 - boolean'pos(G_FREE));
  constant B0_BITS   : natural := P_B0_BITS * boolean'pos(G_REGION);
  constant COL_HIGH  : natural := P_COL_HIGH * boolean'pos(G_REGION);

  -- cache and DDR word of bank 0, row r, column c (9 column bits, 13 row bits)
  function ddr_word(r, c : natural) return natural is
  begin
    if COL_HIGH /= 0 then
      return c * 2 ** 13 + r;
    else
      return r * 2 ** 9 + c;
    end if;
  end function;

begin

  d_rresp <= "10" when G_HP_ERR = 1 else "00";
  c_rresp <= "10" when G_HP_ERR = 2 else "00";

  ------------------------------------------------------------------------------
  -- clocks, reset, watchdog
  ------------------------------------------------------------------------------
  clk_100    <= not clk_100 after T_100 / 2 when not done;
  clk_50     <= not clk_50 after T_50 / 2 when not done;
  clk_master <= not clk_master after T_MASTER / 2 when not done;
  clk_hdmi   <= not clk_hdmi after T_HDMI / 2 when not done;
  clk_audio  <= not clk_audio after T_AUDIO / 2 when not done;
  vd_mode    <= '1' when G_DIRECT else '0';
  vd_clk_src <= not vd_clk_src after T_VIDEO / 2 when not done and G_DIRECT;

  watchdog : process
  begin
    wait for 1 ms;
    assert done report "timeout" severity failure;
    wait;
  end process;

  ------------------------------------------------------------------------------
  -- DUT
  ------------------------------------------------------------------------------
  dut : entity work.mister_zynq
    generic map (
      G_B0_MASK => P_B0_MASK, G_B0_MATCH => P_B0_MATCH, G_B0_SEL => P_B0_SEL, G_B0_BITS => B0_BITS,
      G_CACHE_COL_HIGH => COL_HIGH, G_SDRAM_BASE => P_BASE, G_PACE_NUM => 21, G_PACE_DEN => 22,
      G_DDRAM => boolean'pos(G_DDRAM), G_FREE_CLK => boolean'pos(G_FREE), G_COREMEM => boolean'pos(G_COREMEM),
      G_DIRECT_VIDEO => boolean'pos(G_DIRECT), G_DV_CLKIN_PS => T_VIDEO / 1 ps, G_DV_MULT => 20,
      G_DV_RST_CYCLES => 64, G_PERF_WIN_LOG2 => 10)
    port map (
      clk_100 => clk_100, aresetn => aresetn, clk_50 => clk_50, clk_master => clk_master, clk_master_gate => clk_master,
      clk_hdmi => clk_hdmi, clk_audio => clk_audio,
      s_axi_awaddr => awaddr, s_axi_awprot => "000", s_axi_awvalid => awvalid, s_axi_awready => awready,
      s_axi_wdata => wdata, s_axi_wstrb => "1111", s_axi_wvalid => wvalid, s_axi_wready => wready,
      s_axi_bresp => bresp, s_axi_bvalid => bvalid, s_axi_bready => bready,
      s_axi_araddr => araddr, s_axi_arprot => "000", s_axi_arvalid => arvalid, s_axi_arready => arready,
      s_axi_rdata => rdata, s_axi_rresp => rresp, s_axi_rvalid => rvalid, s_axi_rready => rready,
      m_axi_sdram_awid => open, m_axi_sdram_awaddr => s_awaddr, m_axi_sdram_awlen => s_awlen,
      m_axi_sdram_awsize => s_awsize, m_axi_sdram_awburst => s_awburst, m_axi_sdram_awlock => open,
      m_axi_sdram_awcache => open, m_axi_sdram_awprot => open, m_axi_sdram_awqos => open,
      m_axi_sdram_awvalid => s_awvalid, m_axi_sdram_awready => s_awready,
      m_axi_sdram_wid => open, m_axi_sdram_wdata => s_wdata, m_axi_sdram_wstrb => s_wstrb,
      m_axi_sdram_wlast => s_wlast, m_axi_sdram_wvalid => s_wvalid, m_axi_sdram_wready => s_wready,
      m_axi_sdram_bid => (others => '0'), m_axi_sdram_bresp => "00", m_axi_sdram_bvalid => s_bvalid,
      m_axi_sdram_bready => s_bready,
      m_axi_sdram_arid => open, m_axi_sdram_araddr => s_araddr, m_axi_sdram_arlen => s_arlen,
      m_axi_sdram_arsize => s_arsize, m_axi_sdram_arburst => s_arburst, m_axi_sdram_arlock => open,
      m_axi_sdram_arcache => open, m_axi_sdram_arprot => open, m_axi_sdram_arqos => open,
      m_axi_sdram_arvalid => s_arvalid, m_axi_sdram_arready => s_arready,
      m_axi_sdram_rid => (others => '0'), m_axi_sdram_rdata => s_rdata, m_axi_sdram_rresp => "00",
      m_axi_sdram_rlast => s_rlast, m_axi_sdram_rvalid => s_rvalid, m_axi_sdram_rready => s_rready,
      m_axi_vbuf_awid => open, m_axi_vbuf_awaddr => v_awaddr, m_axi_vbuf_awlen => v_awlen,
      m_axi_vbuf_awsize => v_awsize, m_axi_vbuf_awburst => v_awburst, m_axi_vbuf_awlock => open,
      m_axi_vbuf_awcache => open, m_axi_vbuf_awprot => open, m_axi_vbuf_awqos => open,
      m_axi_vbuf_awvalid => v_awvalid, m_axi_vbuf_awready => v_awready,
      m_axi_vbuf_wid => open, m_axi_vbuf_wdata => v_wdata, m_axi_vbuf_wstrb => v_wstrb,
      m_axi_vbuf_wlast => v_wlast, m_axi_vbuf_wvalid => v_wvalid, m_axi_vbuf_wready => v_wready,
      m_axi_vbuf_bid => (others => '0'), m_axi_vbuf_bresp => "00", m_axi_vbuf_bvalid => v_bvalid,
      m_axi_vbuf_bready => v_bready,
      m_axi_vbuf_arid => open, m_axi_vbuf_araddr => v_araddr, m_axi_vbuf_arlen => v_arlen,
      m_axi_vbuf_arsize => v_arsize, m_axi_vbuf_arburst => v_arburst, m_axi_vbuf_arlock => open,
      m_axi_vbuf_arcache => open, m_axi_vbuf_arprot => open, m_axi_vbuf_arqos => open,
      m_axi_vbuf_arvalid => v_arvalid, m_axi_vbuf_arready => v_arready,
      m_axi_vbuf_rid => (others => '0'), m_axi_vbuf_rdata => v_rdata, m_axi_vbuf_rresp => "00",
      m_axi_vbuf_rlast => v_rlast, m_axi_vbuf_rvalid => v_rvalid, m_axi_vbuf_rready => v_rready,
      ddram_clk => ddram_clk,
      m_axi_ddram_awid => open, m_axi_ddram_awaddr => d_awaddr, m_axi_ddram_awlen => d_awlen,
      m_axi_ddram_awsize => d_awsize, m_axi_ddram_awburst => d_awburst, m_axi_ddram_awlock => open,
      m_axi_ddram_awcache => open, m_axi_ddram_awprot => open, m_axi_ddram_awqos => open,
      m_axi_ddram_awvalid => d_awvalid, m_axi_ddram_awready => d_awready,
      m_axi_ddram_wid => open, m_axi_ddram_wdata => d_wdata, m_axi_ddram_wstrb => d_wstrb,
      m_axi_ddram_wlast => d_wlast, m_axi_ddram_wvalid => d_wvalid, m_axi_ddram_wready => d_wready,
      m_axi_ddram_bid => (others => '0'), m_axi_ddram_bresp => "00", m_axi_ddram_bvalid => d_bvalid,
      m_axi_ddram_bready => d_bready,
      m_axi_ddram_arid => open, m_axi_ddram_araddr => d_araddr, m_axi_ddram_arlen => d_arlen,
      m_axi_ddram_arsize => d_arsize, m_axi_ddram_arburst => d_arburst, m_axi_ddram_arlock => open,
      m_axi_ddram_arcache => open, m_axi_ddram_arprot => open, m_axi_ddram_arqos => open,
      m_axi_ddram_arvalid => d_arvalid, m_axi_ddram_arready => d_arready,
      m_axi_ddram_rid => (others => '0'), m_axi_ddram_rdata => d_rdata, m_axi_ddram_rresp => d_rresp,
      m_axi_ddram_rlast => d_rlast, m_axi_ddram_rvalid => d_rvalid, m_axi_ddram_rready => d_rready,
      coremem_clk => coremem_clk,
      m_axi_coremem_awid => open, m_axi_coremem_awaddr => c_awaddr, m_axi_coremem_awlen => c_awlen,
      m_axi_coremem_awsize => c_awsize, m_axi_coremem_awburst => c_awburst, m_axi_coremem_awlock => open,
      m_axi_coremem_awcache => open, m_axi_coremem_awprot => open, m_axi_coremem_awqos => open,
      m_axi_coremem_awvalid => c_awvalid, m_axi_coremem_awready => c_awready,
      m_axi_coremem_wid => open, m_axi_coremem_wdata => c_wdata, m_axi_coremem_wstrb => c_wstrb,
      m_axi_coremem_wlast => c_wlast, m_axi_coremem_wvalid => c_wvalid, m_axi_coremem_wready => c_wready,
      m_axi_coremem_bid => (others => '0'), m_axi_coremem_bresp => "00", m_axi_coremem_bvalid => c_bvalid,
      m_axi_coremem_bready => c_bready,
      m_axi_coremem_arid => open, m_axi_coremem_araddr => c_araddr, m_axi_coremem_arlen => c_arlen,
      m_axi_coremem_arsize => c_arsize, m_axi_coremem_arburst => c_arburst, m_axi_coremem_arlock => open,
      m_axi_coremem_arcache => open, m_axi_coremem_arprot => open, m_axi_coremem_arqos => open,
      m_axi_coremem_arvalid => c_arvalid, m_axi_coremem_arready => c_arready,
      m_axi_coremem_rid => (others => '0'), m_axi_coremem_rdata => c_rdata, m_axi_coremem_rresp => c_rresp,
      m_axi_coremem_rlast => c_rlast, m_axi_coremem_rvalid => c_rvalid, m_axi_coremem_rready => c_rready,
      vid_data => vid_data, vid_de => vid_de, vid_hs => vid_hs, vid_vs => vid_vs,
      vid_clk => vid_clk, vid_clk_ser => vid_clk_ser, vid_locked => vid_locked,
      i2s_mclk => i2s_mclk, i2s_bclk => i2s_bclk, i2s_lrclk => i2s_lrclk, i2s_data => i2s_data,
      btn_osd => btn_osd, btn_user => btn_user, sw => sw, led => led, status_err => status_err);

  sdram_ddr : entity work.axi3_mem_model
    generic map (G_WORD_BITS => 14, G_RD_LAT => 20, G_SEED => 31)
    port map (
      clk => clk_master,
      awaddr => s_awaddr, awlen => s_awlen, awsize => s_awsize, awburst => s_awburst, awvalid => s_awvalid,
      awready => s_awready, wdata => s_wdata, wstrb => s_wstrb, wlast => s_wlast, wvalid => s_wvalid,
      wready => s_wready, bvalid => s_bvalid, bready => s_bready,
      araddr => s_araddr, arlen => s_arlen, arsize => s_arsize, arburst => s_arburst, arvalid => s_arvalid,
      arready => s_arready, rdata => s_rdata, rlast => s_rlast, rvalid => s_rvalid, rready => s_rready);

  vbuf_ddr : entity work.axi3_mem_model
    generic map (G_WORD_BITS => 14, G_RD_LAT => 10, G_SEED => 37)
    port map (
      clk => clk_100,
      awaddr => v_awaddr, awlen => v_awlen, awsize => v_awsize, awburst => v_awburst, awvalid => v_awvalid,
      awready => v_awready, wdata => v_wdata, wstrb => v_wstrb, wlast => v_wlast, wvalid => v_wvalid,
      wready => v_wready, bvalid => v_bvalid, bready => v_bready,
      araddr => v_araddr, arlen => v_arlen, arsize => v_arsize, arburst => v_arburst, arvalid => v_arvalid,
      arready => v_arready, rdata => v_rdata, rlast => v_rlast, rvalid => v_rvalid, rready => v_rready);

  -- HP2: clocked by the DDRAM_CLK mister_zynq exports; a long read latency keeps the stub's
  -- read open while the testbench quiesces
  ddram_ddr : entity work.axi3_mem_model
    generic map (G_WORD_BITS => 14, G_RD_LAT => 300, G_SEED => 41)
    port map (
      clk => dd_clk_tb,
      awaddr => d_awaddr, awlen => d_awlen, awsize => d_awsize, awburst => d_awburst, awvalid => d_awvalid,
      awready => d_awready, wdata => d_wdata, wstrb => d_wstrb, wlast => d_wlast, wvalid => d_wvalid,
      wready => d_wready, bvalid => d_bvalid, bready => d_bready,
      araddr => d_araddr, arlen => d_arlen, arsize => d_arsize, arburst => d_arburst, arvalid => d_arvalid,
      arready => d_arready, rdata => d_rdata, rlast => d_rlast, rvalid => d_rvalid, rready => d_rready);

  -- HP3: COREMEM, clocked by the core's memory clock mister_zynq exports
  coremem_ddr : entity work.axi3_mem_model
    generic map (G_WORD_BITS => 14, G_RD_LAT => 300, G_SEED => 43)
    port map (
      clk => cm_clk_tb,
      awaddr => c_awaddr, awlen => c_awlen, awsize => c_awsize, awburst => c_awburst, awvalid => c_awvalid,
      awready => c_awready, wdata => c_wdata, wstrb => c_wstrb, wlast => c_wlast, wvalid => c_wvalid,
      wready => c_wready, bvalid => c_bvalid, bready => c_bready,
      araddr => c_araddr, arlen => c_arlen, arsize => c_arsize, arburst => c_arburst, arvalid => c_arvalid,
      arready => c_arready, rdata => c_rdata, rlast => c_rlast, rvalid => c_rvalid, rready => c_rready);

  cm_mode <= '1' when G_COREMEM else '0';
  cm_clk_src <= not cm_clk_src after T_COREMEM / 2 when not done;
  cm_clk_tb  <= cm_clk_src;

  cm_clk_out : process
  begin
    wait until rising_edge(coremem_clk);
    assert cm_clk_src = '1' and cm_clk_src'last_event = 0 ns report "coremem_clk is not the core's memory clock"
      severity failure;
  end process;

  cm_mon : process
    variable na, nr : natural := 0;
  begin
    wait until rising_edge(cm_clk_tb);
    if c_awvalid = '1' and c_awready = '1' then
      if na = 0 then
        assert unsigned(c_awaddr) = unsigned(P_BASE) + unsigned(CM_ADDR) * 8 report "HP3 write address " &
          to_hstring(c_awaddr) severity failure;
      end if;
      na := na + 1;
    end if;
    if c_arvalid = '1' and c_arready = '1' then
      nr := nr + 1;
    end if;
    cm_aw_n <= na; cm_ar_n <= nr;
  end process;

  dd_mode <= '1' when G_DDRAM else '0';
  free_mode <= '1' when G_FREE else '0';
  dd_clk_src <= not dd_clk_src after T_DDRAM / 2 when not done;
  dd_clk_tb  <= dd_clk_src;

  -- mister_zynq exports the core's DDRAM_CLK (the block design clocks HP2 with it)
  dd_clk_out : process
  begin
    wait until rising_edge(ddram_clk);
    assert dd_clk_src = '1' and dd_clk_src'last_event = 0 ns report "ddram_clk is not the core's DDRAM_CLK"
      severity failure;
  end process;

  dd_mon : process
    variable na, nr : natural := 0;
  begin
    wait until rising_edge(dd_clk_tb);
    if d_awvalid = '1' and d_awready = '1' then
      if na = 0 then
        assert unsigned(d_awaddr) = unsigned(DD_ADDR) * 8 report "HP2 write address " & to_hstring(d_awaddr)
          severity failure;
      end if;
      na := na + 1;
    end if;
    if d_arvalid = '1' and d_arready = '1' then
      nr := nr + 1;
    end if;
    dd_aw_n <= na; dd_ar_n <= nr;
  end process;

  ------------------------------------------------------------------------------
  -- DDR side of the SDRAM image: the three writes to the DDR-region column
  -- (W1 full, W2 lower byte, W3 full to the next column), nothing else; without
  -- region the same three to the BRAM-region column first
  ------------------------------------------------------------------------------
  sd_mon : process
    type exp_t is record
      word : natural;
      strb : std_logic_vector(1 downto 0);
      data : std_logic_vector(15 downto 0);
    end record;
    type exp_array is array (natural range <>) of exp_t;
    impure function expected return exp_array is
      variable e : exp_array(0 to N_SD_EXP - 1);
      variable w : natural;
    begin
      for c in 0 to N_SD_EXP / 3 - 1 loop
        w := SD_COLS(c + 2 - N_SD_COLS);
        e(3 * c to 3 * c + 2) := ((ddr_word(SD_ROW, w), "11", SD_W1), (ddr_word(SD_ROW, w), "01", SD_W2),
                                  (ddr_word(SD_ROW, w + 1), "11", SD_W3));
      end loop;
      return e;
    end function;
    constant EXP : exp_array := expected;
    variable na, nw, lane : natural := 0;
    variable a : unsigned(31 downto 0);
  begin
    wait until rising_edge(clk_master);
    if s_awvalid = '1' and s_awready = '1' then
      assert na <= EXP'high report "more SDRAM writes on HP0 than the DDR region got" severity failure;
      a := unsigned(P_BASE) + to_unsigned((EXP(na).word / 4) * 8, 32);
      assert unsigned(s_awaddr) = a report "HP0 write " & integer'image(na) & ": address " & to_hstring(s_awaddr) &
        ", expected " & to_hstring(a) severity failure;
      na := na + 1;
    end if;
    if s_wvalid = '1' and s_wready = '1' then
      assert nw <= EXP'high report "more SDRAM write beats on HP0 than expected" severity failure;
      lane := EXP(nw).word mod 4;
      for l in 0 to 3 loop
        if l = lane then
          assert s_wstrb(2 * l + 1 downto 2 * l) = EXP(nw).strb report "HP0 write " & integer'image(nw) &
            ": strobes " & to_hstring(s_wstrb) severity failure;
          assert s_wdata(16 * l + 7 downto 16 * l) = EXP(nw).data(7 downto 0) and
            (EXP(nw).strb(1) = '0' or s_wdata(16 * l + 15 downto 16 * l + 8) = EXP(nw).data(15 downto 8))
            report "HP0 write " & integer'image(nw) & ": data " & to_hstring(s_wdata) severity failure;
        else
          assert s_wstrb(2 * l + 1 downto 2 * l) = "00" report "HP0 write " & integer'image(nw) &
            ": strobes " & to_hstring(s_wstrb) severity failure;
        end if;
      end loop;
      nw := nw + 1;
    end if;
    assert s_arvalid /= '1' or not G_FREE report "HP0 read with G_FREE_CLK" severity failure;
    sd_aw_n <= na; sd_w_n <= nw;
  end process;

  vb_mon : process
    variable n : natural := 0;
  begin
    wait until rising_edge(clk_100);
    if v_awvalid = '1' and v_awready = '1' then
      assert unsigned(v_awaddr) = unsigned(VB_ADDR) * 8 report "HP1 write address " & to_hstring(v_awaddr)
        severity failure;
      n := n + 1;
      vb_aw_n <= n;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- video (rgb2dvi order R, B, G) and audio patterns of the stub
  ------------------------------------------------------------------------------
  video : process
    variable r, prev : unsigned(7 downto 0);
  begin
    wait for 2 us;
    if G_DIRECT then
      -- direct video: the stub's video runs on CLK_VIDEO, the transmitter clock comes from video_pll
      if vid_locked /= '1' then
        wait until vid_locked = '1' for 100 us;
      end if;
      assert vid_locked = '1' report "direct video: video_pll does not lock" severity failure;
      wait for 1 us;
    else
      assert vid_locked = '0' and vid_clk = '0' and vid_clk_ser = '0'
        report "vid_clk/vid_clk_ser/vid_locked without G_DIRECT_VIDEO" severity failure;
    end if;
    for i in 0 to 63 loop
      if G_DIRECT then
        wait until falling_edge(vid_clk);
      else
        wait until falling_edge(clk_hdmi);
      end if;
      r := unsigned(vid_data(23 downto 16));
      assert unsigned(vid_data(7 downto 0)) = r + 1 and unsigned(vid_data(15 downto 8)) = r + 2
        report "video: " & to_hstring(vid_data) & " is not R, B = R + 2, G = R + 1" severity failure;
      assert vid_de = r(0) and vid_hs = r(1) and vid_vs = r(2) report "video: DE/HS/VS" severity failure;
      assert i = 0 or r = prev + 1 report "video: not one pixel per pixel clock" severity failure;
      prev := r;
    end loop;
    video_done <= true;
    wait;
  end process;

  audio : process
    variable v, prev : unsigned(2 downto 0);
  begin
    wait for 2 us;
    for i in 0 to 31 loop
      wait until falling_edge(clk_audio);
      wait for 1 ns;
      v := i2s_data & i2s_lrclk & i2s_bclk;
      assert i = 0 or v = prev + 1 report "I2S: data/lrclk/bclk out of order" severity failure;
      assert i2s_mclk = '0' report "I2S: MCLK is not the audio clock" severity failure;
      prev := v;
      wait until rising_edge(clk_audio);
      wait for 1 ns;
      assert i2s_mclk = '1' report "I2S: MCLK is not the audio clock" severity failure;
    end loop;
    wait;
  end process;

  ------------------------------------------------------------------------------
  -- AXI-Lite master: hps_bus_axi
  ------------------------------------------------------------------------------
  main : process

    procedure axil_write(a : natural; d : std_logic_vector(31 downto 0)) is
      variable aw_ok, w_ok : boolean := false;
    begin
      awaddr <= std_logic_vector(to_unsigned(a, 7)); awvalid <= '1'; wdata <= d; wvalid <= '1'; bready <= '1';
      while not (aw_ok and w_ok) loop
        wait until rising_edge(clk_100);
        if awvalid = '1' and awready = '1' then awvalid <= '0'; aw_ok := true; end if;
        if wvalid = '1' and wready = '1' then wvalid <= '0'; w_ok := true; end if;
      end loop;
      loop
        wait until rising_edge(clk_100);
        exit when bvalid = '1';
      end loop;
      bready <= '0';
      assert bresp = "00" report "AXI-Lite write response " & to_string(bresp) severity failure;
    end procedure;

    procedure axil_read(a : natural; d : out std_logic_vector(31 downto 0)) is
    begin
      araddr <= std_logic_vector(to_unsigned(a, 7)); arvalid <= '1'; rready <= '1';
      loop
        wait until rising_edge(clk_100);
        if arready = '1' then arvalid <= '0'; end if;
        exit when rvalid = '1';
      end loop;
      d := rdata;
      rready <= '0';
    end procedure;

    procedure gp_check(v : std_logic_vector(31 downto 0)) is
      variable d, e : std_logic_vector(31 downto 0);
    begin
      axil_write(16#0#, v);
      axil_read(16#4#, d);
      e := '0' & v(30) & not v(29 downto 0);
      assert d = e report "GPI " & to_hstring(d) & " after GPO " & to_hstring(v) & ", expected " & to_hstring(e)
        severity failure;
    end procedure;

    variable d : std_logic_vector(31 downto 0);
    variable seq : std_logic_vector(31 downto 0);
    type perf_t is array (0 to 15) of natural;
    variable pc : perf_t;
    variable n : natural;
  begin
    aresetn <= '0';
    for i in 1 to 20 loop wait until rising_edge(clk_100); end loop;
    aresetn <= '1';
    for i in 1 to 50 loop wait until rising_edge(clk_100); end loop;

    axil_read(16#8#, d);
    assert d = x"5A4D5354" report "ID register " & to_hstring(d) severity failure;
    gp_check(x"12345678");
    gp_check(x"4ABCDEF0");                          -- reset_core_req: sysmem reset_out = 1
    gp_check(x"8000A5A5");

    -- the stub's SDRAM and frame buffer sequences
    if led(1 downto 0) /= "11" then
      wait until led(1 downto 0) = "11" for 500 us;
    end if;
    assert led(1 downto 0) = "11" report "stub sequences did not finish: LED " & to_hstring(led)
      severity failure;
    for i in 1 to 100 loop wait until rising_edge(clk_master); end loop;
    assert sd_aw_n = N_SD_EXP and sd_w_n = N_SD_EXP report "HP0 writes: " & integer'image(sd_aw_n) &
      " addresses, " & integer'image(sd_w_n) & " beats, expected " & integer'image(N_SD_EXP) severity failure;
    assert vb_aw_n = 1 report "HP1 write bursts: " & integer'image(vb_aw_n) severity failure;
    assert led(7 downto 2) = "01" & "1010" report "KEY/SW through LED: " & to_hstring(led) severity failure;
    assert status_err = '0' report "stage C error flag" severity failure;

    -- DDRAM: quiesce while the stub's read burst is open, STATUS bit 2 only after its data
    if G_DDRAM then
      if dd_reading /= '1' then
        wait until dd_reading = '1' for 100 us;
      end if;
      assert dd_reading = '1' report "stub DDRAM read did not start (HP2 AW " & integer'image(dd_aw_n) & ", AR " & integer'image(dd_ar_n) & ")" severity failure;
      axil_write(16#C#, x"00000001");
      wait for 500 ns;                       -- longer than the hold/idle synchronisers
      axil_read(16#C#, d);
      assert d(2) = '0' report "STATUS bit 2 while a DDRAM read is open " & to_hstring(d) severity failure;
      assert dd_done = '0' report "DDRAM read finished before the STATUS check (bench timing)" severity failure;
      if dd_done /= '1' then
        wait until dd_done = '1' for 100 us;
      end if;
      wait for 1 us;
      axil_read(16#C#, d);
      assert d(3 downto 2) = "11" report "STATUS after the DDRAM read " & to_hstring(d) severity failure;
      axil_write(16#C#, x"00000000");
      assert status_err = '1' or G_HP_ERR /= 1 report "HP2 error response not on status_err" severity failure;
      assert dd_aw_n = 3 and dd_ar_n = 2 report "HP2 bursts: " & integer'image(dd_aw_n) & " AW, " &
        integer'image(dd_ar_n) & " AR, expected 3 and 2" severity failure;
    else
      if dd_done /= '1' then
        wait until dd_done = '1' for 100 us;
      end if;
      assert dd_done = '1' report "stub DDRAM tie-off check did not finish" severity failure;
      assert dd_aw_n = 0 and dd_ar_n = 0 report "HP2 active without G_DDRAM" severity failure;
    end if;

    -- COREMEM: as DDRAM, quiesce while the stub's read is open
    if G_COREMEM then
      if cm_reading /= '1' then
        wait until cm_reading = '1' for 100 us;
      end if;
      assert cm_reading = '1' report "stub COREMEM read did not start (HP3 AW " & integer'image(cm_aw_n) &
        ", AR " & integer'image(cm_ar_n) & ")" severity failure;
      axil_write(16#C#, x"00000001");
      wait for 500 ns;
      axil_read(16#C#, d);
      assert d(2) = '0' report "STATUS bit 2 while a COREMEM read is open " & to_hstring(d) severity failure;
      assert cm_done = '0' report "COREMEM read finished before the STATUS check (bench timing)" severity failure;
      if cm_done /= '1' then
        wait until cm_done = '1' for 100 us;
      end if;
      wait for 1 us;
      axil_read(16#C#, d);
      assert d(3 downto 2) = "11" report "STATUS after the COREMEM read " & to_hstring(d) severity failure;
      axil_write(16#C#, x"00000000");
      assert status_err = '1' or G_HP_ERR /= 2 report "HP3 error response not on status_err" severity failure;
      assert cm_aw_n = 2 and cm_ar_n = 2 report "HP3 bursts: " & integer'image(cm_aw_n) & " AW, " &
        integer'image(cm_ar_n) & " AR, expected 2 and 2" severity failure;
    else
      assert cm_aw_n = 0 and cm_ar_n = 0 report "HP3 active without G_COREMEM" severity failure;
    end if;

    -- quiescing (all bridges idle after the sequences): CTRL bit 0 -> STATUS bit 2, no HP request
    axil_write(16#C#, x"00000001");
    wait for 1 us;
    axil_read(16#C#, d);
    assert d(3 downto 2) = "11" report "STATUS with quiesce " & to_hstring(d) severity failure;
    axil_write(16#C#, x"00000000");
    wait for 1 us;
    axil_read(16#C#, d);
    assert d(3 downto 2) = "00" report "STATUS after quiesce " & to_hstring(d) severity failure;

    -- stage C event counters as aux words (window 2**10 master cycles): a consistent snapshot
    -- (seq unchanged around it), cycles = window, every cycle exactly one of edge, stall, pacer wait
    n := 0;
    loop
      axil_read(16#10#, seq);
      for i in 0 to 15 loop
        axil_read(16#14# + 4 * i, d);
        pc(i) := to_integer(unsigned(d));
      end loop;
      axil_read(16#10#, d);
      exit when d = seq and unsigned(seq) /= 0;
      n := n + 1;
      assert n < 20 report "no consistent perf snapshot" severity failure;
      wait for 2 us;
    end loop;
    assert pc(0) = 2 ** 10 report "perf cycles " & integer'image(pc(0)) severity failure;
    assert not G_FREE or pc(1) = pc(0) report "perf: free core clock without an edge every cycle"
      severity failure;
    assert pc(1) > 0 and pc(1) + pc(2) + pc(3) = pc(0) report "perf edges/stall/pacer " & integer'image(pc(1)) &
      "/" & integer'image(pc(2)) & "/" & integer'image(pc(3)) severity failure;
    -- miss classes: subsets of the misses (vict_x of vict), reads in the upper half of the reads
    assert pc(12) <= pc(5) and pc(13) <= pc(5) and pc(14) <= pc(13) and pc(15) <= pc(5) and pc(11) <= pc(6)
      report "perf miss classes" severity failure;
    -- aux words are read only
    axil_write(16#1C#, x"00000001");
    axil_read(16#C#, d);
    assert d(3) = '0' report "write to an aux word set quiesce" severity failure;

    sw <= "0101";
    wait for 2 us;
    assert led(5 downto 2) = "0101" report "SW through LED: " & to_hstring(led) severity failure;
    if G_FREE and G_HP_ERR = 0 then
      assert status_err = '0' report "status_err with G_FREE_CLK (no emulator)" severity failure;
    elsif G_FREE then
      assert status_err = '1' report "status_err not sticky after the HP error" severity failure;
    else
      assert status_err = '1' report "unsupported SDRAM mode not on status_err" severity failure;
    end if;

    if not video_done then
      wait until video_done for 100 us;
    end if;
    assert video_done report "video check did not finish" severity failure;
    report "PASS";
    done <= true;
    wait for 1 us;
    std.env.stop;                            -- the PLL model of video_pll (G_DIRECT) keeps running
    wait;
  end process;

end architecture tb;

-------------------------------------------------------------------------------
-- mister_zynq without BRAM region (G_B0_BITS = 0)
-------------------------------------------------------------------------------
entity mister_zynq_noreg_tb is
end entity;

architecture tb of mister_zynq_noreg_tb is
begin
  noreg : entity work.mister_zynq_tb generic map (G_REGION => false, G_DDRAM => false);
end architecture tb;

-------------------------------------------------------------------------------
-- mister_zynq with a free-running core clock (G_FREE_CLK = 1) and HP2 (N64 profile)
-------------------------------------------------------------------------------
entity mister_zynq_free_tb is
end entity;

architecture tb of mister_zynq_free_tb is
begin
  free : entity work.mister_zynq_tb generic map (G_REGION => true, G_DDRAM => true, G_FREE => true,
                                                 G_COREMEM => true, G_DIRECT => true);
end architecture tb;

-------------------------------------------------------------------------------
-- N64 profile with SLVERR on every HP2 (DDRAM) or HP3 (COREMEM) read beat
-------------------------------------------------------------------------------
entity mister_zynq_hp2err_tb is
end entity;

architecture tb of mister_zynq_hp2err_tb is
begin
  hp2 : entity work.mister_zynq_tb generic map (G_REGION => true, G_DDRAM => true, G_FREE => true,
                                                G_COREMEM => true, G_DIRECT => false, G_HP_ERR => 1);
end architecture tb;

entity mister_zynq_hp3err_tb is
end entity;

architecture tb of mister_zynq_hp3err_tb is
begin
  hp3 : entity work.mister_zynq_tb generic map (G_REGION => true, G_DDRAM => true, G_FREE => true,
                                                G_COREMEM => true, G_DIRECT => false, G_HP_ERR => 2);
end architecture tb;
