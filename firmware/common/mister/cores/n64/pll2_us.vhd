-------------------------------------------------------------------------------
-- Title      : N64 core profile: video PLL with one MMCM (UltraScale+)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : pll2_us.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-11-27
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/pll2.v of N64_MiSTer on a board with few MMCMs (the
--   profile swaps it for pll2.vhd, core_swap_low_mmcm in core.tcl), with the
--   same name and ports as pll2.vhd.  The VCO of the UltraScale+ MMCM goes up
--   to 1600 MHz, so one MMCME4 gives both rates on two outputs, and the
--   BUFGCTRL (wired as BUFGMUX_CTRL: glitch-free switch, both inputs toggle)
--   selects one:
--     MMCME4_BASE, refclk 50 MHz, DIVCLK 3, CLKFBOUT 92.375
--           -> PFD 16.667 MHz, VCO 1539.583 MHz
--     NTSC  CLKOUT0 / 31.625 = 48.682477 MHz (+14 ppm)
--     PAL   CLKOUT1 / 31     = 49.663978 MHz (+150 ppm)
--   Both inputs of the BUFGCTRL come from one MMCM, so both have a dedicated
--   route.  reconfig_to_pll(0) = '1' selects PAL (cores/n64/pll_cfg_small.vhd
--   sets it from the divider N64.sv writes); MPAL gets the NTSC clock.
--   reconfig_from_pll is zero.  refclk must be a free-running 50 MHz clock;
--   pll_reset resets the MMCM once refclk runs and again when it loses lock.
--   The signal names (mmcm, buf_vid, mmcm_rst, pll_rst, lock_i) are those of
--   pll2.vhd: cores/n64/core_us.xdc and tb/n64_pll_tb.vhd use them.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

entity pll2 is
  generic (
    G_RST_CYCLES : positive := 65536                         -- refclk cycles of MMCM reset (pll_reset)
  );
  port (
    refclk            : in  std_logic;                       -- free-running 50 MHz
    rst               : in  std_logic;                       -- MMCM reset (N64.sv ties it to 0)
    outclk_0          : out std_logic;                       -- clk_vid 48.682 (NTSC) or 49.664 MHz (PAL)
    reconfig_to_pll   : in  std_logic_vector(63 downto 0);   -- bit 0: PAL (pll_cfg_small)
    reconfig_from_pll : out std_logic_vector(63 downto 0)
  );
end entity pll2;

architecture rtl of pll2 is
  signal fb             : std_logic;
  signal clk_n, clk_p   : std_logic;
  signal lock           : std_logic;
  signal rst_seq        : std_logic;
  signal pll_rst        : std_logic;                         -- = mmcm_rst (name of pll2.vhd)
  signal mmcm_rst       : std_logic;                         -- NTSC and PAL MMCM
  signal lock_i         : std_logic;
  signal pal, ntsc_sel  : std_logic;
begin

  mmcm : MMCME4_BASE
    generic map (
      BANDWIDTH        => "OPTIMIZED",
      CLKIN1_PERIOD    => 20.0,
      DIVCLK_DIVIDE    => 3,
      CLKFBOUT_MULT_F  => 92.375,
      CLKOUT0_DIVIDE_F => 31.625,          -- NTSC
      CLKOUT1_DIVIDE   => 31)              -- PAL
    port map (
      CLKIN1   => refclk,
      CLKFBIN  => fb,                      -- internal feedback: no phase relation to refclk needed
      CLKFBOUT => fb,
      CLKOUT0  => clk_n,
      CLKOUT1  => clk_p,
      LOCKED   => lock,
      PWRDWN   => '0',
      RST      => mmcm_rst);

  mmcm_rst <= rst or rst_seq;
  pll_rst  <= mmcm_rst;
  lock_i   <= lock;

  seq : entity work.pll_reset
    generic map (G_RST_CYCLES => G_RST_CYCLES)
    port map (clk => refclk, locked => lock, rst => rst_seq);

  -- pal comes from a register on refclk (pll_cfg_small); BUFGCTRL waits for both inputs itself
  pal      <= reconfig_to_pll(0);
  ntsc_sel <= not pal;

  buf_vid : BUFGCTRL
    generic map (
      INIT_OUT     => 0,
      PRESELECT_I0 => true,
      PRESELECT_I1 => false)
    port map (
      I0      => clk_n,
      I1      => clk_p,
      S0      => ntsc_sel,
      S1      => pal,
      CE0     => '1',
      CE1     => '1',
      IGNORE0 => '0',
      IGNORE1 => '0',
      O       => outclk_0);

  reconfig_from_pll <= (others => '0');

end architecture rtl;
