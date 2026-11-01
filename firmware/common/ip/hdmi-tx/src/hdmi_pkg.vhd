-------------------------------------------------------------------------------
-- Title      : HDMI symbol tables (TMDS control tokens, TERC4, guard bands, ECC)
-- Project    : fpga-mister (hdmi-tx)
-------------------------------------------------------------------------------
-- File       : hdmi_pkg.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-29
-------------------------------------------------------------------------------
-- Description:
--   Constants and functions of the HDMI 1.4 link layer used by hdmi_tx.
--   10-bit symbols are written q(9 downto 0); q(0) is sent first.
--   Control tokens as in DVI (rgb2dvi DVI_Constants), TERC4 table, video and
--   data island guard bands (HDMI 1.4 5.4.2, 5.4.3, 5.2.2.1, 5.2.3.3).
--   ECC: BCH code of the data island packets, generator x^8 + x^7 + x^6 + 1,
--   computed LSB first; the 8 parity bits follow the data, bit 0 first
--   (cross-checked against two implementations and a polynomial division,
--   README.md).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package hdmi_pkg is

  subtype sym_t is std_logic_vector(9 downto 0);

  -- control token for (C1, C0)
  function ctrl_token(c : std_logic_vector(1 downto 0)) return sym_t;
  -- TERC4 symbol of a nibble D3..D0
  function terc4(d : std_logic_vector(3 downto 0)) return sym_t;

  constant C_VGB_02 : sym_t := "1011001100";   -- video guard band, channels 0 and 2
  constant C_VGB_1  : sym_t := "0100110011";   -- video guard band, channel 1
  constant C_DGB_12 : sym_t := "0100110011";   -- data island guard band, channels 1 and 2
                                               -- (channel 0: terc4("11" & vs & hs))

  -- one ECC step: parity register p (LSB first) with the next data bit b
  function ecc_step(p : std_logic_vector(7 downto 0); b : std_logic) return std_logic_vector;

end package hdmi_pkg;

package body hdmi_pkg is

  function ctrl_token(c : std_logic_vector(1 downto 0)) return sym_t is
  begin
    case c is
      when "00"   => return "1101010100";
      when "01"   => return "0010101011";
      when "10"   => return "0101010100";
      when others => return "1010101011";
    end case;
  end function;

  function terc4(d : std_logic_vector(3 downto 0)) return sym_t is
  begin
    case d is
      when "0000" => return "1010011100";
      when "0001" => return "1001100011";
      when "0010" => return "1011100100";
      when "0011" => return "1011100010";
      when "0100" => return "0101110001";
      when "0101" => return "0100011110";
      when "0110" => return "0110001110";
      when "0111" => return "0100111100";
      when "1000" => return "1011001100";
      when "1001" => return "0100111001";
      when "1010" => return "0110011100";
      when "1011" => return "1011000110";
      when "1100" => return "1010001110";
      when "1101" => return "1001110001";
      when "1110" => return "0101100011";
      when others => return "1011000011";
    end case;
  end function;

  function ecc_step(p : std_logic_vector(7 downto 0); b : std_logic) return std_logic_vector is
    variable r : std_logic_vector(7 downto 0);
  begin
    r := '0' & p(7 downto 1);
    if (p(0) xor b) = '1' then
      r := r xor "10000011";
    end if;
    return r;
  end function;

end package body hdmi_pkg;
