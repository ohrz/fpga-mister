-------------------------------------------------------------------------------
-- Title      : Safe clock start: MMCM or PLL outputs enabled after lock
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : clk_safe_start.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-11-07
-------------------------------------------------------------------------------
-- Description:
--   Global buffers for the outputs of an MMCM or PLL that stay off until it
--   has locked (as the "safe clock startup" of the Clocking Wizard): the
--   outputs of an MMCM are not specified before LOCKED (UG472, UG572), and a
--   core clock that drives an AXI port of the PS (HP2/HP3 of the ZynqMP:
--   SmartConnect and AFI on the core's DDRAM_CLK or memory clock) must not see
--   runt pulses while the logic behind it leaves its reset.
--     refclk  free-running input clock of the MMCM; locked (asynchronous) on
--             two synchronizer stages, then G_CYCLES further cycles with
--             locked '1' until ready rises; ready falls three cycles after
--             locked (the count starts again)
--     clk_in  MMCM outputs (without buffer); per output a BUFGCE with CE '1'
--             clocks three stages that take ready into that output's domain,
--             the last one drives CE of the output's BUFGCE: CE then meets
--             setup and hold to the BUFGCE input (both buffers on the same
--             MMCM output, timed as one clock), the BUFGCE switches
--             glitch-free.  The clocks start 3 to 4 of their own cycles
--             after ready.
--     clear   the three stages are cleared asynchronously while locked or
--             ready is '0': when the MMCM loses lock, pll_reset resets it
--             and its outputs (also the enable clocks) stand still, so the
--             stages could not take ready = '0' and CE would stay '1' into
--             the next start, letting the clocks before the lock through.
--             CE so falls with LOCKED, before ready (the core's locked)
--             falls; only its rise is synchronous.
--   ready_r is asynchronous to the output clocks (as LOCKED): the core
--   constraints of a user declare paths from it false (cores/psx/core.xdc).
--   ready doubles as the core's locked: the core clocks follow it within 3 to
--   4 of their cycles, and the core synchronizes it onto them.  Costs two
--   global buffers per output.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

entity clk_safe_start is
  generic (
    G_N      : positive := 1;                   -- number of clock outputs
    G_CYCLES : positive := 256                  -- cycles of refclk from locked to ready
  );
  port (
    refclk  : in  std_logic;                    -- free running (the MMCM's input clock)
    locked  : in  std_logic;                    -- LOCKED of the MMCM, asynchronous
    clk_in  : in  std_logic_vector(G_N - 1 downto 0);  -- MMCM outputs, unbuffered
    clk_out : out std_logic_vector(G_N - 1 downto 0);  -- global clocks, off until ready
    ready   : out std_logic                     -- on refclk: outputs enabled (or about to be)
  );
end entity clk_safe_start;

architecture rtl of clk_safe_start is

  signal lock_s  : std_logic_vector(1 downto 0) := "00";
  signal cnt     : natural range 0 to G_CYCLES := 0;
  signal ready_r : std_logic := '0';
  signal clr     : std_logic;

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of lock_s : signal is "TRUE";

begin

  process (refclk)
  begin
    if rising_edge(refclk) then
      lock_s <= lock_s(0) & locked;
      if lock_s(1) = '0' then
        cnt     <= 0;
        ready_r <= '0';
      elsif cnt = G_CYCLES then
        ready_r <= '1';
      else
        cnt <= cnt + 1;
      end if;
    end if;
  end process;

  ready <= ready_r;
  clr   <= not (locked and ready_r);

  g_out : for i in 0 to G_N - 1 generate
    signal clk_en  : std_logic;
    signal meta    : std_logic := '0';
    signal sync    : std_logic := '0';
    signal ce      : std_logic := '0';
    attribute ASYNC_REG of meta : signal is "TRUE";
    attribute ASYNC_REG of sync : signal is "TRUE";
  begin

    -- always on: clocks the enable path of this output (runt pulses before the lock only
    -- reach these three registers, and ready is '0' then)
    en_buf : BUFGCE port map (I => clk_in(i), CE => '1', O => clk_en);

    process (clk_en, clr)
    begin
      if clr = '1' then
        meta <= '0';
        sync <= '0';
        ce   <= '0';
      elsif rising_edge(clk_en) then
        meta <= ready_r;
        sync <= meta;
        ce   <= sync;
      end if;
    end process;

    out_buf : BUFGCE port map (I => clk_in(i), CE => ce, O => clk_out(i));

  end generate;

end architecture rtl;
