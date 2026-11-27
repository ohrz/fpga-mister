-------------------------------------------------------------------------------
-- Title      : PSX core profile: video PLL with one MMCM (UltraScale+)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : pll2_us.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-11-27
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/pll2.v of PSX_MiSTer on a board with few MMCMs (the
--   profile swaps it for pll2.vhd, core_swap_low_mmcm in core.tcl), with the
--   same name and ports as pll2.vhd.  The VCO of the UltraScale+ MMCM goes up
--   to 1600 MHz, so one MMCME4 gives both rates on two outputs, and the
--   BUFGCTRL (wired as BUFGMUX_CTRL: glitch-free switch, both inputs toggle)
--   selects one:
--     MMCME4_BASE, refclk 50 MHz, DIVCLK 2, CLKFBOUT 60.125
--           -> PFD 25 MHz, VCO 1503.125 MHz
--     NTSC  CLKOUT1 / 28    = 53.683036 MHz (-189 ppm)
--     PAL   CLKOUT0 / 28.25 = 53.207965 MHz (+85 ppm)
--   These values give the same rates in the unisim model of Vivado 2025.2 and
--   in older copies of it. An older copy gave /27.375 instead of /27.25 for
--   CLKFBOUT 29 (GHDL).
--   Both inputs of the BUFGCTRL come from one MMCM, so both have a dedicated
--   route.  reconfig_to_pll(0) = '1' selects PAL (isPal of PSX.sv,
--   rules.py; asynchronous, synchronised here on refclk).  reconfig_from_pll
--   is zero.  refclk must be a free-running 50 MHz clock; pll_reset resets
--   the MMCM once refclk runs and again when it loses lock.  The signal
--   names (mmcm, buf_vid, pal_s, mmcm_rst, pll_rst, lock_i) are those of
--   pll2.vhd: cores/psx/core_us.xdc and tb/psx_pll_tb.vhd use them.
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
    rst               : in  std_logic;                       -- MMCM reset (PSX.sv ties it to 0)
    outclk_0          : out std_logic;                       -- clk_vid 53.683 (NTSC) or 53.208 MHz (PAL)
    reconfig_to_pll   : in  std_logic_vector(63 downto 0);   -- bit 0: PAL (isPal, any clock)
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
  signal pal_s          : std_logic_vector(1 downto 0) := "00";
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of pal_s : signal is "TRUE";
begin

  mmcm : MMCME4_BASE
    generic map (
      BANDWIDTH        => "OPTIMIZED",
      CLKIN1_PERIOD    => 20.0,
      DIVCLK_DIVIDE    => 2,
      CLKFBOUT_MULT_F  => 60.125,
      CLKOUT0_DIVIDE_F => 28.25,           -- PAL
      CLKOUT1_DIVIDE   => 28)              -- NTSC
    port map (
      CLKIN1   => refclk,
      CLKFBIN  => fb,                      -- internal feedback: no phase relation to refclk needed
      CLKFBOUT => fb,
      CLKOUT0  => clk_p,
      CLKOUT1  => clk_n,
      LOCKED   => lock,
      PWRDWN   => '0',
      RST      => mmcm_rst);

  mmcm_rst <= rst or rst_seq;
  pll_rst  <= mmcm_rst;
  lock_i   <= lock;

  seq : entity work.pll_reset
    generic map (G_RST_CYCLES => G_RST_CYCLES)
    port map (clk => refclk, locked => lock, rst => rst_seq);

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
