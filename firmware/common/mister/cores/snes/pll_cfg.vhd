-------------------------------------------------------------------------------
-- Title      : SNES core profile: replacement of the PLL reconfiguration
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : pll_cfg.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Replaces sys/pll_cfg/pll_cfg.v (altera_pll_reconfig, excluded for every
--   core by mister_project.tcl) with the same name and ports.  SNES.sv writes
--   the PLL's fractional M value (address 7) when the region changes, then
--   starts the reconfiguration (address 2): PAL 21.281 MHz instead of NTSC
--   21.477 MHz.  The stage C clocks come from the pacer (cores/snes/pll.vhd),
--   which cannot be reprogrammed; instead the pacer has a second ratio.
--   This entity decodes the writes: K = G_K_ALT selects it, K = G_K_MAIN the
--   first ratio, another K keeps the selection; the start write (address 2)
--   takes it over.  reconfig_to_pll(0) = '1' while the second ratio is
--   selected (rules.py: emu port ZYNQ_PACE_ALT, mister_zynq G_PACE_NUM_ALT /
--   G_PACE_DEN_ALT from core.tcl); the other bits are 0.  Every write is
--   accepted at once (waitrequest '0'), reads return 0.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity pll_cfg is
  generic (
    G_K_MAIN : std_logic_vector(31 downto 0) := x"9745BF27";   -- K written for NTSC (2537930535, SNES.sv)
    G_K_ALT  : std_logic_vector(31 downto 0) := x"83365882"    -- K written for PAL (2201376898)
  );
  port (
    mgmt_clk          : in  std_logic;
    mgmt_reset        : in  std_logic;
    mgmt_waitrequest  : out std_logic;
    mgmt_read         : in  std_logic;
    mgmt_write        : in  std_logic;
    mgmt_readdata     : out std_logic_vector(31 downto 0);
    mgmt_address      : in  std_logic_vector(5 downto 0);
    mgmt_writedata    : in  std_logic_vector(31 downto 0);
    reconfig_to_pll   : out std_logic_vector(63 downto 0);
    reconfig_from_pll : in  std_logic_vector(63 downto 0)
  );
end entity pll_cfg;

architecture rtl of pll_cfg is
  signal pend : std_logic := '0';
  signal alt  : std_logic := '0';
begin
  mgmt_waitrequest <= '0';
  mgmt_readdata    <= (others => '0');
  reconfig_to_pll  <= (63 downto 1 => '0') & alt;

  process (mgmt_clk)
  begin
    if rising_edge(mgmt_clk) then
      if mgmt_write = '1' then
        if mgmt_address = "000111" then
          if mgmt_writedata = G_K_ALT then
            pend <= '1';
          elsif mgmt_writedata = G_K_MAIN then
            pend <= '0';
          end if;
        elsif mgmt_address = "000010" then
          alt <= pend;
        end if;
      end if;
      if mgmt_reset = '1' then
        pend <= '0';
        alt  <= '0';
      end if;
    end if;
  end process;
end architecture rtl;
