-------------------------------------------------------------------------------
-- Title      : Testbench of kr260_dp_live
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : kr260_dp_live_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-11-26
-- Standard   : VHDL-2008
-------------------------------------------------------------------------------
-- Description:
--   Drives random pixels and syncs into kr260_dp_live and compares each output
--   with a reference model one clock later: the field of each component for
--   G_ORDER, the 8 to 12 bit expansion and the sync polarity. The model
--   addresses single bits (no slices of the DUT's helper), so a wrong field,
--   a wrong bit order, a missing expansion or a missing register stage fails.
--   Prints "kr260_dp_live_tb: PASS" after 4000 checked pixels.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity kr260_dp_live_tb is
  generic (
    G_ORDER  : integer := 0;
    G_HS_INV : boolean := false;
    G_VS_INV : boolean := false
  );
end entity;

architecture sim of kr260_dp_live_tb is

  constant C_N : integer := 4000;

  signal clk      : std_logic := '0';
  signal vid_data : std_logic_vector(23 downto 0) := (others => '0');
  signal vid_de, vid_hs, vid_vs : std_logic := '0';
  signal dp_pixel : std_logic_vector(35 downto 0);
  signal dp_de, dp_hs, dp_vs : std_logic;
  signal done     : boolean := false;

  -- field f (2 = bits 35..24, 1 = 23..12, 0 = 11..0) of a component value c (8 bit)
  function expect_field (c : std_logic_vector(7 downto 0)) return std_logic_vector is
    variable v : std_logic_vector(11 downto 0);
  begin
    for i in 0 to 7 loop
      v(i + 4) := c(i);
    end loop;
    for i in 0 to 3 loop
      v(i) := c(i + 4);
    end loop;
    return v;
  end function;

  function b2sl (x : boolean) return std_logic is
  begin
    if x then return '1'; else return '0'; end if;
  end function;

begin

  dut : entity work.kr260_dp_live
    generic map (G_ORDER => G_ORDER, G_HS_INV => G_HS_INV, G_VS_INV => G_VS_INV)
    port map (clk_pix => clk, vid_data => vid_data, vid_de => vid_de, vid_hs => vid_hs,
              vid_vs => vid_vs, dp_pixel => dp_pixel, dp_de => dp_de, dp_hs => dp_hs, dp_vs => dp_vs);

  clk <= not clk after 5 ns when not done;

  process
    variable s1, s2 : positive := 7;
    variable rnd    : real;
    variable d      : std_logic_vector(23 downto 0);
    variable de, hs, vs : std_logic;
    variable r, g, b : std_logic_vector(7 downto 0);
    variable hi, mid, lo : std_logic_vector(7 downto 0);
    variable exp    : std_logic_vector(35 downto 0);
    variable errors : integer := 0;
    impure function rbit return std_logic is
    begin
      uniform(s1, s2, rnd);
      if rnd < 0.5 then return '0'; else return '1'; end if;
    end function;
  begin
    wait until rising_edge(clk);
    for n in 0 to C_N loop
      -- new input for this clock
      for i in 0 to 23 loop
        d(i) := rbit;
      end loop;
      de := rbit; hs := rbit; vs := rbit;
      vid_data <= d; vid_de <= de; vid_hs <= hs; vid_vs <= vs;
      wait until rising_edge(clk);
      wait for 1 ns;
      -- the output now shows the input of the previous clock edge (d, de, hs, vs)
      r := d(23 downto 16); b := d(15 downto 8); g := d(7 downto 0);
      case G_ORDER is
        when 1      => hi := b; mid := g; lo := r;
        when 2      => hi := g; mid := b; lo := r;
        when others => hi := r; mid := g; lo := b;
      end case;
      exp := expect_field(hi) & expect_field(mid) & expect_field(lo);
      if dp_pixel /= exp then
        errors := errors + 1;
        if errors < 5 then
          report "pixel " & integer'image(n) & ": got " & to_hstring(dp_pixel) & " expected " & to_hstring(exp)
            severity error;
        end if;
      end if;
      if dp_de /= de or dp_hs /= (hs xor b2sl(G_HS_INV)) or dp_vs /= (vs xor b2sl(G_VS_INV)) then
        errors := errors + 1;
        if errors < 5 then
          report "pixel " & integer'image(n) & ": sync/de wrong" severity error;
        end if;
      end if;
    end loop;
    if errors = 0 then
      report "kr260_dp_live_tb: PASS (" & integer'image(C_N) & " pixels, G_ORDER " & integer'image(G_ORDER) & ")";
    else
      report "kr260_dp_live_tb: FAIL (" & integer'image(errors) & " errors)" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture;
