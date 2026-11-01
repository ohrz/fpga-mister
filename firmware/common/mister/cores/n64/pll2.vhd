-------------------------------------------------------------------------------
-- Title      : N64 core profile: replacement of the video PLL
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : pll2.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/pll2.v of N64_MiSTer (altera_pll with reconfiguration,
--   50 MHz -> clk_vid 48.681818 MHz NTSC; N64.sv rewrites the fractional
--   divider over pll_cfg_small for PAL 49.656530 and MPAL 48.628322 MHz) with
--   the same name and ports.  No single 7-series VCO gives NTSC and PAL
--   within 0.2 %, so two clock sources run at once and a BUFGCTRL (wired as
--   BUFGMUX_CTRL: glitch-free switch, both inputs toggle) selects one:
--     NTSC  PLLE2_BASE, refclk 50 MHz, DIVCLK 2, CLKFBOUT 37 -> VCO 925 MHz,
--           CLKOUT0 / 19 = 48.684211 MHz (+49 ppm)
--     PAL   MMCME2_BASE, DIVCLK 4, CLKFBOUT 54.125 -> VCO 676.5625 MHz,
--           CLKOUT0 / 13.625 = 49.655963 MHz (-11 ppm)
--   reconfig_to_pll(0) = '1' selects PAL (cores/n64/pll_cfg_small.vhd sets it
--   from the divider N64.sv writes); MPAL gets the NTSC clock (-1100 ppm).
--   PAL matters for the picture: a PAL VI (625 lines, 1589 clk_vid per
--   doubled line) gives 31.25 kHz / 50 Hz as 576p50 only at the PAL rate.
--   clk_vid keeps the original rates at 2/3 core speed: the VI reads the
--   frame buffer and produces the picture in this domain; the core clocks
--   are asynchronous to it (N64.sdc: false paths, cores/n64/core.xdc).
--   reconfig_from_pll is zero.  refclk must be a free-running 50 MHz clock;
--   one pll_reset per source resets it once refclk runs and again when it
--   loses lock (N64.sv ties rst to 0, see pll.vhd).  lock_i: both locked.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

entity pll2 is
  generic (
    G_RST_CYCLES : positive := 65536                         -- refclk cycles of PLL/MMCM reset (pll_reset)
  );
  port (
    refclk            : in  std_logic;                       -- free-running 50 MHz
    rst               : in  std_logic;                       -- PLL/MMCM reset (N64.sv ties it to 0)
    outclk_0          : out std_logic;                       -- clk_vid 48.684 (NTSC) or 49.656 MHz (PAL)
    reconfig_to_pll   : in  std_logic_vector(63 downto 0);   -- bit 0: PAL (pll_cfg_small)
    reconfig_from_pll : out std_logic_vector(63 downto 0)
  );
end entity pll2;

architecture rtl of pll2 is
  signal fb_n, fb_p     : std_logic;
  signal clk_n, clk_p   : std_logic;
  signal lock_n, lock_p : std_logic;
  signal rst_n, rst_p   : std_logic;
  signal pll_rst        : std_logic;                         -- NTSC PLLE2
  signal mmcm_rst       : std_logic;                         -- PAL MMCM
  signal lock_i         : std_logic;
  signal pal, ntsc_sel  : std_logic;
begin

  ntsc : PLLE2_BASE
    generic map (
      BANDWIDTH      => "OPTIMIZED",
      CLKIN1_PERIOD  => 20.0,
      DIVCLK_DIVIDE  => 2,
      CLKFBOUT_MULT  => 37,
      CLKOUT0_DIVIDE => 19)
    port map (
      CLKIN1   => refclk,
      CLKFBIN  => fb_n,                  -- internal feedback: no phase relation to refclk needed
      CLKFBOUT => fb_n,
      CLKOUT0  => clk_n,
      LOCKED   => lock_n,
      PWRDWN   => '0',
      RST      => pll_rst);

  mmcm : MMCME2_BASE
    generic map (
      BANDWIDTH        => "OPTIMIZED",
      CLKIN1_PERIOD    => 20.0,
      DIVCLK_DIVIDE    => 4,
      CLKFBOUT_MULT_F  => 54.125,
      CLKOUT0_DIVIDE_F => 13.625)
    port map (
      CLKIN1   => refclk,
      CLKFBIN  => fb_p,
      CLKFBOUT => fb_p,
      CLKOUT0  => clk_p,
      LOCKED   => lock_p,
      PWRDWN   => '0',
      RST      => mmcm_rst);

  pll_rst  <= rst or rst_n;
  mmcm_rst <= rst or rst_p;
  lock_i   <= lock_n and lock_p;

  seq_n : entity work.pll_reset
    generic map (G_RST_CYCLES => G_RST_CYCLES)
    port map (clk => refclk, locked => lock_n, rst => rst_n);
  seq_p : entity work.pll_reset
    generic map (G_RST_CYCLES => G_RST_CYCLES)
    port map (clk => refclk, locked => lock_p, rst => rst_p);

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
