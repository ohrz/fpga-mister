-------------------------------------------------------------------------------
-- Title      : Testbench of kr260_dp_audio
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : kr260_dp_audio_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-11-27
-- Standard   : VHDL-2008
-------------------------------------------------------------------------------
-- Description:
--   An I2S transmitter model (as MiSTer sys/i2s.v: 16 bit, bclk = clk / 16,
--   lrclk changes with the LSB of the previous word) sends a counting and
--   random sample sequence into kr260_dp_audio. An AXI4-Stream sink with a
--   random tready takes the beats. The bench decodes each beat bit by bit and
--   checks it against its own model:
--     - tid 0 for the left beat, 1 for the right beat (or always 0, ctrl bit 4)
--     - preamble 1 at frame 0 of each 192-frame block, else 2 (left), 3 (right)
--       (or always 0, ctrl bit 5)
--     - the sample in bits 27..12, bits 11..4 zero, V and U zero
--     - C = 1 only at frame 25 of the block, even parity over bits 31..4
--     - the frame counter of status = the number of frames at the sink
--   Cases (G_CASE):
--     0  I2S source, random tready, 420 frames, each sample in order
--     1  test tone (ctrl bit 3): 1 kHz sine, the bench computes the values
--     2  test tone with ctrl bits 4 and 5 (tid 0, preamble 0)
--     3  tready low for 20 sample periods: drops counted, then in order again
--   Prints "kr260_dp_audio_tb: PASS" at the end of a case without an error.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity kr260_dp_audio_tb is
  generic (
    G_CASE : integer := 0
  );
end entity;

architecture sim of kr260_dp_audio_tb is

  constant C_FRAMES : integer := 420;
  constant T_CLK    : time := 40.69 ns;

  signal clk      : std_logic := '0';
  signal bclk, lrclk, sdata : std_logic := '0';
  signal ctrl     : std_logic_vector(7 downto 3) := (others => '0');
  signal tdata    : std_logic_vector(31 downto 0);
  signal tid      : std_logic;
  signal tvalid   : std_logic;
  signal tready   : std_logic := '0';
  signal status   : std_logic_vector(22 downto 0);
  signal hold_low : boolean := false;
  signal finished : boolean := false;

  -- sample n of the I2S source (left = 2n, right = 2n + 1)
  function src_sample (n : integer) return std_logic_vector is
    variable x : unsigned(15 downto 0);
  begin
    x := to_unsigned((n * 40503 + 12345) mod 65536, 16);
    return std_logic_vector(x);
  end function;

  function sine_sample (i : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_signed(integer(round(8000.0 * sin(2.0 * MATH_PI * real(i mod 48) / 48.0))), 16));
  end function;

