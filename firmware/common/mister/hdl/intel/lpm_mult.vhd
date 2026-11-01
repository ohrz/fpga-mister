-------------------------------------------------------------------------------
-- Title      : Replacement of the Intel megafunction lpm_mult for Vivado
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : lpm_mult.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Same name, generics and ports as the Intel lpm_mult, so MiSTer sources that
--   instantiate it (SNES rtl/chip/SA1/SA1MULT.vhd) stay unchanged.  The subset
--   these sources use is implemented; any other setting stops the synthesis
--   with an assertion:
--     lpm_pipeline     0: combinational product (clock, clken, aclr unused)
--     representation   SIGNED or UNSIGNED (both operands alike)
--     lpm_widthp       the product has lpm_widtha + lpm_widthb bits; a
--                      narrower result keeps its upper bits (as on Intel), a
--                      wider one is sign or zero extended
--   Not supported: sum input (lpm_widths), pipeline stages.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity lpm_mult is
  generic (
    lpm_widtha         : natural := 16;
    lpm_widthb         : natural := 16;
    lpm_widthp         : natural := 32;
    lpm_widths         : natural := 1;
    lpm_representation : string  := "UNSIGNED";
    lpm_pipeline       : natural := 0;
    lpm_type           : string  := "LPM_MULT";
    lpm_hint           : string  := "UNUSED"
  );
  port (
    dataa  : in  std_logic_vector(lpm_widtha - 1 downto 0);
    datab  : in  std_logic_vector(lpm_widthb - 1 downto 0);
    sum    : in  std_logic_vector(lpm_widths - 1 downto 0) := (others => '0');
    clock  : in  std_logic := '0';
    clken  : in  std_logic := '1';
    aclr   : in  std_logic := '0';
    result : out std_logic_vector(lpm_widthp - 1 downto 0)
  );
end entity lpm_mult;

architecture rtl of lpm_mult is

  constant C_SIGNED : boolean := lpm_representation = "SIGNED";
  constant C_W      : natural := lpm_widtha + lpm_widthb;

  signal p : std_logic_vector(C_W - 1 downto 0);

begin

  assert lpm_pipeline = 0
    report "lpm_mult: pipeline stages not supported" severity failure;
  assert lpm_representation = "SIGNED" or lpm_representation = "UNSIGNED"
    report "lpm_mult: representation " & lpm_representation & " not supported" severity failure;

  g_s : if C_SIGNED generate
    p <= std_logic_vector(signed(dataa) * signed(datab));
  end generate;
  g_u : if not C_SIGNED generate
    p <= std_logic_vector(unsigned(dataa) * unsigned(datab));
  end generate;

  g_narrow : if lpm_widthp <= C_W generate
    result <= p(C_W - 1 downto C_W - lpm_widthp);
  end generate;
  g_wide : if lpm_widthp > C_W generate
    result(C_W - 1 downto 0)          <= p;
    result(lpm_widthp - 1 downto C_W) <= (others => p(C_W - 1)) when C_SIGNED else (others => '0');
  end generate;

end architecture rtl;
