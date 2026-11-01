-------------------------------------------------------------------------------
-- Title      : Event counters over a fixed window (stage C measurements)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : perf_counters.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-29
-------------------------------------------------------------------------------
-- Description:
--   Counts, for each of G_N event inputs, the clk cycles in which it is 1,
--   over windows of 2**G_WIN_LOG2 cycles.  At the end of a window the counts
--   go to snapshot registers and the counters restart; seq counts the
--   windows.  The snapshot stays stable for a whole window, so another clock
--   domain may read it without a handshake (quasi-static, no timing path
--   needed): read seq, the counts, seq again, and repeat if seq changed.
--   Output words: word 0 = seq, word 1 + i = count of event i.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity perf_counters is
  generic (
    G_N        : positive := 8;        -- events
    G_WIN_LOG2 : positive := 27        -- window 2**G_WIN_LOG2 cycles (<= 31)
  );
  port (
    clk  : in  std_logic;
    rst  : in  std_logic;              -- synchronous, active high
    ev   : in  std_logic_vector(G_N - 1 downto 0);
    snap : out std_logic_vector(32 * (G_N + 1) - 1 downto 0)
  );
end entity perf_counters;

architecture rtl of perf_counters is

  type cnt_array_t is array (0 to G_N - 1) of unsigned(31 downto 0);
  signal cnt    : cnt_array_t;
  signal shot   : cnt_array_t;
  signal win    : unsigned(G_WIN_LOG2 - 1 downto 0);
  signal seq    : unsigned(31 downto 0);

begin

  assert G_WIN_LOG2 <= 31 report "perf_counters: window too long for 32-bit counts" severity failure;

  process (clk)
  begin
    if rising_edge(clk) then
      win <= win + 1;
      for i in 0 to G_N - 1 loop
        if win = 2 ** G_WIN_LOG2 - 1 then
          if ev(i) = '1' then                      -- this cycle belongs to the window
            shot(i) <= cnt(i) + 1;
          else
            shot(i) <= cnt(i);
          end if;
          cnt(i) <= (others => '0');
        elsif ev(i) = '1' then
          cnt(i) <= cnt(i) + 1;
        end if;
      end loop;
      if win = 2 ** G_WIN_LOG2 - 1 then
        seq <= seq + 1;
      end if;

      if rst = '1' then
        win <= (others => '0');
        seq <= (others => '0');
        cnt <= (others => (others => '0'));
        shot <= (others => (others => '0'));
      end if;
    end if;
  end process;

  snap(31 downto 0) <= std_logic_vector(seq);
  g_out : for i in 0 to G_N - 1 generate
    snap(32 * (i + 2) - 1 downto 32 * (i + 1)) <= std_logic_vector(shot(i));
  end generate;

end architecture rtl;
