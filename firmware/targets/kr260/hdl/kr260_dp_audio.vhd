-------------------------------------------------------------------------------
-- Title      : KR260 sound of the MiSTer designs into the DisplayPort live audio input
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : kr260_dp_audio.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-11-27
-- Platform   : KR260 (Kria K26, Zynq UltraScale+ XCK26)
-- Standard   : VHDL-93 (Vivado module reference), the bench uses VHDL-2008
-------------------------------------------------------------------------------
-- Description:
--   The DisplayPort of the PS (DPSUB) takes PL audio at its live audio input,
--   an AXI4-Stream (dp_s_axis_audio_*, 32 bit, tid = channel). Each beat is one
--   IEC 60958 subframe:
--     tdata(3 downto 0)   preamble code: 1 = channel 0 and block start,
--                         2 = channel 0, 3 = channel 1
--     tdata(27 downto 4)  sample, 24 bit, MSB at bit 27 (16-bit sample in 27..12)
--     tdata(28)           V (validity, 0 = valid)
--     tdata(29)           U (user data, 0)
--     tdata(30)           C (channel status, one bit of the 192-bit block)
--     tdata(31)           P (parity: bits 31..4 have an even number of ones)
--     tid                 0 = left (channel 0), 1 = right (channel 1)
--   The channel status block is that of the Linux driver (zynqmp_dp_audio.c):
--   all bits 0, except bit 25 (byte 3 = 0x02, 48 kHz).
--
--   clk is clk_audio (24.576 MHz = 512 x 48 kHz). The same clock goes to
--   dp_s_axis_audio_clk, so no CDC is necessary. i2s_rx (hdmi-tx)
--   receives the I2S of mister_zynq (bclk 1.536 MHz, 16 bit). Each received
--   sample pair starts a frame of two beats (left, then right). If the DPSUB
--   did not take the frame before the next pair, the new pair is dropped and
--   the drop counter increments. A pair in the clock in which the right beat
--   ends starts the next frame.
--
--   ctrl (from CTRL bits 7:3 of hps_bus_axi, aclk, quasi-static, synchronized):
--     bit 3  test tone: 1 kHz sine (amplitude 8000), left and right, from an
--            internal 48 kHz tick. The I2S is not used.
--     bit 4  tid is always 0
--     bit 5  the preamble code is always 0
--   Main writes CTRL at each core load. Thus each bit is 0 after a load.
--
--   status (to board_status 31:9, read through aux word 17; the counters
--   cross to aclk without a handshake, so read them twice):
--     status(22 downto 7)  frames sent (wraps)
--     status(6 downto 0)   frames dropped (saturates at 127)
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity kr260_dp_audio is
  port (
    clk        : in  std_logic;                      -- clk_audio, 24.576 MHz
    -- I2S of mister_zynq (clk_audio domain, bclk = clk / 16)
    i2s_bclk   : in  std_logic;
    i2s_lrclk  : in  std_logic;
    i2s_data   : in  std_logic;
    -- CTRL bits 7:3 of hps_bus_axi (aclk)
    ctrl       : in  std_logic_vector(7 downto 3);
    -- to dp_s_axis_audio_* of zynq_ultra_ps_e
    m_tdata    : out std_logic_vector(31 downto 0);
    m_tid      : out std_logic;
    m_tvalid   : out std_logic;
    m_tready   : in  std_logic;
    status     : out std_logic_vector(22 downto 0)
  );
end entity;