begin

  clk <= not clk after T_CLK / 2 when not finished;

  dut : entity work.kr260_dp_audio
    port map (
      clk => clk, i2s_bclk => bclk, i2s_lrclk => lrclk, i2s_data => sdata,
      ctrl => ctrl, m_tdata => tdata, m_tid => tid, m_tvalid => tvalid,
      m_tready => tready, status => status);

  -- I2S transmitter: 32 slots per frame, one slot = 16 clk, data and lrclk
  -- change at the falling bclk edge
  i2s_tx : process
    variable n    : integer := 0;          -- word index: left of pair k = 2k, right = 2k + 1
    variable prev : std_logic_vector(15 downto 0) := (others => '0');
    variable w_l, w_r : std_logic_vector(15 downto 0);
  begin
    wait until rising_edge(clk);
    loop
      w_l := src_sample(n);
      w_r := src_sample(n + 1);
      for s in 0 to 31 loop
        -- falling bclk edge: new lrclk and data
        bclk <= '0';
        if s < 16 then lrclk <= '0'; else lrclk <= '1'; end if;
        if s = 0 then
          sdata <= prev(0);
        elsif s < 16 then
          sdata <= w_l(16 - s);
        elsif s = 16 then
          sdata <= w_l(0);
        else
          sdata <= w_r(32 - s);
        end if;
        for c in 1 to 8 loop wait until rising_edge(clk); end loop;
        bclk <= '1';
        for c in 1 to 8 loop wait until rising_edge(clk); end loop;
      end loop;
      prev := w_r;
      n := n + 2;
    end loop;
  end process;

  -- tready: random, 0 while hold_low
  sink_ready : process
    variable s1, s2 : positive := 7;
    variable r : real;
  begin
    wait until rising_edge(clk);
    uniform(s1, s2, r);
    if hold_low then tready <= '0';
    elsif r < 0.4 then tready <= '1';
    else tready <= '0';
    end if;
  end process;

  stim : process
  begin
    case G_CASE is
      when 1 => ctrl <= "00001";
      when 2 => ctrl <= "00111";
      when others => ctrl <= "00000";
    end case;
    if G_CASE = 3 then
      wait for 150 * 512 * T_CLK;
      hold_low <= true;
      wait for 20 * 512 * T_CLK;
      hold_low <= false;
    end if;
    wait;
  end process;

  check : process
    variable frames   : integer := 0;
    variable errors   : integer := 0;
    variable beat     : integer := 0;      -- 0 left, 1 right
    variable d        : std_logic_vector(31 downto 0);
    variable smp      : std_logic_vector(15 downto 0);
    variable exp_pre  : integer;
    variable exp_smp  : std_logic_vector(15 downto 0);
    variable exp_tid  : std_logic;
    variable par      : std_logic;
    variable fidx     : integer;
    variable first_n  : integer := -1;     -- source pair index of the current frame
    variable left_s   : std_logic_vector(15 downto 0);
    variable tone_i   : integer := -1;
    variable resync   : boolean := true;   -- find the source index again (start, after a gap)

    procedure err (msg : string) is
    begin
      errors := errors + 1;
      if errors < 20 then
        report "frame " & integer'image(frames) & " beat " & integer'image(beat) & ": " & msg severity error;
      end if;
    end procedure;

    -- source pair index whose left sample is s (search in a window)
    impure function find_pair (s : std_logic_vector(15 downto 0); from : integer) return integer is
    begin
      for k in from to from + 4000 loop
        if src_sample(2 * k) = s then return k; end if;
      end loop;
      return -1;
    end function;

  begin
    wait until rising_edge(clk);
    while frames < C_FRAMES loop
      wait until rising_edge(clk);
      if tvalid = '1' and tready = '1' then
        d := tdata;
        fidx := frames mod 192;
        -- fixed fields
        if d(11 downto 4) /= x"00" then err("bits 11..4 not zero"); end if;
        if d(28) /= '0' then err("V not 0"); end if;
        if d(29) /= '0' then err("U not 0"); end if;
        par := '0';
        for i in 4 to 31 loop par := par xor d(i); end loop;
        if par /= '0' then err("parity odd"); end if;
        if (fidx = 25) /= (d(30) = '1') then err("C bit wrong at block frame " & integer'image(fidx)); end if;
        -- preamble and tid
        if G_CASE = 2 then
          exp_pre := 0;
          exp_tid := '0';
        elsif beat = 0 then
          if fidx = 0 then exp_pre := 1; else exp_pre := 2; end if;
          exp_tid := '0';
        else
          exp_pre := 3;
          exp_tid := '1';
        end if;
        if to_integer(unsigned(d(3 downto 0))) /= exp_pre then
          err("preamble " & integer'image(to_integer(unsigned(d(3 downto 0)))) & " /= " & integer'image(exp_pre));
        end if;
        if tid /= exp_tid then err("tid wrong"); end if;
        -- sample
        smp := d(27 downto 12);
        if G_CASE = 1 or G_CASE = 2 then
          if beat = 0 then
            if tone_i < 0 then
              for k in 0 to 47 loop
                if sine_sample(k) = smp then tone_i := k; exit; end if;
              end loop;
              if tone_i < 0 then err("tone sample not in the sine table"); tone_i := 0; end if;
            else
              tone_i := tone_i + 1;
            end if;
            if smp /= sine_sample(tone_i) then err("tone sample wrong"); end if;
            left_s := smp;
          elsif smp /= left_s then
            err("tone: right /= left");
          end if;
        else
          if beat = 0 then
            if resync then
              first_n := find_pair(smp, 0);
              if first_n < 0 then err("left sample not from the source"); first_n := 0; end if;
              resync := false;
            else
              first_n := first_n + 1;
              exp_smp := src_sample(2 * first_n);
              if smp /= exp_smp then
                if G_CASE = 3 and find_pair(smp, first_n) > first_n then
                  first_n := find_pair(smp, first_n);       -- gap after the dropped pairs
                else
                  err("left sample out of order");
                end if;
              end if;
            end if;
          else
            if smp /= src_sample(2 * first_n + 1) then err("right sample does not belong to the left"); end if;
          end if;
        end if;
        if beat = 1 then
          frames := frames + 1;
          beat := 0;
        else
          beat := 1;
        end if;
      end if;
    end loop;
    -- counters: frames (status 22..7), drops (6..0)
    for i in 1 to 4 loop wait until rising_edge(clk); end loop;
    if to_integer(unsigned(status(22 downto 7))) /= frames then
      err("status frames " & integer'image(to_integer(unsigned(status(22 downto 7)))) & " /= " & integer'image(frames));
    end if;
    if G_CASE = 3 then
      if to_integer(unsigned(status(6 downto 0))) < 15 then err("drops not counted"); end if;
    elsif to_integer(unsigned(status(6 downto 0))) /= 0 then
      err("drops " & integer'image(to_integer(unsigned(status(6 downto 0)))) & " without backpressure");
    end if;
    if errors = 0 then
      report "kr260_dp_audio_tb: PASS (case " & integer'image(G_CASE) & ", " & integer'image(frames) & " frames, drops "
        & integer'image(to_integer(unsigned(status(6 downto 0)))) & ")";
    else
      report "kr260_dp_audio_tb: FAIL (" & integer'image(errors) & " errors)" severity error;
    end if;
    finished <= true;
    wait;
  end process;

end architecture;
