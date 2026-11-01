-------------------------------------------------------------------------------
-- Title      : Testbench of the N64 Shiftreg replacement
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : n64_shiftreg_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   cores/n64/Shiftreg.vhd in the two configurations of RDP_pipeline.vhd
--   (DEPTH 7 x 26 bits, DEPTH 8 x 36 bits) and DEPTH 1 against a reference
--   queue: random data and clk_en on every edge; after each edge data_out
--   must be the data_in of the DEPTH-th last enabled edge (zero before that).
--   Ends with "PASS" or a failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity n64_shiftreg_check is
  generic (DEPTH : natural; BITS : natural; SEED : positive);
  port (clk : in std_logic; done : out boolean := false);
end entity;

architecture tb of n64_shiftreg_check is
  signal clk_en   : std_logic := '0';
  signal data_in  : std_logic_vector(BITS-1 downto 0) := (others => '0');
  signal data_out : std_logic_vector(BITS-1 downto 0);
begin

  dut : entity work.Shiftreg
    generic map (USE_BRAM => '1', DEPTH => DEPTH, BITS => BITS)
    port map (clk => clk, clk_en => clk_en, data_in => data_in, data_out => data_out);

  process
    type q_t is array (0 to DEPTH-1) of std_logic_vector(BITS-1 downto 0);
    variable q : q_t := (others => (others => '0'));          -- q(0): last enabled input
    variable s1 : positive := SEED;
    variable s2 : positive := 3;
    variable r : real;
    variable n : natural := 0;
    variable d : std_logic_vector(BITS-1 downto 0);
  begin
    wait until falling_edge(clk);
    for k in 1 to 5000 loop
      for b in 0 to BITS-1 loop
        uniform(s1, s2, r);
        d(b) := '1' when r < 0.5 else '0';
      end loop;
      uniform(s1, s2, r);
      clk_en <= '1' when r < 0.6 else '0';
      data_in <= d;
      wait until rising_edge(clk);
      if clk_en = '1' then
        q := d & q(0 to DEPTH-2);                         -- null slice for DEPTH 1
        n := n + 1;
      end if;
      wait for 1 ns;
      assert data_out = q(DEPTH-1)
        report "DEPTH " & integer'image(DEPTH) & " after " & integer'image(n) & " enabled edges: " &
               to_hstring(data_out) & ", expected " & to_hstring(q(DEPTH-1)) severity failure;
      wait until falling_edge(clk);
    end loop;
    report "DEPTH " & integer'image(DEPTH) & " x " & integer'image(BITS) & ": " & integer'image(n) & " shifts";
    done <= true;
    wait;
  end process;

end architecture tb;

library ieee;
use ieee.std_logic_1164.all;

entity n64_shiftreg_tb is
end entity;

architecture tb of n64_shiftreg_tb is
  signal clk : std_logic := '0';
  signal d1, d7, d8 : boolean;
begin

  clk <= not clk after 5 ns when not (d1 and d7 and d8);

  palette : entity work.n64_shiftreg_check generic map (DEPTH => 7, BITS => 26, SEED => 1) port map (clk, d7);
  texsel  : entity work.n64_shiftreg_check generic map (DEPTH => 8, BITS => 36, SEED => 2) port map (clk, d8);
  single  : entity work.n64_shiftreg_check generic map (DEPTH => 1, BITS => 4, SEED => 3) port map (clk, d1);

  process
  begin
    wait until d1 and d7 and d8;
    report "PASS";
    wait;
  end process;

end architecture tb;
