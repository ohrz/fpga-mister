-------------------------------------------------------------------------------
-- Title      : N64 core profile: replacement of the video PLL reconfiguration
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : pll_cfg_small.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/pll_cfg_small.v of N64_MiSTer (altera_pll_reconfig for
--   pll2) with the same name and ports (the Verilog parameters reconf_width
--   and device_family as generics).  N64.sv writes, when the region changes,
--   address 0 (mode), 7 (fractional divider of the region) and 2 (start).
--   cores/n64/pll2.vhd has a fixed NTSC and a fixed PAL source and selects
--   one: a write to address 7 with the PAL divider (VCLK_DSM_PAL of N64.sv,
--   4029432661) sets reconfig_to_pll(0) = '1', any other divider (NTSC,
--   MPAL) clears it.  Writes are accepted at once (waitrequest '0');
--   reconfig_to_pll(0) is a register on mgmt_clk ('0' = NTSC after
--   configuration, as the original pll2 starts).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity pll_cfg_small is
  generic (
    reconf_width  : integer := 64;
    device_family : string  := "Cyclone V"
  );
  port (
    mgmt_clk          : in  std_logic;
    mgmt_reset        : in  std_logic;
    reconfig_to_pll   : out std_logic_vector(reconf_width-1 downto 0);
    reconfig_from_pll : in  std_logic_vector(reconf_width-1 downto 0);
    mgmt_waitrequest  : out std_logic;
    mgmt_address      : in  std_logic_vector(5 downto 0);
    mgmt_write        : in  std_logic;
    mgmt_writedata    : in  std_logic_vector(31 downto 0)
  );
end entity pll_cfg_small;

architecture rtl of pll_cfg_small is
  constant C_DSM_PAL : std_logic_vector(31 downto 0) := x"F02C4355";   -- 4029432661: 49.65653 MHz
  signal pal : std_logic := '0';
begin

  process (mgmt_clk)
  begin
    if rising_edge(mgmt_clk) then
      if mgmt_reset = '1' then
        pal <= '0';
      elsif mgmt_write = '1' and mgmt_address = "000111" then
        if mgmt_writedata = C_DSM_PAL then
          pal <= '1';
        else
          pal <= '0';
        end if;
      end if;
    end if;
  end process;

  mgmt_waitrequest <= '0';
  reconfig_to_pll  <= (reconf_width-1 downto 1 => '0') & pal;

end architecture rtl;
