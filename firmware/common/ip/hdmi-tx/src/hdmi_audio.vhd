-------------------------------------------------------------------------------
-- Title      : HDMI audio sample packets and clock regeneration values
-- Project    : fpga-mister (hdmi-tx)
-------------------------------------------------------------------------------
-- File       : hdmi_audio.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-29
-------------------------------------------------------------------------------
-- Description:
--   Collects the 2-channel L-PCM samples of i2s_rx (valid pulses, clk = TMDS
--   pixel clock) for hdmi_tx:
--   - Audio Sample Packet (HDMI 1.4 5.3.4, layout 0): up to 4 samples, one
--     per subpacket; asp_hdr/asp_sub always hold the packet of the samples
--     collected so far (a Null Packet without samples).  asp_take (one clk,
--     when hdmi_tx loads the packet) empties the collection; a sample
--     arriving in the same clk goes to the next packet.  A fifth sample before
--     the next asp_take is dropped (drops counts them).
--     Subpacket: left bits 23:0, right 47:24 (16-bit sample in the upper
--     bits), bit 48 + 4c ... 51 + 4c = V, U, C, P of channel c (0 left);
--     P = even parity over sample, V, U, C.  Header: HB0 0x02, HB1 bits 3:0
--     sample present, HB2 bits 7:4 B (first frame of an IEC 60958 block).
--   - Channel status (IEC 60958-3, consumer, both channels): bit 2 copying
--     permitted, bits 24-27 = 48 kHz, bits 32-35 = 16 bit; all others 0.
--   - CTS for the Audio Clock Regeneration Packet: clk cycles of G_N / 128
--     samples, measured against the sample pulses (the audio clock is not
--     locked to the pixel clock); acr_due rises with each new value and falls
--     with acr_take.  No samples, no acr_due.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity hdmi_audio is
  generic (
    G_N : positive := 6144             -- ACR N (48 kHz: 6144), a multiple of 128
  );
  port (
    clk      : in  std_logic;
    rst      : in  std_logic;          -- synchronous
    s_valid  : in  std_logic;
    s_left   : in  std_logic_vector(15 downto 0);
    s_right  : in  std_logic_vector(15 downto 0);
    asp_hdr  : out std_logic_vector(23 downto 0);
    asp_sub  : out std_logic_vector(4 * 56 - 1 downto 0);
    asp_take : in  std_logic;
    acr_due  : out std_logic;
    acr_cts  : out std_logic_vector(19 downto 0);
    acr_take : in  std_logic;
    drops    : out std_logic_vector(15 downto 0)
  );
end entity hdmi_audio;

architecture rtl of hdmi_audio is

  constant C_PER : positive := G_N / 128;   -- samples per CTS period

  type sub_array_t is array (0 to 3) of std_logic_vector(55 downto 0);
  signal sub   : sub_array_t := (others => (others => '0'));
  signal pres  : std_logic_vector(3 downto 0) := "0000";
  signal bflg  : std_logic_vector(3 downto 0) := "0000";
  signal n     : natural range 0 to 4 := 0;
  signal frame : natural range 0 to 191 := 0;
  signal drop_n : unsigned(15 downto 0) := (others => '0');

  signal per_cnt  : natural range 0 to C_PER - 1 := 0;
  signal clk_cnt  : unsigned(19 downto 0) := (others => '0');
  signal started  : std_logic := '0';
  signal due      : std_logic := '0';
  signal cts      : std_logic_vector(19 downto 0) := (others => '0');

  function cs_bit(f : natural) return std_logic is
  begin
    if f = 2 or f = 25 or f = 33 then
      return '1';
    end if;
    return '0';
  end function;

  function xor_all(v : std_logic_vector) return std_logic is
    variable r : std_logic := '0';
  begin
    for i in v'range loop
      r := r xor v(i);
    end loop;
    return r;
  end function;

  -- subpacket of one sample at IEC 60958 frame f (V = U = 0)
  function subpacket(l, r : std_logic_vector(15 downto 0); f : natural) return std_logic_vector is
    variable s : std_logic_vector(55 downto 0) := (others => '0');
    variable c : std_logic;
  begin
    c := cs_bit(f);
    s(23 downto 8)  := l;
    s(47 downto 32) := r;
    s(50) := c;
    s(51) := xor_all(l) xor c;
    s(54) := c;
    s(55) := xor_all(r) xor c;
    return s;
  end function;

begin

  process (clk)
    variable k : natural range 0 to 4;
  begin
    if rising_edge(clk) then
      -- sample collection
      k := n;
      if asp_take = '1' then
        k    := 0;
        pres <= "0000";
        bflg <= "0000";
      end if;
      if s_valid = '1' then
        if k < 4 then
          sub(k)  <= subpacket(s_left, s_right, frame);
          pres(k) <= '1';
          if frame = 0 then
            bflg(k) <= '1';
          else
            bflg(k) <= '0';
          end if;
          if frame = 191 then
            frame <= 0;
          else
            frame <= frame + 1;
          end if;
          k := k + 1;
        else
          drop_n <= drop_n + 1;
        end if;
      end if;
      n <= k;

      -- CTS: clk cycles between every C_PER-th sample (a new value wins over acr_take)
      if acr_take = '1' then
        due <= '0';
      end if;
      clk_cnt <= clk_cnt + 1;
      if s_valid = '1' then
        if per_cnt = C_PER - 1 then
          per_cnt <= 0;
          clk_cnt <= to_unsigned(1, clk_cnt'length);
          started <= '1';
          if started = '1' then
            cts <= std_logic_vector(clk_cnt);
            due <= '1';
          end if;
        else
          per_cnt <= per_cnt + 1;
        end if;
      end if;

      if rst = '1' then
        n       <= 0;
        pres    <= "0000";
        bflg    <= "0000";
        frame   <= 0;
        drop_n  <= (others => '0');
        per_cnt <= 0;
        started <= '0';
        due     <= '0';
      end if;
    end if;
  end process;

  asp_hdr <= bflg & "0000" & "0000" & pres & x"02" when pres /= "0000" else (others => '0');
  g_sub : for i in 0 to 3 generate
    asp_sub(56 * i + 55 downto 56 * i) <= sub(i) when pres(i) = '1' else (others => '0');
  end generate;
  acr_due <= due;
  acr_cts <= cts;
  drops   <= std_logic_vector(drop_n);

end architecture rtl;
