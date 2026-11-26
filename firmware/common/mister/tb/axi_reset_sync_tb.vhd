-------------------------------------------------------------------------------
-- Title      : Testbench of axi_reset_sync
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : axi_reset_sync_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-11-07
-------------------------------------------------------------------------------
-- Description:
--   axi_reset_sync with G_CYCLES 32:
--     1. rst_in ends long before clk starts (the PL reset before the core's
--        MMCM runs): aresetn '0' and rst '1' before the first clk edge, and
--        for at least 32 rising edges of clk, then '1' within 36
--     2. rst_in pulse while clk runs: aresetn '0' within 3 edges, again for
--        at least 32 edges after rst_in ended, then '1'
--     3. clk stops with aresetn '1' and restarts: aresetn stays '1'
--   rst = not aresetn throughout.  Ends with "PASS" or a failure.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity axi_reset_sync_tb is
end entity;

architecture tb of axi_reset_sync_tb is
  constant T     : time := 10 ns;
  signal clk     : std_logic := '0';
  signal run     : boolean := false;
  signal rst_in  : std_logic := '1';
  signal aresetn : std_logic;
  signal rst     : std_logic;
begin

  process
  begin
    wait until run;
    while run loop
      clk <= '1';
      wait for T / 2;
      clk <= '0';
      wait for T / 2;
    end loop;
  end process;

  dut : entity work.axi_reset_sync
    generic map (G_CYCLES => 32)
    port map (clk => clk, rst_in => rst_in, aresetn => aresetn, rst => rst);

  process (aresetn, rst)
  begin
    assert rst = not aresetn or now = 0 ns report "rst is not the inverse of aresetn" severity failure;
  end process;

  process
    variable n : natural;
  begin
    -- 1. reset ends without a clock
    wait for 100 ns;
    rst_in <= '0';
    wait for 1 us;
    assert aresetn = '0' report "aresetn '1' before clk ran" severity failure;
    run <= true;
    n := 0;
    while aresetn = '0' loop
      wait until rising_edge(clk);
      n := n + 1;
      wait for 1 ns;
      assert n <= 36 report "aresetn still '0' after 36 clk edges" severity failure;
    end loop;
    assert n >= 32 report "aresetn '1' after only " & integer'image(n) & " clk edges" severity failure;

    -- 2. reset pulse with the clock running
    wait for 200 ns;
    wait until falling_edge(clk);
    rst_in <= '1';
    n := 0;
    while aresetn = '1' loop
      wait until rising_edge(clk);
      n := n + 1;
      wait for 1 ns;
      assert n <= 3 report "aresetn still '1' 3 clk edges after rst_in" severity failure;
    end loop;
    wait for 5 * T;
    rst_in <= '0';
    n := 0;
    while aresetn = '0' loop
      wait until rising_edge(clk);
      n := n + 1;
      wait for 1 ns;
      assert n <= 36 report "aresetn still '0' 36 clk edges after rst_in" severity failure;
    end loop;
    assert n >= 32 report "aresetn '1' after only " & integer'image(n) & " clk edges after rst_in"
      severity failure;

    -- 3. the clock stops and restarts: no new reset
    run <= false;
    wait for 1 us;
    run <= true;
    for k in 1 to 40 loop
      wait until rising_edge(clk);
      wait for 1 ns;
      assert aresetn = '1' report "aresetn fell after a clock pause" severity failure;
    end loop;

    report "PASS";
    run <= false;
    wait;
  end process;

end architecture tb;
