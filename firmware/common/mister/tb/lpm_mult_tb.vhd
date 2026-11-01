-------------------------------------------------------------------------------
-- Title      : Testbench of the lpm_mult replacement
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : lpm_mult_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Four configurations against integer arithmetic: SNES rtl/chip/SA1/SA1MULT
--   (SIGNED 16 x 16 -> 32, generics as there, random operands plus the corner
--   values), UNSIGNED 16 x 16 -> 32, and 6 x 5 bit SIGNED with a narrower
--   (8 bit: upper bits) and a wider (14 bit: sign extended) result, both
--   exhaustive.  Ends with "PASS" or a failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity lpm_mult_tb is
end entity;

architecture tb of lpm_mult_tb is
  signal a16, b16 : std_logic_vector(15 downto 0) := (others => '0');
  signal ps, pu : std_logic_vector(31 downto 0);
  signal a6 : std_logic_vector(5 downto 0) := (others => '0');
  signal b5 : std_logic_vector(4 downto 0) := (others => '0');
  signal pn : std_logic_vector(7 downto 0);
  signal pw : std_logic_vector(13 downto 0);
begin

  sa1 : entity work.lpm_mult
    generic map (lpm_hint => "MAXIMIZE_SPEED=5", lpm_representation => "SIGNED", lpm_type => "LPM_MULT",
                 lpm_widtha => 16, lpm_widthb => 16, lpm_widthp => 32)
    port map (dataa => a16, datab => b16, result => ps);
  uns : entity work.lpm_mult
    generic map (lpm_representation => "UNSIGNED", lpm_widtha => 16, lpm_widthb => 16, lpm_widthp => 32)
    port map (dataa => a16, datab => b16, result => pu);
  narrow : entity work.lpm_mult
    generic map (lpm_representation => "SIGNED", lpm_widtha => 6, lpm_widthb => 5, lpm_widthp => 8)
    port map (dataa => a6, datab => b5, result => pn);
  wide : entity work.lpm_mult
    generic map (lpm_representation => "SIGNED", lpm_widtha => 6, lpm_widthb => 5, lpm_widthp => 14)
    port map (dataa => a6, datab => b5, result => pw);

  process
    variable s1, s2 : positive := 11;
    variable r : real;
    variable n : natural := 0;
    type corner_t is array (0 to 5) of integer;
    constant CORNER : corner_t := (-32768, -32767, -1, 0, 1, 32767);

    impure function rnd(lo, hi : integer) return integer is
    begin
      uniform(s1, s2, r);
      return lo + integer(floor(r * real(hi - lo + 1)));
    end function;

    procedure check16(x, y : integer) is
      variable ux, uy : natural;
    begin
      a16 <= std_logic_vector(to_signed(x, 16)); b16 <= std_logic_vector(to_signed(y, 16));
      wait for 1 ns;
      assert signed(ps) = to_signed(x, 16) * to_signed(y, 16)
        report "SIGNED " & integer'image(x) & " * " & integer'image(y) & " = " & to_hstring(ps) severity failure;
      ux := to_integer(unsigned(a16)); uy := to_integer(unsigned(b16));
      assert unsigned(pu) = to_unsigned(ux, 16) * to_unsigned(uy, 16)
        report "UNSIGNED " & integer'image(ux) & " * " & integer'image(uy) & " = " & to_hstring(pu)
        severity failure;
      n := n + 1;
    end procedure;
  begin
    for i in CORNER'range loop
      for j in CORNER'range loop
        check16(CORNER(i), CORNER(j));
      end loop;
    end loop;
    for k in 1 to 20000 loop
      check16(rnd(-32768, 32767), rnd(-32768, 32767));
    end loop;

    for x in -32 to 31 loop
      for y in -16 to 15 loop
        a6 <= std_logic_vector(to_signed(x, 6)); b5 <= std_logic_vector(to_signed(y, 5));
        wait for 1 ns;
        assert signed(pw) = to_signed(x * y, 14)
          report "wide " & integer'image(x) & " * " & integer'image(y) & " = " & to_hstring(pw) severity failure;
        -- 11 bit product, the upper 8 bits
        assert pn = std_logic_vector(to_signed(x * y, 11)(10 downto 3))
          report "narrow " & integer'image(x) & " * " & integer'image(y) & " = " & to_hstring(pn) severity failure;
        n := n + 1;
      end loop;
    end loop;
    report "checked " & integer'image(n) & " products";
    report "PASS";
    wait;
  end process;

end architecture tb;
