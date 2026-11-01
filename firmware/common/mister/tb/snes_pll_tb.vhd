-------------------------------------------------------------------------------
-- Title      : Testbench of the SNES core PLL replacement
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : snes_pll_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   cores/snes/pll.vhd with the unisim BUFGCE model.  refclk is the gated
--   master clock: 90 MHz with random missing pulses (single and runs, as the
--   pacer and the stall of core_clock_stall produce them).  Checks:
--     outclk_0 = refclk
--     every rising edge of outclk_1 (CLK_VIDEO) is a rising edge of refclk,
--     exactly 2 refclk pulses after the previous one; its falling edge is a
--     falling edge of refclk (high time of refclk, no glitch)
--     every rising edge of outclk_2 (clk_sys) is a rising edge of outclk_1,
--     exactly 2 outclk_1 pulses after the previous one; same for the falling
--     edge
--     every rising edge of outclk_3 (clk_sys_mid) is a rising edge of
--     outclk_1 without one of outclk_2: every CLK_VIDEO pulse goes to exactly
--     one of clk_sys and clk_sys_mid, the two alternate (clk_sys_mid is the
--     falling edge of clk_sys on the DE10); falling edges as for clk_sys
--   Ends with "PASS" or a failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.math_real.all;

entity snes_pll_tb is
end entity;

architecture tb of snes_pll_tb is
  constant T_HALF  : time    := 5.555 ns;
  constant PERIODS : natural := 20000;
  signal refclk, clk_mem, clk_video, clk_sys, clk_mid, locked : std_logic := '0';
  signal reconfig_from_pll : std_logic_vector(63 downto 0);
  signal done : boolean := false;
begin

  dut : entity work.pll
    port map (refclk => refclk, rst => '0', outclk_0 => clk_mem, outclk_1 => clk_video, outclk_2 => clk_sys, outclk_3 => clk_mid,
              reconfig_to_pll => (others => '0'), reconfig_from_pll => reconfig_from_pll, locked => locked);

  -- gated master clock: a missing pulse keeps refclk low for one period
  stim : process
    variable s1, s2 : positive := 7;
    variable r      : real;
    variable gap    : natural := 0;
  begin
    wait for T_HALF;                              -- first edge after time 0 (the checks skip time 0)
    for i in 1 to PERIODS loop
      if gap = 0 then
        uniform(s1, s2, r);
        if r < 0.05 then                          -- pacer: single missing pulse
          gap := 1;
        elsif r < 0.06 then                       -- stall: a run of missing pulses
          uniform(s1, s2, r);
          gap := 2 + integer(r * 12.0);
        end if;
      end if;
      if gap > 0 then
        gap := gap - 1;
        wait for 2 * T_HALF;
      else
        refclk <= '1';
        wait for T_HALF;
        refclk <= '0';
        wait for T_HALF;
      end if;
    end loop;
    done <= true;
    wait;
  end process;

  check : process
    variable n_ref, n_video          : natural := 0;
    variable video_pulses, sys_pulses : natural := 0;
    variable mid_pulses              : natural := 0;
    variable got_sys, got_mid        : boolean := false;  -- in the current CLK_VIDEO pulse
    variable last_sys                : boolean := false;  -- the previous CLK_VIDEO pulse went to clk_sys
  begin
    wait on refclk, clk_mem, clk_video, clk_sys, clk_mid, done;
    if done then
      assert video_pulses > PERIODS / 3 and sys_pulses > PERIODS / 6 and sys_pulses + mid_pulses = video_pulses
        report "too few pulses: CLK_VIDEO " & integer'image(video_pulses) & ", clk_sys " & integer'image(sys_pulses)
        severity failure;
      report "PASS: CLK_VIDEO " & integer'image(video_pulses) & ", clk_sys " & integer'image(sys_pulses)
        & " and clk_sys_mid " & integer'image(mid_pulses) & " pulses checked";
      wait;
    end if;
    if now > 0 ns then                            -- not the initialization of the BUFGCE models
      if refclk'event and refclk = '1' then
        n_ref := n_ref + 1;
      end if;
      if clk_video'event and clk_video = '1' then
        assert refclk = '1' and refclk'last_event = 0 ns
          report "CLK_VIDEO rises without a rising edge of refclk" severity failure;
        assert n_ref = 2
          report "CLK_VIDEO after " & integer'image(n_ref) & " refclk pulses instead of 2" severity failure;
        n_ref        := 0;
        n_video      := n_video + 1;
        got_sys      := false;
        got_mid      := false;
        video_pulses := video_pulses + 1;
      end if;
      if clk_video'event and clk_video = '0' then
        assert refclk = '0' and refclk'last_event = 0 ns
          report "CLK_VIDEO falls without a falling edge of refclk" severity failure;
        -- every CLK_VIDEO pulse went to exactly one of clk_sys and clk_sys_mid, alternating
        assert got_sys xor got_mid report "CLK_VIDEO pulse not to exactly one of clk_sys, clk_sys_mid" severity failure;
        assert got_sys /= last_sys or video_pulses = 1
          report "clk_sys and clk_sys_mid do not alternate" severity failure;
        last_sys := got_sys;
      end if;
      if clk_sys'event and clk_sys = '1' then
        assert clk_video = '1' and clk_video'last_event = 0 ns
          report "clk_sys rises without a rising edge of CLK_VIDEO" severity failure;
        assert n_video = 2
          report "clk_sys after " & integer'image(n_video) & " CLK_VIDEO pulses instead of 2" severity failure;
        n_video    := 0;
        sys_pulses := sys_pulses + 1;
        got_sys    := true;
      end if;
      if clk_mid'event and clk_mid = '1' then
        assert clk_video = '1' and clk_video'last_event = 0 ns
          report "clk_sys_mid rises without a rising edge of CLK_VIDEO" severity failure;
        mid_pulses := mid_pulses + 1;
        got_mid    := true;
      end if;
      if clk_mid'event and clk_mid = '0' then
        assert clk_video = '0' and clk_video'last_event = 0 ns
          report "clk_sys_mid falls without a falling edge of CLK_VIDEO" severity failure;
      end if;
      if clk_sys'event and clk_sys = '0' then
        assert clk_video = '0' and clk_video'last_event = 0 ns
          report "clk_sys falls without a falling edge of CLK_VIDEO" severity failure;
      end if;
    end if;
  end process;

  mem_check : process (refclk, clk_mem)
  begin
    if now > 0 ns then
      assert clk_mem = refclk or refclk'last_event = 0 ns
        report "outclk_0 differs from refclk" severity failure;
    end if;
  end process;

  assert locked = '1' or now = 0 ns report "locked not '1'" severity failure;

end architecture tb;
