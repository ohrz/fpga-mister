-------------------------------------------------------------------------------
-- Title      : Testbench of audio_i2s_simple
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : audio_i2s_simple_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   audio_i2s_simple (clk 24.576 MHz) into the I2S receiver of hdmi_out
--   (hdmi-tx i2s_rx, clk 74.25 MHz), the consumer on the boards.  The core
--   audio changes to random left/right values every N_HOLD clk (four frames)
--   from a clock of its own (core domain, 41.667 MHz); first with is_signed 1,
--   then with is_signed 0.  Checks:
--     every received frame is the current or the previous sample (a frame
--     taken during a change), left and right as sent, the MSB inverted for
--     is_signed 0; every sample is received at least twice in a row
--     bclk period 16 clk, lrclk period 512 clk (48 kHz), lrclk changes only
--     at the end of the bclk high phase (one clk before the falling edge, as sys/i2s.v)
--   and that enough frames came through.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity audio_i2s_simple_tb is
end entity audio_i2s_simple_tb;

architecture sim of audio_i2s_simple_tb is
  constant T_AUD    : time    := 40690 ps;   -- 24.576 MHz
  constant T_HDMI   : time    := 13468 ps;   -- 74.25 MHz
  constant T_CORE   : time    := 24 ns;      -- core clock domain of core_l/core_r
  constant N_HOLD   : natural := 2048;       -- clk per sample (four frames)
  constant N_SAMPLE : natural := 120;        -- samples per is_signed value

  signal clk, clk_hdmi, clk_core : std_logic := '0';
  signal reset      : std_logic := '1';
  signal is_signed  : std_logic := '1';
  signal core_l, core_r : std_logic_vector(15 downto 0) := (others => '0');
  signal bclk, lrclk, sdata : std_logic;
  signal rx_l, rx_r : std_logic_vector(15 downto 0);
  signal rx_valid   : std_logic;
  signal done       : boolean := false;

  -- expected (two's complement) value of the current and the previous sample
  signal exp_l, exp_r, prev_l, prev_r : std_logic_vector(15 downto 0) := (others => '0');
  signal n_frames : natural := 0;
begin

  clk      <= not clk after T_AUD / 2 when not done;
  clk_hdmi <= not clk_hdmi after T_HDMI / 2 when not done;
  clk_core <= not clk_core after T_CORE / 2 when not done;

  dut : entity work.audio_i2s_simple
    port map (clk => clk, reset => reset, is_signed => is_signed, core_l => core_l, core_r => core_r,
              i2s_bclk => bclk, i2s_lrclk => lrclk, i2s_data => sdata);

  rx : entity work.i2s_rx
    generic map (G_BITS => 16)
    port map (clk => clk_hdmi, bclk => bclk, lrclk => lrclk, sdata => sdata,
              left => rx_l, right => rx_r, valid => rx_valid);

  -- stimulus in the core clock domain
  process
    variable s1, s2 : positive := 7;
    variable r : real;
    variable l, rr : std_logic_vector(15 downto 0);
    impure function rnd16 return std_logic_vector is
    begin
      uniform(s1, s2, r);
      return std_logic_vector(to_unsigned(integer(floor(r * 65536.0)) mod 65536, 16));
    end function;
  begin
    wait for 20 * T_AUD;
    reset <= '0';
    for sgn in 1 downto 0 loop
      is_signed <= '1' when sgn = 1 else '0';
      for i in 0 to N_SAMPLE - 1 loop
        wait until rising_edge(clk_core);
        l := rnd16; rr := rnd16;
        core_l <= l; core_r <= rr;
        prev_l <= exp_l; prev_r <= exp_r;
        if sgn = 1 then
          exp_l <= l; exp_r <= rr;
        else
          exp_l <= (not l(15)) & l(14 downto 0); exp_r <= (not rr(15)) & rr(14 downto 0);
        end if;
        wait for N_HOLD * T_AUD;
      end loop;
    end loop;
    assert n_frames > 2 * N_SAMPLE * 3
      report "only " & integer'image(n_frames) & " frames received" severity failure;
    report "frames " & integer'image(n_frames);
    report "PASS";
    done <= true;
    wait;
  end process;

  -- received frames; run: frames in a row with the current sample, checked when the sample changes
  process (clk_hdmi)
    variable run : natural := 0;
    variable tag : std_logic_vector(31 downto 0) := (others => 'U');
  begin
    if rising_edge(clk_hdmi) and rx_valid = '1' and reset = '0' and now > 2 * N_HOLD * T_AUD then
      if exp_l & exp_r /= tag then
        assert tag(0) = 'U' or run >= 2
          report "sample " & to_hstring(tag) & " received only " & integer'image(run) & " times" severity failure;
        tag := exp_l & exp_r; run := 0;
      end if;
      if rx_l = exp_l and rx_r = exp_r then
        run := run + 1;
      else
        assert rx_l = prev_l and rx_r = prev_r
          report "frame " & integer'image(n_frames) & ": left " & to_hstring(rx_l) & " right " & to_hstring(rx_r) &
                 ", expected " & to_hstring(exp_l) & "/" & to_hstring(exp_r) & " or previous " &
                 to_hstring(prev_l) & "/" & to_hstring(prev_r) & " (is_signed " & std_logic'image(is_signed) & ")"
          severity failure;
      end if;
      n_frames <= n_frames + 1;
    end if;
  end process;

  -- clock rates in clk periods of the transmitter
  process (clk)
    variable c_b, c_lr : natural := 0;
    variable b_last, lr_last : std_logic := '1';
    variable n_b, n_lr : natural := 0;
  begin
    if rising_edge(clk) and reset = '0' then
      c_b := c_b + 1; c_lr := c_lr + 1;
      if bclk = '1' and b_last = '0' then
        assert n_b < 2 or c_b = 16 report "bclk period " & integer'image(c_b) & " clk, expected 16" severity failure;
        n_b := n_b + 1; c_b := 0;
      end if;
      if lrclk /= lr_last then
        -- sys/i2s.v: one clk before the falling bclk edge, at the end of the high phase
        -- (high phase 8 clk: 7 clk after the rising edge)
        assert bclk = '1' and c_b = 7
          report "lrclk changes " & integer'image(c_b) & " clk after the rising bclk edge, expected 7" severity failure;
        if lrclk = '0' then
          assert n_lr < 2 or c_lr = 512 report "lrclk period " & integer'image(c_lr) & " clk, expected 512" severity failure;
          n_lr := n_lr + 1; c_lr := 0;
        end if;
      end if;
      b_last := bclk; lr_last := lrclk;
    end if;
  end process;

end architecture sim;
