-------------------------------------------------------------------------------
-- Title      : Testbench of the altdpram replacement
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : altdpram_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   The configuration of SNES rtl/mlab.vhd (PPU RANGE_TBL: 5 address, 7 data
--   bits; all generics as there): random writes and reads against a reference.
--   Checks that q follows rdaddress without a clock (asynchronous read), that
--   a write takes effect at the rising edge of inclock and not before, and
--   that wren low does not write.  Ends with "PASS" or a failure.
--   VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity altdpram_tb is
end entity;

architecture tb of altdpram_tb is
  constant AW : positive := 5;
  constant DW : positive := 7;
  signal clk, wren : std_logic := '0';
  signal rdaddress, wraddress : std_logic_vector(AW - 1 downto 0) := (others => '0');
  signal data, q : std_logic_vector(DW - 1 downto 0) := (others => '0');
begin

  dut : entity work.altdpram
    generic map (
      indata_aclr => "OFF", indata_reg => "INCLOCK", intended_device_family => "Cyclone V",
      lpm_type => "altdpram", outdata_aclr => "OFF", outdata_reg => "UNREGISTERED", ram_block_type => "MLAB",
      rdaddress_aclr => "OFF", rdaddress_reg => "UNREGISTERED", rdcontrol_aclr => "OFF",
      rdcontrol_reg => "UNREGISTERED", read_during_write_mode_mixed_ports => "CONSTRAINED_DONT_CARE",
      width => DW, widthad => AW, width_byteena => 1, wraddress_aclr => "OFF", wraddress_reg => "INCLOCK",
      wrcontrol_aclr => "OFF", wrcontrol_reg => "INCLOCK")
    port map (data => data, outclock => clk, rdaddress => rdaddress, wren => wren, inclock => clk,
              wraddress => wraddress, q => q);

  process
    type ref_t is array (0 to 2 ** AW - 1) of std_logic_vector(DW - 1 downto 0);
    variable ref : ref_t := (others => (others => '0'));
    variable s1, s2 : positive := 7;
    variable r : real;
    variable wa, ra, n_wr, n_rd : natural := 0;
    variable d : std_logic_vector(DW - 1 downto 0);
    variable w : boolean;

    impure function rnd(n : natural) return natural is
    begin
      uniform(s1, s2, r);
      return natural(floor(r * real(n)));
    end function;
  begin
    for step in 1 to 20000 loop
      w := rnd(2) = 0;
      wa := rnd(2 ** AW); ra := rnd(2 ** AW);
      d := std_logic_vector(to_unsigned(rnd(2 ** DW), DW));
      wraddress <= std_logic_vector(to_unsigned(wa, AW)); data <= d;
      wren <= '1' when w else '0';
      rdaddress <= std_logic_vector(to_unsigned(ra, AW));
      wait for 1 ns;
      -- asynchronous read, before the clock edge: the old contents
      assert q = ref(ra) report "read before the edge, addr " & integer'image(ra) & ": " & to_hstring(q) &
                                ", expected " & to_hstring(ref(ra)) severity failure;
      clk <= '1';
      if w then ref(wa) := d; n_wr := n_wr + 1; end if;
      wait for 1 ns;
      assert q = ref(ra) report "read after the edge, addr " & integer'image(ra) & ": " & to_hstring(q) &
                                ", expected " & to_hstring(ref(ra)) severity failure;
      -- a second read address without a clock
      ra := rnd(2 ** AW);
      rdaddress <= std_logic_vector(to_unsigned(ra, AW));
      wait for 1 ns;
      assert q = ref(ra) report "read without clock, addr " & integer'image(ra) severity failure;
      n_rd := n_rd + 2;
      clk <= '0';
    end loop;
    report "checked " & integer'image(n_rd) & " reads, " & integer'image(n_wr) & " writes";
    report "PASS";
    wait;
  end process;

end architecture tb;
