-------------------------------------------------------------------------------
-- Title      : Slim audio path: core audio straight to I2S
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : audio_i2s_simple.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Replaces sys/audio_out.v in sys_top_zynq with the Verilog macro
--   MISTER_ZYNQ_SIMPLE_AUDIO (prepare_sources.py), for a core at the area
--   limit (N64: audio_out is about 1.6k LUT, most of it the IIR filter).
--   Keeps of audio_out only what the I2S output needs, the same way:
--     - core_l/core_r into the clk domain: two registers, taken over when both
--       agree (a sample that changes during the transfer is not torn)
--     - unsigned core audio (is_signed = 0) to two's complement: MSB inverted
--     - I2S as sys/i2s.v at 48 kHz (audio_out with sample_rate 0) on
--       clk = 24.576 MHz: bit clock enable every 8 clk, bclk = clk / 16 =
--       1.536 MHz, 16 bits per channel, MSB first, 32 bclk per frame, lrclk
--       0 = left, lrclk changes together with the LSB of the previous word
--       (Philips I2S, one bclk before the MSB), data and lrclk change at the
--       falling bclk edge; both words are taken over at the start of the
--       left word
--   Without: IIR low pass, DC blocker, volume and mixing (OSD volume and
--   MiSTer.ini audio filters have no effect), 96 kHz, S/PDIF, sigma-delta
--   DAC (the Zynq boards have none).  The receivers are the I2S codec and
--   hdmi_out (hdmi-tx i2s_rx), both on this I2S.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity audio_i2s_simple is
  port (
    clk       : in  std_logic;                      -- clk_audio, 24.576 MHz
    reset     : in  std_logic;                      -- synchronous, as audio_out's i2s
    is_signed : in  std_logic;                      -- core audio in two's complement
    core_l    : in  std_logic_vector(15 downto 0);  -- core audio (core clock domain)
    core_r    : in  std_logic_vector(15 downto 0);
    i2s_bclk  : out std_logic;
    i2s_lrclk : out std_logic;
    i2s_data  : out std_logic
  );
end entity audio_i2s_simple;

architecture rtl of audio_i2s_simple is
  constant C_BITS : positive := 16;

  signal cl1, cl2, cl : std_logic_vector(15 downto 0) := (others => '0');
  signal cr1, cr2, cr : std_logic_vector(15 downto 0) := (others => '0');
  signal ce_cnt       : unsigned(2 downto 0) := (others => '0');
  signal ce           : std_logic := '0';
  signal msclk        : std_logic := '1';
  signal sclk         : std_logic := '1';
  signal lrclk        : std_logic := '1';
  signal sdata        : std_logic := '0';
  signal bit_cnt      : unsigned(7 downto 0) := to_unsigned(1, 8);
  signal left, right  : std_logic_vector(C_BITS - 1 downto 0) := (others => '0');

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of cl1, cl2, cr1, cr2 : signal is "TRUE";
begin

  -- core audio into the clk domain, taken when two samples in a row agree (audio_out cl/cr)
  process (clk)
  begin
    if rising_edge(clk) then
      cl1 <= core_l; cl2 <= cl1;
      if cl2 = cl1 then cl <= cl2; end if;
      cr1 <= core_r; cr2 <= cr1;
      if cr2 = cr1 then cr <= cr2; end if;
    end if;
  end process;

  -- bit clock enable: every 8 clk (audio_out: mclk_ce every 4 clk at 48 kHz, i2s_ce every 2nd)
  process (clk)
  begin
    if rising_edge(clk) then
      ce_cnt <= ce_cnt + 1;
      ce <= '0';
      if ce_cnt = 7 then
        ce <= '1';
      end if;
    end if;
  end process;

  -- sys/i2s.v
  process (clk)
    variable idx : natural range 0 to C_BITS - 1;
  begin
    if rising_edge(clk) then
      if reset = '1' then
        bit_cnt <= to_unsigned(1, 8);
        lrclk   <= '1';
        sclk    <= '1';
        msclk   <= '1';
      else
        sclk <= msclk;
        if ce = '1' then
          msclk <= not msclk;
          if msclk = '1' then
            if bit_cnt >= C_BITS then
              bit_cnt <= to_unsigned(1, 8);
              lrclk   <= not lrclk;
              if lrclk = '1' then
                -- start of the left word: both channels, signed (audio_out: ~is_signed ^ MSB)
                left  <= (cl(15) xor not is_signed) & cl(14 downto 0);
                right <= (cr(15) xor not is_signed) & cr(14 downto 0);
              end if;
            else
              bit_cnt <= bit_cnt + 1;
            end if;
            idx := C_BITS - to_integer(bit_cnt);
            if lrclk = '1' then
              sdata <= right(idx);
            else
              sdata <= left(idx);
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  i2s_bclk  <= sclk;
  i2s_lrclk <= lrclk;
  i2s_data  <= sdata;

end architecture rtl;
