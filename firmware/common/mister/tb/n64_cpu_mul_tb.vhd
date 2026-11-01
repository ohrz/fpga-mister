-------------------------------------------------------------------------------
-- Title      : Testbench of the N64 cpu_mul replacement
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : n64_cpu_mul_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   cores/n64/cpu_mul.vhd against a reference that does not use the "*" of
--   numeric_std: the unsigned product from 8-bit limbs (integer arithmetic),
--   for sign = '1' minus b * 2^64 when a is negative and minus a * 2^64 when b
--   is negative (mod 2^128).  New operands and sign on every clock edge
--   (random values plus corner values: 0, 1, -1, 2^63, 2^63-1, 2^32-1),
--   changed after each rising edge as a register (cpu.vhd mul1/mul2) would:
--   the result after edge n must be the product of the operands sampled at
--   edge n-1, the values the operand register took after edge n-2.
--   Ends with "PASS" or a failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity n64_cpu_mul_tb is
end entity;

architecture tb of n64_cpu_mul_tb is
  signal clk    : std_logic := '0';
  signal sign   : std_logic := '0';
  signal v1, v2 : std_logic_vector(63 downto 0) := (others => '0');
  signal result : std_logic_vector(127 downto 0);
  signal done   : boolean := false;

  -- unsigned 64 x 64 -> 128 from 8-bit limbs
  function umul(a, b : std_logic_vector(63 downto 0)) return unsigned is
    type acc_t is array (0 to 16) of natural;
    variable acc : acc_t := (others => 0);
    variable p   : unsigned(127 downto 0);
    variable c   : natural := 0;
  begin
    for i in 0 to 7 loop
      for j in 0 to 7 loop
        acc(i + j) := acc(i + j) + to_integer(unsigned(a(8*i+7 downto 8*i))) * to_integer(unsigned(b(8*j+7 downto 8*j)));
      end loop;
    end loop;
    for k in 0 to 15 loop
      c := c + acc(k);
      p(8*k+7 downto 8*k) := to_unsigned(c mod 256, 8);
      c := c / 256;
    end loop;
    return p;
  end function;

  function ref(s : std_logic; a, b : std_logic_vector(63 downto 0)) return std_logic_vector is
    variable p : unsigned(127 downto 0) := umul(a, b);
  begin
    if s = '1' and a(63) = '1' then
      p := p - (unsigned(b) & to_unsigned(0, 64));
    end if;
    if s = '1' and b(63) = '1' then
      p := p - (unsigned(a) & to_unsigned(0, 64));
    end if;
    return std_logic_vector(p);
  end function;
begin

  clk <= not clk after 5 ns when not done;

  dut : entity work.cpu_mul
    port map (clk => clk, sign => sign, value1_in => v1, value2_in => v2, result => result);

  process
    type ops_t is array (0 to 1) of std_logic_vector(128 downto 0);   -- sign & v1 & v2 per edge
    variable hist  : ops_t := (others => (others => '0'));
    variable s1, s2 : positive := 7;
    variable r : real;
    variable n : natural := 0;
    type corner_t is array (0 to 5) of std_logic_vector(63 downto 0);
    constant CORNER : corner_t := (x"0000000000000000", x"0000000000000001", x"FFFFFFFFFFFFFFFF",
                                   x"8000000000000000", x"7FFFFFFFFFFFFFFF", x"00000000FFFFFFFF");

    impure function rnd64 return std_logic_vector is
      variable v : std_logic_vector(63 downto 0);
    begin
      for k in 0 to 3 loop
        uniform(s1, s2, r);
        v(16*k+15 downto 16*k) := std_logic_vector(to_unsigned(integer(floor(r * 65536.0)), 16));
      end loop;
      return v;
    end function;

    procedure step(s : std_logic; a, b : std_logic_vector(63 downto 0)) is
      variable exp : std_logic_vector(127 downto 0);
      variable op  : std_logic_vector(128 downto 0);
    begin
      sign <= s; v1 <= a; v2 <= b;
      wait until rising_edge(clk);
      op := s & a & b;
      hist := op & hist(0 to 0);
      wait for 1 ns;
      -- after this edge: the operands sampled at the edge before (hist(1))
      if n >= 1 then
        exp := ref(hist(1)(128), hist(1)(127 downto 64), hist(1)(63 downto 0));
        assert result = exp
          report "sign " & std_logic'image(hist(1)(128)) & " " & to_hstring(hist(1)(127 downto 64)) & " * " &
                 to_hstring(hist(1)(63 downto 0)) & " = " & to_hstring(result) & ", expected " & to_hstring(exp)
          severity failure;
      end if;
      n := n + 1;
    end procedure;

    variable s : std_logic;
  begin
    wait until falling_edge(clk);
    for k in 0 to 1 loop
      s := '1' when k = 1 else '0';
      for i in CORNER'range loop
        for j in CORNER'range loop
          step(s, CORNER(i), CORNER(j));
        end loop;
      end loop;
    end loop;
    for k in 1 to 20000 loop
      uniform(s1, s2, r);
      s := '1' when r < 0.5 else '0';
      step(s, rnd64, rnd64);
    end loop;
    -- 32-bit operands as cpu.vhd forms them for MULT (sign extended) and MULTU
    for k in 1 to 2000 loop
      step('1', std_logic_vector(resize(signed(rnd64(31 downto 0)), 64)),
                std_logic_vector(resize(signed(rnd64(31 downto 0)), 64)));
      step('0', x"00000000" & rnd64(31 downto 0), x"00000000" & rnd64(31 downto 0));
    end loop;
    step('0', CORNER(0), CORNER(0));
    report "checked " & integer'image(n - 1) & " products, latency 2";
    report "PASS";
    done <= true;
    wait;
  end process;

end architecture tb;
