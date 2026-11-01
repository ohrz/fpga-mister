-------------------------------------------------------------------------------
-- Title      : Testbench of the altddio_out replacement
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : altddio_out_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Random datain_h/datain_l, changed in the middle of the high phase as well,
--   and random sclr/sset/outclocken.  Checks that dataout shows the datain_h
--   value of the last rising edge while outclock is high and its datain_l value
--   while outclock is low (Intel semantics: both taken on the rising edge), the
--   synchronous clear/set and the clock enable.  The MiSTer use (datain_h = 0,
--   datain_l = 1: inverted clock) is one of the cases.  Ends with "PASS" or a
--   failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity altddio_out_tb is
end entity;

architecture tb of altddio_out_tb is
  signal clk : std_logic := '0';
  signal h, l, q : std_logic_vector(3 downto 0) := (others => '0');
  signal ce, sclr, sset : std_logic := '0';
begin

  dut : entity work.altddio_out
    generic map (width => 4, intended_device_family => "Cyclone V", lpm_type => "altddio_out")
    port map (datain_h => h, datain_l => l, outclock => clk, outclocken => ce, sclr => sclr, sset => sset,
              dataout => q, oe_out => open);

  process
    variable s1, s2 : positive := 9;
    variable r : real;
    variable rh, rl : std_logic_vector(3 downto 0) := (others => '0');   -- model registers

    impure function rnd(n : natural) return natural is
    begin
      uniform(s1, s2, r);
      return natural(floor(r * real(n)));
    end function;
  begin
    for i in 1 to 5000 loop
      -- inputs for the coming rising edge
      if i mod 7 = 0 then
        h <= "0000"; l <= "1111";                                          -- the SDRAM_CLK use
      else
        h <= std_logic_vector(to_unsigned(rnd(16), 4)); l <= std_logic_vector(to_unsigned(rnd(16), 4));
      end if;
      ce <= '1' when rnd(8) /= 0 else '0';
      sclr <= '1' when rnd(30) = 0 else '0';
      sset <= '1' when rnd(30) = 0 else '0';
      wait for 2 ns;
      clk <= '1';
      wait for 0 ns;                                                       -- the model takes the same inputs
      if ce = '1' then
        if sclr = '1' then rh := "0000"; rl := "0000";
        elsif sset = '1' then rh := "1111"; rl := "1111";
        else rh := h; rl := l; end if;
      end if;
      wait for 1 ns;
      assert q = rh report "high phase: " & to_hstring(q) & ", expected " & to_hstring(rh) severity failure;
      h <= not h; l <= not l;                                              -- change in the high phase
      wait for 2 ns;
      assert q = rh report "high phase after input change" severity failure;
      clk <= '0';
      wait for 1 ns;
      assert q = rl report "low phase: " & to_hstring(q) & ", expected " & to_hstring(rl) severity failure;
      wait for 1 ns;
    end loop;
    report "PASS: 5000 cycles";
    wait;
  end process;

end architecture tb;
