-------------------------------------------------------------------------------
-- Title      : MSX core profile: replacement of the core PLL (Stage C clocks)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : pll.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/pll.v of MSX_MiSTer (altera_pll, 50 MHz -> clk_mem 85.909 MHz
--   and clk_sys 21.477 MHz, both phase 0) with the same name and ports, so
--   MSX.sv stays unchanged (doc/ARCHITECTURE.md §3.7).
--   The top level feeds the emu port CLK_50M (refclk here) with the gated core
--   master clock: the BUFGCE output driven by core_clock_stall (90 MHz with the
--   pacer at 21/22, a missing pulse while the core is stalled).
--     outclk_0  clk_mem = refclk
--     outclk_1  clk_sys = every 4th pulse of refclk: BUFGCE on refclk, CE from
--               a counter clocked by refclk itself, so it counts the pulses the
--               core actually got and the phase of clk_sys to clk_mem is the
--               same after every stall (as with the original PLL)
--     locked    '1' (the clocks exist once the top level releases the core)
--   The high time of clk_sys is the high time of refclk; the MSX core uses no
--   falling edges of clk_sys (its falling edge logic runs on clk_mem).
--   Timing: create_generated_clock -source <refclk BUFGCE>/O -edges {1 2 9} on
--   the BUFGCE output of this entity.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity pll is
  port (
    refclk   : in  std_logic;           -- gated core master clock
    rst      : in  std_logic;           -- unused (the original ties it to 0)
    outclk_0 : out std_logic;           -- clk_mem
    outclk_1 : out std_logic;           -- clk_sys = clk_mem / 4
    locked   : out std_logic
  );
end entity pll;

architecture rtl of pll is
  signal cnt    : unsigned(1 downto 0) := (others => '0');
  signal ce_sys : std_logic;
begin

  outclk_0 <= refclk;
  locked   <= '1';

  -- pulse n of refclk reaches clk_sys when cnt = 3 after pulse n-1
  process (refclk)
  begin
    if rising_edge(refclk) then
      cnt <= cnt + 1;
    end if;
  end process;
  ce_sys <= '1' when cnt = 3 else '0';

  sys_buf : BUFGCE
    port map (I => refclk, CE => ce_sys, O => outclk_1);

end architecture rtl;
