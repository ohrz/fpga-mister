-------------------------------------------------------------------------------
-- Title      : Menu core profile: replacement of the core PLL (Stage C clocks)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : pll.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/pll.v of Menu_MiSTer (altera_pll, 50 MHz -> clk_sys and
--   CLK_VIDEO, both 100 MHz phase 0) with the same name and ports, so menu.sv
--   stays unchanged (doc/ARCHITECTURE.md §3.7).
--   The top level feeds the emu port CLK_50M (refclk here) with the gated core
--   master clock (the BUFGCE output driven by core_clock_stall), so both outputs
--   are that clock:
--     outclk_0  clk_sys   = refclk
--     outclk_1  CLK_VIDEO = refclk
--     locked    '1' (the clocks exist once the top level releases the core;
--               rtl/sdram.sv starts from its initial values, init stays 0)
--   No constraints needed: both outputs are the master clock net itself.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity pll is
  port (
    refclk   : in  std_logic;           -- gated core master clock
    rst      : in  std_logic;           -- unused (the original ties it to 0)
    outclk_0 : out std_logic;           -- clk_sys
    outclk_1 : out std_logic;           -- CLK_VIDEO
    locked   : out std_logic
  );
end entity pll;

architecture rtl of pll is
begin

  outclk_0 <= refclk;
  outclk_1 <= refclk;
  locked   <= '1';

end architecture rtl;
