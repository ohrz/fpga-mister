-------------------------------------------------------------------------------
-- Title      : I2S receiver, oversampled
-- Project    : fpga-mister (hdmi-tx)
-------------------------------------------------------------------------------
-- File       : i2s_rx.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-29
-------------------------------------------------------------------------------
-- Description:
--   Receives a Philips I2S stream (e.g. MiSTer's sys/i2s.v) in the clk domain
--   (no clock of its own: bclk, lrclk and sdata are synchronised, clk must be
--   at least 4 times bclk; HDMI: 74.25 MHz against 1.536 MHz).
--   Format (as sys/i2s.v): G_BITS bits per channel, MSB first, 2 * G_BITS bclk
--   per frame, lrclk 0 = left, lrclk changes one bit before the MSB, i.e.
--   together with the LSB of the previous word; data and lrclk change near
--   the falling bclk edge and are sampled at the rising edge.
--   At the rising edge on which lrclk differs from the previous edge the word
--   of the previous channel is complete (the bit of this edge is its LSB).
--   After the right word: left, right and a valid pulse of one clk.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity i2s_rx is
  generic (
    G_BITS : positive := 16
  );
  port (
    clk   : in  std_logic;
    bclk  : in  std_logic;             -- asynchronous to clk
    lrclk : in  std_logic;
    sdata : in  std_logic;
    left  : out std_logic_vector(G_BITS - 1 downto 0);
    right : out std_logic_vector(G_BITS - 1 downto 0);
    valid : out std_logic
  );
end entity i2s_rx;

architecture rtl of i2s_rx is

  signal bclk_s  : std_logic_vector(2 downto 0) := "000";
  signal lrclk_s : std_logic_vector(1 downto 0) := "00";
  signal sdata_s : std_logic_vector(1 downto 0) := "00";
  signal lr_last : std_logic := '0';
  signal sr      : std_logic_vector(G_BITS - 1 downto 0) := (others => '0');
  signal left_r  : std_logic_vector(G_BITS - 1 downto 0) := (others => '0');

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of bclk_s, lrclk_s, sdata_s : signal is "TRUE";

begin

  process (clk)
    variable w : std_logic_vector(G_BITS - 1 downto 0);
  begin
    if rising_edge(clk) then
      bclk_s  <= bclk_s(1 downto 0) & bclk;
      lrclk_s <= lrclk_s(0) & lrclk;
      sdata_s <= sdata_s(0) & sdata;
      valid   <= '0';
      if bclk_s(2) = '0' and bclk_s(1) = '1' then  -- rising bclk (same delay as lrclk_s(1), sdata_s(1))
        w  := sr(G_BITS - 2 downto 0) & sdata_s(1);
        sr <= w;
        if lrclk_s(1) /= lr_last then
          if lr_last = '0' then
            left_r <= w;
          else
            left  <= left_r;
            right <= w;
            valid <= '1';
          end if;
        end if;
        lr_last <= lrclk_s(1);
      end if;
    end if;
  end process;

end architecture rtl;
