-------------------------------------------------------------------------------
-- Title      : PSX core profile: replacement of the core PLL
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : pll.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-31
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/pll.v of PSX_MiSTer (altera_pll, 50 MHz -> clk_1x 33.8688,
--   clk_2x 67.7376, clk_3x 101.6064 MHz, rtl/pll/pll_0002.v) with the same
--   name and ports, so PSX.sv stays unchanged.  The core moves data between
--   the three domains in fixed cycles (clk2xIndex, clk3x phase in sdram), so
--   the ratios stay exactly 1:2:3 with a common rising edge every clk_1x
--   period; only the VCO is off by the nearest MMCM setting:
--     MMCME2_BASE, refclk 50 MHz, DIVCLK 1, CLKFBOUT 16.25 -> VCO 812.5 MHz
--     outclk_0  clk_1x  CLKOUT0 / 24 = 33.854167 MHz (29.538 ns)
--     outclk_1  clk_2x  CLKOUT1 / 12 = 67.708333 MHz (14.769 ns)
--     outclk_2  clk_3x  CLKOUT2 /  8 = 101.562500 MHz (9.846 ns)
--     locked    LOCKED of the MMCM (PSX.sv: sdram init)
--   All three clocks are 432 ppm slow (the best of every MMCM setting with
--   PFD >= 10 MHz, VCO 600-1200 MHz and dividers 6a/3a/2a; M = 61, D = 5 is
--   +593 ppm): CPU, SPU (44.1 kHz from clk_1x / 768 -> 44.081 kHz) and CD
--   timing run 0.04 % slow.  All outputs come from the same VCO with phase 0:
--   Vivado times the paths between them as related clocks (cores/psx/core.xdc
--   only names them).  refclk must be a free-running 50 MHz clock (G_FREE_CLK,
--   CLK_50M = clk_master of the block design); it starts only after the PL
--   configuration, so pll_reset resets the MMCM once refclk runs and again
--   when it loses lock (as cores/n64/pll.vhd).  PSX.sv ties rst to 0.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

entity pll is
  generic (
    G_RST_CYCLES : positive := 65536           -- refclk cycles of MMCM reset (pll_reset)
  );
  port (
    refclk   : in  std_logic;                  -- free-running 50 MHz
    rst      : in  std_logic;                  -- MMCM reset (PSX.sv ties it to 0)
    outclk_0 : out std_logic;                  -- clk_1x 33.854 MHz
    outclk_1 : out std_logic;                  -- clk_2x 67.708 MHz
    outclk_2 : out std_logic;                  -- clk_3x 101.563 MHz
    locked   : out std_logic
  );
end entity pll;

architecture rtl of pll is
  signal fb               : std_logic;
  signal lock_i, rst_seq  : std_logic;
  signal mmcm_rst         : std_logic;
  signal clk0, clk1, clk2 : std_logic;
begin

  mmcm : MMCME2_BASE
    generic map (
      BANDWIDTH        => "OPTIMIZED",
      CLKIN1_PERIOD    => 20.0,
      DIVCLK_DIVIDE    => 1,
      CLKFBOUT_MULT_F  => 16.25,
      CLKOUT0_DIVIDE_F => 24.0,
      CLKOUT1_DIVIDE   => 12,
      CLKOUT2_DIVIDE   => 8)
    port map (
      CLKIN1   => refclk,
      CLKFBIN  => fb,                    -- internal feedback: no phase relation to refclk needed
      CLKFBOUT => fb,
      CLKOUT0  => clk0,
      CLKOUT1  => clk1,
      CLKOUT2  => clk2,
      LOCKED   => lock_i,
      PWRDWN   => '0',
      RST      => mmcm_rst);

  mmcm_rst <= rst or rst_seq;

  seq : entity work.pll_reset
    generic map (G_RST_CYCLES => G_RST_CYCLES)
    port map (clk => refclk, locked => lock_i, rst => rst_seq);

  locked <= lock_i;

  buf_1x : BUFG port map (I => clk0, O => outclk_0);
  buf_2x : BUFG port map (I => clk1, O => outclk_1);
  buf_3x : BUFG port map (I => clk2, O => outclk_2);

end architecture rtl;
