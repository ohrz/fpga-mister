-------------------------------------------------------------------------------
-- Title      : N64 core profile: replacement of the CPU multiplier
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : cpu_mul.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/cpu_mul.vhd of N64_MiSTer (altera_mult_add) with the same
--   entity and ports.  The original: one 64 x 64 multiplier, representation
--   UNSIGNED with signa = signb = sign (sign '1': both operands two's
--   complement), latency 1 on dataa, datab and the sign inputs (CLOCK0), the
--   output register on CLOCK0, every other register UNREGISTERED.  So the
--   result is valid 2 clock edges after the operands:
--     edge 1  operand register (value1_in, value2_in, sign)
--     edge 2  result register  = low 128 bits of the product
--   Exactly 2: the FPU (rtl/cpu_FPU.vhd, MUL stage 3) takes mul_result 3 edges
--   after cpu.vhd loads mul1/mul2, with the same edge as MUL_start; MULT and
--   DMULT wait longer (hiloWait).
--   The operands are sign- or zero-extended to 65 bits and multiplied as
--   signed numbers; the low 128 bits are the same for both readings.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_mul is
  port (
    clk       : in  std_logic;
    sign      : in  std_logic;                       -- '1': signed operands
    value1_in : in  std_logic_vector(63 downto 0);
    value2_in : in  std_logic_vector(63 downto 0);
    result    : out std_logic_vector(127 downto 0)   -- 2 clock edges after the operands
  );
end entity cpu_mul;

architecture rtl of cpu_mul is
  signal a_r : signed(64 downto 0) := (others => '0');
  signal b_r : signed(64 downto 0) := (others => '0');
  signal p_r : signed(129 downto 0) := (others => '0');
begin

  process (clk)
  begin
    if rising_edge(clk) then
      -- edge 1: operands, extended by the sign bit when sign = '1'
      a_r <= signed((sign and value1_in(63)) & value1_in);
      b_r <= signed((sign and value2_in(63)) & value2_in);
      -- edge 2: product
      p_r <= a_r * b_r;
    end if;
  end process;

  result <= std_logic_vector(p_r(127 downto 0));

end architecture rtl;
