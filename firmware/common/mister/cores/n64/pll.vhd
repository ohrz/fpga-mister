-------------------------------------------------------------------------------
-- Title      : N64 core profile: replacement of the core PLL (2/3 speed)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : pll.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/pll.v of N64_MiSTer (altera_pll, 50 MHz -> clk_1x 62.5,
--   clk_93 93.75, clk_2x 125 MHz, SDRAM_CLK 62.5 MHz shifted) with the same
--   name and ports, so N64.sv stays unchanged.  The core does not fit the
--   timing of a 7-series -1 part easily at full speed (doc/PORTING.md §5.2):
--   The port ran it at 2/3 (VCO 1000 MHz, dividers 24/16/12) and 80 % (VCO
--   900 MHz, 18/12/9); phase 5 tries the original rates.  The ratios 2:3:4
--   stay (the core moves data between the three domains in the same cycles):
--     MMCME2_BASE, refclk 50 MHz, CLKFBOUT 22.5 -> VCO 1125 MHz
--     outclk_0  clk_1x  CLKOUT0 / 18 = 62.500 MHz (16 ns)
--     outclk_1  clk_93  CLKOUT1 / 12 = 93.750 MHz (10.667 ns)
--     outclk_2  clk_2x  CLKOUT2 /  9 = 125.000 MHz (8 ns)
--     outclk_3  '0': SDRAM_CLK goes to the SDRAM chip only, mister_zynq
--               leaves it open (its SDRAM emulator runs on the core clock)
--     locked    LOCKED of the MMCM (N64.sv: SDRAM init, reset)
--   All three outputs come from the same VCO with phase 0, so Vivado times
--   the paths between them as related clocks (cores/n64/core.xdc only names
--   them).  refclk must be a free-running 50 MHz clock: an MMCM loses lock
--   on a gated or stalled input.  N64.sv ties rst to 0, but refclk (CLK_50M =
--   clk_master of the block design) only starts after the PL configuration,
--   when clk_core leaves its reset: pll_reset on refclk resets the MMCM once
--   refclk runs and again when it loses lock (an MMCM never reset after its
--   input started does not lock).
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
    rst      : in  std_logic;                  -- MMCM reset (N64.sv ties it to 0)
    outclk_0 : out std_logic;                  -- clk_1x  62.5 MHz
    outclk_1 : out std_logic;                  -- clk_93  93.75 MHz
    outclk_2 : out std_logic;                  -- clk_2x  125 MHz
    outclk_3 : out std_logic;                  -- SDRAM_CLK, unused ('0')
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
      CLKFBOUT_MULT_F  => 22.5,
      CLKOUT0_DIVIDE_F => 18.0,
      CLKOUT1_DIVIDE   => 12,
      CLKOUT2_DIVIDE   => 9)
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

  buf_1x  : BUFG port map (I => clk0, O => outclk_0);
  buf_93  : BUFG port map (I => clk1, O => outclk_1);
  buf_2x  : BUFG port map (I => clk2, O => outclk_2);

  outclk_3 <= '0';

end architecture rtl;
