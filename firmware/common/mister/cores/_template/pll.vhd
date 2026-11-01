-------------------------------------------------------------------------------
-- Title      : <CORE> core profile: replacement of the core PLL  -- TEMPLATE
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : pll.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : <date>
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/pll.v of the core (altera_pll) with the same entity name and
--   ports, so the core stays unchanged (doc/ARCHITECTURE.md §3.7, PORTING §3.3).
--   Pattern of cores/msx/pll.vhd (verified in simulation, timing and hardware)
--   with the building block hdl/clk_pulse_div.vhd: the top level feeds the emu
--   port CLK_50M (refclk here) with the gated core master clock (BUFGCE core_buf
--   of mister_zynq, a missing pulse while the core is stalled).
--     outclk_0  the fastest core clock = refclk
--     outclk_1  refclk / 4: every 4th pulse of refclk (clk_pulse_div G_DIV 4); the
--               counter counts the pulses the core really got, so the phase to
--               outclk_0 is the same after every stall
--     locked    '1'
--   Conditions: every core clock is an integer fraction of the fastest one with
--   phase 0.  A derived clock is high for one high time of refclk: when the core
--   uses its falling edge (core_survey.py lint), set G_MID => G_DIV/2 and
--   give clk_mid an extra port (outclk_<n>, not in the original PLL); rules.py
--   moves the falling edges to it (falling_edge_to, add_port, connect_port of
--   prepare_sources.py, PORTING §3.3).  Otherwise: PORTING §3.3.
--   One create_generated_clock per derived clock in cores/<core>/core.xdc
--   (formulas in the header of clk_pulse_div.vhd).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity pll is
  port (
    refclk   : in  std_logic;           -- gated core master clock
    rst      : in  std_logic;           -- unused
    outclk_0 : out std_logic;           -- = refclk
    outclk_1 : out std_logic;           -- = refclk / 4
    locked   : out std_logic
  );
end entity pll;

architecture rtl of pll is
begin

  outclk_0 <= refclk;
  locked   <= '1';

  -- G_MID => 2 and a port for clk_mid when the core uses the falling edge of outclk_1
  div4 : entity work.clk_pulse_div
    generic map (G_DIV => 4, G_MID => 0)
    port map (clk_in => refclk, clk_out => outclk_1, clk_mid => open);

end architecture rtl;
