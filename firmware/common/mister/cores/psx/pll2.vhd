-------------------------------------------------------------------------------
-- Title      : PSX core profile: replacement of the video PLL
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : pll2.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-31
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/pll2.v of PSX_MiSTer (altera_pll with reconfiguration,
--   rtl/pll2/pll2_0002.v: 50 MHz * (8 + K) / 8 -> clk_vid 53.693175 MHz NTSC;
--   PSX.sv rewrites the fractional K over pll_cfg for PAL 53.203425 MHz and
--   for fast forward) with the same name and ports.  clk_vid is the clock of
--   gpu_videoout_async: it produces the picture and the video timing (and so
--   the vblank rate the games run at) from VRAM in the DDR, asynchronous to
--   the core clocks (PSX.sdc false paths, cores/psx/core.xdc).
--   No single 7-series VCO gives both rates closely, and the last MMCM of the
--   xc7z020 serves PAL (frame: clk_core, clk_hdmi; core: pll), so as in
--   cores/n64/pll2.vhd two sources run at once and a BUFGCTRL (wired as
--   BUFGMUX_CTRL: glitch-free switch, both inputs toggle) selects one:
--     NTSC  PLLE2_BASE, refclk 50 MHz, DIVCLK 1, CLKFBOUT 29 -> VCO 1450 MHz,
--           CLKOUT0 / 27 = 53.703704 MHz (+196 ppm)
--     PAL   MMCME2_BASE, DIVCLK 1, CLKFBOUT 20.75 -> VCO 1037.5 MHz,
--           CLKOUT0 / 19.5 = 53.205128 MHz (+32 ppm)
--   reconfig_to_pll(0) = '1' selects PAL: the profile connects isPal of
--   PSX.sv to it (rules.py; asynchronous, synchronised here on refclk), not
--   pll_cfg (its cfg_block sequence lost the PAL switch on the board).
--   Fast forward (85 MHz) is tied off by the profile (rules.py).  reconfig_from_pll is zero.  refclk must be a
--   free-running 50 MHz clock; one pll_reset per source resets it once
--   refclk runs and again when it loses lock (PSX.sv ties rst to 0).
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
    rst               : in  std_logic;                       -- PLL/MMCM reset (PSX.sv ties it to 0)
    outclk_0          : out std_logic;                       -- clk_vid 53.704 (NTSC) or 53.205 MHz (PAL)
    reconfig_to_pll   : in  std_logic_vector(63 downto 0);   -- bit 0: PAL (isPal, any clock)
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
  signal pal_s          : std_logic_vector(1 downto 0) := "00";
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of pal_s : signal is "TRUE";
begin

  ntsc : PLLE2_BASE
    generic map (
      BANDWIDTH      => "OPTIMIZED",
      CLKIN1_PERIOD  => 20.0,
      DIVCLK_DIVIDE  => 1,
      CLKFBOUT_MULT  => 29,
      CLKOUT0_DIVIDE => 27)
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
      DIVCLK_DIVIDE    => 1,
      CLKFBOUT_MULT_F  => 20.75,
      CLKOUT0_DIVIDE_F => 19.5)
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

  -- reconfig_to_pll(0) is isPal of PSX.sv (clk_1x domain, rules.py): two flip-flops on refclk;
  -- BUFGCTRL waits for both inputs itself
  process (refclk)
  begin
    if rising_edge(refclk) then
      pal_s <= pal_s(0) & reconfig_to_pll(0);
    end if;
  end process;
  pal      <= pal_s(1);
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
