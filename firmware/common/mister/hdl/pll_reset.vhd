-------------------------------------------------------------------------------
-- Title      : Reset sequencer of a PLL or MMCM
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : pll_reset.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   A 7-series PLL or MMCM must be reset once its input clock is stable; it
--   does not lock (again) by itself when the input starts after configuration,
--   stops or jumps (UG472).  In the designs here the inputs come from other
--   MMCMs that start after the PL configuration (clk_core waits for
--   FCLK_RESET0_N) or from a core's video clock.  This sequencer drives RST:
--     S_RESET  rst = '1' for G_RST_CYCLES cycles of clk (power-up state)
--     S_WAIT   rst = '0', up to 4 * G_RST_CYCLES cycles for locked, else
--              S_RESET again
--     S_RUN    until locked falls, then S_RESET
--   clk may be the PLL's own input clock: while it does not run, rst stays
--   '1' (the register's initial value), so the count starts with the clock.
--   locked is asynchronous (two synchronizer stages here).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity pll_reset is
  generic (
    G_RST_CYCLES : positive := 65536            -- cycles of clk in reset (1.3 ms at 50 MHz)
  );
  port (
    clk    : in  std_logic;                     -- free-running or the PLL's input clock
    locked : in  std_logic;                     -- LOCKED of the PLL, asynchronous
    rst    : out std_logic                      -- RST of the PLL
  );
end entity pll_reset;

architecture rtl of pll_reset is

  type state_t is (S_RESET, S_WAIT, S_RUN);
  signal state  : state_t := S_RESET;
  signal cnt    : natural range 0 to 4 * G_RST_CYCLES := 0;
  signal rst_r  : std_logic := '1';
  signal lock_s : std_logic_vector(1 downto 0) := "00";

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of lock_s : signal is "TRUE";

begin

  rst <= rst_r;

  process (clk)
  begin
    if rising_edge(clk) then
      lock_s <= lock_s(0) & locked;
      case state is
        when S_RESET =>
          rst_r <= '1';
          if cnt = G_RST_CYCLES - 1 then
            cnt   <= 0;
            state <= S_WAIT;
          else
            cnt <= cnt + 1;
          end if;
        when S_WAIT =>
          rst_r <= '0';
          if lock_s(1) = '1' then
            cnt   <= 0;
            state <= S_RUN;
          elsif cnt = 4 * G_RST_CYCLES - 1 then
            cnt   <= 0;
            state <= S_RESET;
          else
            cnt <= cnt + 1;
          end if;
        when S_RUN =>
          rst_r <= '0';
          if lock_s(1) = '0' then
            state <= S_RESET;
          end if;
      end case;
    end if;
  end process;

end architecture rtl;
