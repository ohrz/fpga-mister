-------------------------------------------------------------------------------
-- Title      : Testbench of perf_counters
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : perf_counters_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-29
-------------------------------------------------------------------------------
-- Description:
--   Three events over windows of 64 cycles: always 1, random, always 0.  The
--   bench counts each window itself and checks after every window: seq one
--   higher, the three snapshot counts equal to its own, and the snapshot
--   unchanged inside a window.  Ends with "PASS" or a failure.  VHDL-2008.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity perf_counters_tb is
end entity;

architecture tb of perf_counters_tb is

  constant C_WIN  : natural := 64;
  constant C_WINS : natural := 40;
  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal done : boolean := false;
  signal ev   : std_logic_vector(2 downto 0) := "000";
  signal snap : std_logic_vector(4 * 32 - 1 downto 0);

  function word(v : std_logic_vector; i : natural) return natural is
  begin
    return to_integer(unsigned(v(32 * i + 31 downto 32 * i)));
  end function;

begin

  clk <= not clk after 5 ns when not done;

  dut : entity work.perf_counters
    generic map (G_N => 3, G_WIN_LOG2 => 6)
    port map (clk => clk, rst => rst, ev => ev, snap => snap);

  stim : process
    variable s1, s2 : positive := 5;
    variable r : real;
    variable n1 : natural;
    variable last : std_logic_vector(snap'range);
  begin
    rst <= '1';
    for i in 1 to 3 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    for w in 1 to C_WINS loop
      n1 := 0;
      for c in 0 to C_WIN - 1 loop
        uniform(s1, s2, r);
        if r >= 0.5 then
          ev <= "011";
          n1 := n1 + 1;
        else
          ev <= "001";
        end if;
        if c = 1 then last := snap; end if;
        wait until rising_edge(clk);
        if c >= 1 and c < C_WIN - 1 then
          assert snap = last report "snapshot changed inside window " & integer'image(w) severity failure;
        end if;
      end loop;
      ev <= "000";
      wait for 1 ns;
      assert word(snap, 0) = w report "seq " & integer'image(word(snap, 0)) & " after window " &
        integer'image(w) severity failure;
      assert word(snap, 1) = C_WIN report "always-1 event: " & integer'image(word(snap, 1)) severity failure;
      assert word(snap, 2) = n1 report "random event: " & integer'image(word(snap, 2)) & ", expected " &
        integer'image(n1) & " (window " & integer'image(w) & ")" severity failure;
      assert word(snap, 3) = 0 report "always-0 event: " & integer'image(word(snap, 3)) severity failure;
    end loop;
    report "PASS: " & integer'image(C_WINS) & " windows";
    done <= true;
    wait;
  end process;

end architecture tb;
