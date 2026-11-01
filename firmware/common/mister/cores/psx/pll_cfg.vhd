-------------------------------------------------------------------------------
-- Title      : PSX core profile: replacement of the video PLL reconfiguration
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : pll_cfg.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-31
-------------------------------------------------------------------------------
-- Description:
--   Replaces sys/pll_cfg/pll_cfg.v (altera_pll_reconfig, excluded for every
--   core by mister_project.tcl) with the same name and ports, for the pll2 of
--   PSX.sv.  PSX.sv (cfg_block) writes, when the region or fast forward
--   changes, address 0 (mode), 5 (C counter), 7 (fractional K) and 2 (start).
--   cores/psx/pll2.vhd has a fixed NTSC and a fixed PAL source and selects
--   one: a write to address 7 with the PAL K value (2201376898 = 0x83365882,
--   53.203425 MHz) sets reconfig_to_pll(0) = '1', any other K (NTSC
--   2537930535, the debug and fast forward values, both tied off by the
--   profile) clears it.  Address 5 is ignored (C = 8 for NTSC and PAL).
--   Writes are accepted at once (waitrequest '0'); reconfig_to_pll(0) is a
--   register on mgmt_clk ('0' = NTSC after configuration, as the original
--   pll2 starts).  mgmt_readdata is zero.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity pll_cfg is
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
  constant C_K_PAL : std_logic_vector(31 downto 0) := x"83365882";   -- 2201376898: 53.203425 MHz
  signal pal : std_logic := '0';
begin

  process (mgmt_clk)
  begin
    if rising_edge(mgmt_clk) then
      if mgmt_reset = '1' then
        pal <= '0';
      elsif mgmt_write = '1' and mgmt_address = "000111" then
        if mgmt_writedata = C_K_PAL then
          pal <= '1';
        else
          pal <= '0';
        end if;
      end if;
    end if;
  end process;

  mgmt_waitrequest <= '0';
  mgmt_readdata    <= (others => '0');
  reconfig_to_pll  <= (63 downto 1 => '0') & pal;

end architecture rtl;
