-------------------------------------------------------------------------------
-- Title      : Testbench of the N64 memory address adder (forwarding after the add)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : n64_cpu_addr_fwd_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-31
-------------------------------------------------------------------------------
-- Description:
--   cores/n64/cpu_addr_fwd.vhd against the expression of rtl/cpu.vhd it
--   replaces (forwarding mux first, then value1 + sign_extend(imm)).  Every
--   combination of the three select inputs with random operands and corner
--   values (0, all ones, 2^63, 2^31, carries through 32 and 64 bits, negative
--   immediates), the three sources always different, so that a wrong select
--   shows.  Ends with "PASS" or a failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity n64_cpu_addr_fwd_tb is
end entity;

architecture tb of n64_cpu_addr_fwd_tb is
  signal res, wb, dec, addr : unsigned(63 downto 0) := (others => '0');
  signal imm                : unsigned(15 downto 0) := (others => '0');
  signal fwd_ex, we, fwd_wb : std_logic := '0';

  type corner_t is array (natural range <>) of unsigned(63 downto 0);
  constant C_CORNER : corner_t := (x"0000000000000000", x"FFFFFFFFFFFFFFFF", x"8000000000000000",
                                   x"0000000080000000", x"00000000FFFFFFFF", x"7FFFFFFFFFFFFFFF",
                                   x"FFFFFFFF80000000", x"FFFFFFFFFFFF8000", x"0000000000007FFF");
  type imm_t is array (natural range <>) of unsigned(15 downto 0);
  constant C_IMM : imm_t := (x"0000", x"0001", x"7FFF", x"8000", x"FFFF", x"FFFC");
begin

  dut : entity work.n64_cpu_addr_fwd
    port map (
      resultData => res, writebackData => wb, decodeValue1 => dec, decodeImmData => imm,
      executeForwardValue1 => fwd_ex, resultWriteEnable => we, writebackForwardValue1 => fwd_wb,
      calcMemAddr => addr);

  process
    variable s1, s2 : positive := 7;
    variable n      : natural := 0;

    impure function rnd64 return unsigned is
      variable r : real;
      variable v : unsigned(63 downto 0);
    begin
      for i in 0 to 3 loop
        uniform(s1, s2, r);
        v(16 * i + 15 downto 16 * i) := to_unsigned(integer(trunc(r * 65536.0)) mod 65536, 16);
      end loop;
      return v;
    end function;

    procedure check(r, w, d : unsigned(63 downto 0); i : unsigned(15 downto 0)) is
      variable value1, expect : unsigned(63 downto 0);
    begin
      res <= r; wb <= w; dec <= d; imm <= i;
      for sel in 0 to 7 loop
        fwd_ex <= '1' when (sel / 4) mod 2 = 1 else '0';
        we     <= '1' when (sel / 2) mod 2 = 1 else '0';
        fwd_wb <= '1' when sel mod 2 = 1 else '0';
        wait for 1 ns;
        -- cpu.vhd: value1 <= resultData when (executeForwardValue1 = '1' and resultWriteEnable = '1') else
        --          writebackData when (writebackForwardValue1 = '1') else decodeValue1;
        if fwd_ex = '1' and we = '1' then value1 := r;
        elsif fwd_wb = '1' then value1 := w;
        else value1 := d;
        end if;
        expect := value1 + unsigned(resize(signed(i), 64));
        assert addr = expect
          report "calcMemAddr " & to_hstring(addr) & " /= " & to_hstring(expect) & " (sel " & integer'image(sel) & ")"
          severity failure;
        n := n + 1;
      end loop;
    end procedure;
  begin
    -- corner values: each corner as each source, the other two sources derived and different
    for c in C_CORNER'range loop
      for k in C_IMM'range loop
        check(C_CORNER(c), C_CORNER(c) xor x"0000000000000010", C_CORNER(c) xor x"0000001000000000", C_IMM(k));
        check(C_CORNER(c) xor x"0000000000000020", C_CORNER(c), C_CORNER(c) xor x"0000000000000040", C_IMM(k));
        check(C_CORNER(c) xor x"0000002000000000", C_CORNER(c) xor x"0000000000000080", C_CORNER(c), C_IMM(k));
      end loop;
    end loop;
    -- random operands
    for t in 1 to 4000 loop
      check(rnd64, rnd64, rnd64, rnd64(15 downto 0));
    end loop;
    report "checked " & integer'image(n) & " cases";
    report "PASS";
    wait;
  end process;

end architecture tb;
