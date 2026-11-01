-------------------------------------------------------------------------------
-- Title      : Testbench of clk_pulse_div
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : clk_pulse_div_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   hdl/clk_pulse_div.vhd with the unisim BUFGCE model, five instances on one
--   gated master clock (90 MHz with random missing pulses, single and runs, as
--   the pacer and the stall of core_clock_stall produce them):
--     G_DIV/G_MID 2/1 (Gameboy), 4/2 (SNES clk_sys), 3/1 (odd), 4/0 (MSX,
--     no mid clock), 1/0 (pass-through).
--   Checker per instance (clk_pulse_div_chk):
--     every rising edge of clk_out is a rising edge of clk_in, exactly G_DIV
--     pulses after the previous one; every falling edge a falling edge of
--     clk_in (high time of clk_in, no glitch)
--     every rising edge of clk_mid is a rising edge of clk_in exactly G_MID
--     pulses after the last clk_out pulse, one per clk_out period, falling
--     edges as for clk_out; with G_MID = 0 clk_mid stays '0'
--     enough pulses of both
--   Ends with "PASS" or a failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity clk_pulse_div_chk is
  generic (
    G_DIV   : positive;
    G_MID   : natural;
    G_NAME  : string;
    G_MIN   : natural                 -- minimum number of clk_out pulses at the end
  );
  port (
    clk_in  : in  std_logic;
    clk_out : in  std_logic;
    clk_mid : in  std_logic;
    done    : in  boolean;
    ok      : out boolean := false
  );
end entity;

architecture tb of clk_pulse_div_chk is
begin
  process
    variable n_in       : natural := 0;     -- clk_in pulses since the last clk_out pulse
    variable outs, mids : natural := 0;
    variable mid_seen   : boolean := true;  -- clk_mid pulse of the current clk_out period
  begin
    wait on clk_in, clk_out, clk_mid, done;
    if done then
      assert outs >= G_MIN and (G_MID = 0 or mids + 1 >= outs)
        report G_NAME & ": too few pulses: clk_out " & integer'image(outs) & ", clk_mid " & integer'image(mids)
        severity failure;
      report G_NAME & ": clk_out " & integer'image(outs) & ", clk_mid " & integer'image(mids) & " pulses checked";
      ok <= true;
      wait;
    end if;
    if now > 0 ns then                      -- not the initialization of the BUFGCE models
      if clk_in'event and clk_in = '1' then
        n_in := n_in + 1;
      end if;
      if clk_out'event and clk_out = '1' then
        assert clk_in = '1' and clk_in'last_event = 0 ns
          report G_NAME & ": clk_out rises without a rising edge of clk_in" severity failure;
        assert n_in = G_DIV or outs = 0
          report G_NAME & ": clk_out after " & integer'image(n_in) & " clk_in pulses instead of "
            & integer'image(G_DIV) severity failure;
        assert mid_seen or outs = 0
          report G_NAME & ": no clk_mid pulse in a clk_out period" severity failure;
        n_in     := 0;
        outs     := outs + 1;
        mid_seen := G_MID = 0;
      end if;
      if clk_out'event and clk_out = '0' then
        assert clk_in = '0' and clk_in'last_event = 0 ns
          report G_NAME & ": clk_out falls without a falling edge of clk_in" severity failure;
      end if;
      if clk_mid'event and clk_mid = '1' then
        assert G_MID > 0 report G_NAME & ": clk_mid rises with G_MID = 0" severity failure;
        assert clk_in = '1' and clk_in'last_event = 0 ns
          report G_NAME & ": clk_mid rises without a rising edge of clk_in" severity failure;
        if outs > 0 then                    -- before the first clk_out pulse: no reference
          assert n_in = G_MID and not mid_seen
            report G_NAME & ": clk_mid " & integer'image(n_in) & " clk_in pulses after clk_out instead of "
              & integer'image(G_MID) severity failure;
          mid_seen := true;
          mids     := mids + 1;
        end if;
      end if;
      if clk_mid'event and clk_mid = '0' then
        assert clk_in = '0' and clk_in'last_event = 0 ns
          report G_NAME & ": clk_mid falls without a falling edge of clk_in" severity failure;
      end if;
    end if;
  end process;
end architecture tb;

library ieee;
use ieee.std_logic_1164.all;
use ieee.math_real.all;

entity clk_pulse_div_tb is
end entity;

architecture tb of clk_pulse_div_tb is
  constant T_HALF  : time    := 5.555 ns;
  constant PERIODS : natural := 20000;
  type div_t is array (0 to 4) of positive;
  type mid_t is array (0 to 4) of natural;
  constant DIVS : div_t := (2, 4, 3, 4, 1);
  constant MIDS : mid_t := (1, 2, 1, 0, 0);
  signal clk_in   : std_logic := '0';
  signal clk_out  : std_logic_vector(0 to 4);
  signal clk_mid  : std_logic_vector(0 to 4);
  signal done     : boolean := false;
  type ok_t is array (0 to 4) of boolean;
  signal ok       : ok_t;
begin

  inst : for i in 0 to 4 generate
    dut : entity work.clk_pulse_div
      generic map (G_DIV => DIVS(i), G_MID => MIDS(i))
      port map (clk_in => clk_in, clk_out => clk_out(i), clk_mid => clk_mid(i));
    chk : entity work.clk_pulse_div_chk
      generic map (G_DIV => DIVS(i), G_MID => MIDS(i),
                   G_NAME => "div " & integer'image(DIVS(i)) & " mid " & integer'image(MIDS(i)),
                   G_MIN  => PERIODS / 2 / DIVS(i))
      port map (clk_in => clk_in, clk_out => clk_out(i), clk_mid => clk_mid(i), done => done, ok => ok(i));
  end generate;

  -- gated master clock: a missing pulse keeps clk_in low for one period
  stim : process
    variable s1, s2 : positive := 11;
    variable r      : real;
    variable gap    : natural := 0;
  begin
    wait for T_HALF;                        -- first edge after time 0 (the checks skip time 0)
    for i in 1 to PERIODS loop
      if gap = 0 then
        uniform(s1, s2, r);
        if r < 0.05 then                    -- pacer: single missing pulse
          gap := 1;
        elsif r < 0.06 then                 -- stall: a run of missing pulses
          uniform(s1, s2, r);
          gap := 2 + integer(r * 12.0);
        end if;
      end if;
      if gap > 0 then
        gap := gap - 1;
        wait for 2 * T_HALF;
      else
        clk_in <= '1';
        wait for T_HALF;
        clk_in <= '0';
        wait for T_HALF;
      end if;
    end loop;
    done <= true;
    wait for 1 ns;
    assert ok = (ok_t'range => true) report "a checker did not finish" severity failure;
    report "PASS";
    wait;
  end process;

end architecture tb;
