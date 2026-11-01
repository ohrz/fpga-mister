-------------------------------------------------------------------------------
-- Title      : Testbench of video_pll
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : video_pll_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   hdl/video_pll.vhd with the unisim PLLE2_BASE and BUFG models, clk_free
--   50 MHz, clk_in 48.681 MHz (period 20.542 ns, N64), G_MULT 20, short
--   reset (G_RST_CYCLES 64).  Phases:
--     1. clk_in starts late (after the first lock timeout): the sequencer
--        resets the PLL again and it locks
--     2. locked: every rising edge of clk_pix within 50 ps of a rising edge
--        of clk_in (phase and period), clk_ser period a fifth of clk_in and
--        high time half of that, a clk_ser edge within 50 ps of each clk_pix
--        edge (so 5 per clk_pix period)
--     3. clk_in stops for 3 us: locked falls; clk_in comes back with a
--        different phase: the sequencer resets the PLL, it locks again and
--        phase 2 holds again
--   Ends with "PASS" or a failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity video_pll_tb is
end entity;

architecture tb of video_pll_tb is
  constant T_IN   : time := 20542 ps;
  constant T_FREE : time := 20 ns;
  constant TOL    : time := 50 ps;

  signal clk_free : std_logic := '0';
  signal clk_in   : std_logic := '0';
  signal run_in   : boolean := false;
  signal clk_pix, clk_ser, locked : std_logic;
  signal t_edge_in : time := 0 ns;            -- last rising edge of clk_in
  signal check    : boolean := false;        -- phase 2 checks on
  signal n_pix    : natural := 0;            -- clk_pix edges checked
  signal t_ser    : time := 0 ns;            -- last rising edge of clk_ser
  signal n_lock   : natural := 0;            -- rising edges of locked
  signal n_unlock : natural := 0;            -- falling edges of locked
begin

  clk_free <= not clk_free after T_FREE / 2;

  process
  begin
    wait until run_in;
    while run_in loop
      clk_in <= '1';
      wait for T_IN / 2;
      clk_in <= '0';
      wait for T_IN - T_IN / 2;
    end loop;
  end process;

  dut : entity work.video_pll
    generic map (G_CLKIN_PS => 20542, G_MULT => 20, G_RST_CYCLES => 64)
    port map (clk_free => clk_free, clk_in => clk_in, clk_pix => clk_pix, clk_ser => clk_ser, locked => locked);

  t_edge_in <= now when rising_edge(clk_in);

  process (locked)
  begin
    if rising_edge(locked) then
      n_lock <= n_lock + 1;
    elsif falling_edge(locked) then
      n_unlock <= n_unlock + 1;
    end if;
  end process;

  -- clk_ser: period a fifth of clk_in, high time half of it
  process (clk_ser)
    variable t_rise : time := 0 ns;
  begin
    if rising_edge(clk_ser) then
      if check and t_rise > 0 ns then
        assert abs ((now - t_rise) - T_IN / 5) <= TOL
          report "clk_ser period " & time'image(now - t_rise) severity failure;
      end if;
      t_rise := now;
      t_ser  <= now;
    elsif falling_edge(clk_ser) and check and t_rise > 0 ns then
      assert abs ((now - t_rise) - T_IN / 10) <= TOL
        report "clk_ser high time " & time'image(now - t_rise) severity failure;
    end if;
  end process;

  -- clk_pix: on a clk_in edge, a clk_ser edge on it
  process
    variable tp : time;
  begin
    wait until rising_edge(clk_pix) and check;
    tp := now;
    assert now - t_edge_in <= TOL or T_IN - (now - t_edge_in) <= TOL
      report "clk_pix edge " & time'image(now - t_edge_in) & " after clk_in" severity failure;
    wait for TOL + 1 ps;
    assert abs (t_ser - tp) <= TOL
      report "last clk_ser edge " & time'image(tp - t_ser) & " before the clk_pix edge" severity failure;
    n_pix <= n_pix + 1;
  end process;

  main : process
    variable n0 : natural;
  begin
    -- 1. clk_in only after the first timeout (reset 64 + wait 256 clk_free cycles)
    wait for 400 * T_FREE;
    assert locked /= '1' report "locked without clk_in" severity failure;
    run_in <= true;
    wait until locked = '1' for 200 us;
    assert locked = '1' report "no lock after a late clk_in" severity failure;

    -- 2. phase and frequencies
    wait for 1 us;
    check <= true;
    wait for 2 us;
    check <= false;
    assert n_pix >= 90 report "clk_pix edges: " & integer'image(n_pix) severity failure;

    -- 3. clk_in stops, then comes back with another phase
    run_in <= false;
    wait for 3 us;
    assert locked = '0' report "locked stays high without clk_in" severity failure;
    wait for 7 ns;                           -- phase shift of the restart
    run_in <= true;
    wait until locked = '1' for 200 us;
    assert locked = '1' report "no lock after clk_in came back" severity failure;
    wait for 1 us;
    n0 := n_pix;
    check <= true;
    wait for 2 us;
    check <= false;
    assert n_pix - n0 >= 90 report "clk_pix edges after the restart: " & integer'image(n_pix - n0) severity failure;
    assert n_lock = 2 and n_unlock >= 1
      report "lock edges " & integer'image(n_lock) & " / " & integer'image(n_unlock) severity failure;

    report "PASS";
    std.env.stop;
  end process;

end architecture tb;
