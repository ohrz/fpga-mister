-------------------------------------------------------------------------------
-- Title      : Menu core profile: replacement of rtl/lfsr.v (clocked LFSR)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : lfsr.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   rtl/lfsr.v of Menu_MiSTer is no register: a ring of N Cyclone V lcell
--   buffers with the XNOR feedback of an LFSR, a free-running combinational
--   loop used as noise source for the background picture.  Vivado would need
--   a combinational loop (DRC LUTLP-1), so this is the same shift structure as
--   a clocked Fibonacci LFSR with the same taps, one step per clk.
--   menu.sv samples rnd once per pixel (every 8th CLK_VIDEO cycle) and uses
--   bits 2:0, so every pixel gets 3 new bits.  prepare_sources.py gives the
--   instance the clock (rule lfsr-clock: clk => CLK_VIDEO).
--   XNOR feedback: the all-zero start state is valid (all ones would lock).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity lfsr is
  generic (
    N : positive := 63
  );
  port (
    clk : in  std_logic;
    rnd : out std_logic_vector(N - 1 downto 0)
  );
end entity lfsr;

architecture rtl of lfsr is
  signal r : std_logic_vector(N - 1 downto 0) := (others => '0');
begin

  process (clk)
  begin
    if rising_edge(clk) then
      r <= r(N - 2 downto 0) & not (r(N - 1) xor r(N - 3) xor r(N - 4) xor r(N - 6) xor r(N - 10));
    end if;
  end process;

  rnd <= r;

end architecture rtl;