architecture rtl of kr260_dp_audio is

  type t_sine is array (0 to 47) of integer range -8000 to 8000;
  -- round(8000 * sin(2 pi i / 48))
  constant C_SINE : t_sine := (
        0,  1044,  2071,  3061,  4000,  4870,  5657,  6347,  6928,  7391,  7727,  7932,
     8000,  7932,  7727,  7391,  6928,  6347,  5657,  4870,  4000,  3061,  2071,  1044,
        0, -1044, -2071, -3061, -4000, -4870, -5657, -6347, -6928, -7391, -7727, -7932,
    -8000, -7932, -7727, -7391, -6928, -6347, -5657, -4870, -4000, -3061, -2071, -1044);

  signal i2s_l, i2s_r : std_logic_vector(15 downto 0);
  signal i2s_valid    : std_logic;

  signal ctrl_m, ctrl_s : std_logic_vector(7 downto 3) := (others => '0');
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of ctrl_m, ctrl_s : signal is "TRUE";

  signal tick_cnt  : unsigned(8 downto 0) := (others => '0');   -- 512 clk = 1 / 48 kHz
  signal sine_idx  : integer range 0 to 47 := 0;

  signal busy      : std_logic := '0';
  signal chan      : std_logic := '0';                          -- 0: left beat, 1: right beat
  signal smp_l     : std_logic_vector(15 downto 0) := (others => '0');
  signal smp_r     : std_logic_vector(15 downto 0) := (others => '0');
  signal frame_idx : integer range 0 to 191 := 0;
  signal n_sent    : unsigned(15 downto 0) := (others => '0');
  signal n_drop    : unsigned(6 downto 0) := (others => '0');

  signal tdata_r   : std_logic_vector(31 downto 0) := (others => '0');
  signal tid_r     : std_logic := '0';
  signal tvalid_r  : std_logic := '0';

  -- one subframe: sample, preamble, C bit, even parity over bits 31..4
  function subframe (smp : std_logic_vector(15 downto 0); pre : std_logic_vector(3 downto 0);
                     c : std_logic) return std_logic_vector is
    variable v : std_logic_vector(31 downto 0);
    variable p : std_logic;
  begin
    v := (others => '0');
    v(3 downto 0)   := pre;
    v(27 downto 12) := smp;
    v(28) := '0';
    v(29) := '0';
    v(30) := c;
    p := '0';
    for i in 4 to 30 loop
      p := p xor v(i);
    end loop;
    v(31) := p;
    return v;
  end function;

begin

  rx : entity work.i2s_rx
    generic map (G_BITS => 16)
    port map (
      clk   => clk,
      bclk  => i2s_bclk,
      lrclk => i2s_lrclk,
      sdata => i2s_data,
      left  => i2s_l,
      right => i2s_r,
      valid => i2s_valid
    );

  process (clk)
    variable start : boolean;
    variable done  : boolean;                           -- the right beat ends in this clock
    variable nl, nr : std_logic_vector(15 downto 0);
    variable pre : std_logic_vector(3 downto 0);
    variable c   : std_logic;
  begin
    if rising_edge(clk) then
      ctrl_m <= ctrl;
      ctrl_s <= ctrl_m;

      -- sample source: the I2S, or the test tone at its own 48 kHz tick
      start := false;
      tick_cnt <= tick_cnt + 1;
      if ctrl_s(3) = '1' then
        if tick_cnt = 0 then
          start := true;
          nl := std_logic_vector(to_signed(C_SINE(sine_idx), 16));
          nr := nl;
          if sine_idx = 47 then sine_idx <= 0; else sine_idx <= sine_idx + 1; end if;
        end if;
      elsif i2s_valid = '1' then
        start := true;
        nl := i2s_l;
        nr := i2s_r;
      end if;

      -- the DPSUB took the current beat
      done := false;
      if tvalid_r = '1' and m_tready = '1' then
        tvalid_r <= '0';
        if chan = '0' then
          chan <= '1';                                  -- right beat next
        else
          chan <= '0';
          busy <= '0';
          done := true;
          n_sent <= n_sent + 1;
          if frame_idx = 191 then frame_idx <= 0; else frame_idx <= frame_idx + 1; end if;
        end if;
      end if;

      if start then
        if busy = '1' and not done then
          if n_drop /= 127 then n_drop <= n_drop + 1; end if;
        else
          busy  <= '1';
          smp_l <= nl;
          smp_r <= nr;
        end if;
      end if;

      -- present the next beat (one clock after the handshake or the start)
      if busy = '1' and tvalid_r = '0' then
        if frame_idx = 25 then c := '1'; else c := '0'; end if;
        if chan = '0' then
          if frame_idx = 0 then pre := "0001"; else pre := "0010"; end if;
          if ctrl_s(5) = '1' then pre := "0000"; end if;
          tdata_r <= subframe(smp_l, pre, c);
          tid_r   <= '0';
        else
          pre := "0011";
          if ctrl_s(5) = '1' then pre := "0000"; end if;
          tdata_r <= subframe(smp_r, pre, c);
          tid_r   <= not ctrl_s(4);
        end if;
        tvalid_r <= '1';
      end if;
    end if;
  end process;

  m_tdata  <= tdata_r;
  m_tid    <= tid_r;
  m_tvalid <= tvalid_r;
  status   <= std_logic_vector(n_sent) & std_logic_vector(n_drop);

end architecture;
