-------------------------------------------------------------------------------
-- Title      : N64 core profile: replacement of the RDP pipeline shift register
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : Shiftreg.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/Shiftreg.vhd of N64_MiSTer (altshift_taps, number_of_taps 1,
--   tap_distance DEPTH, in M10K or MLAB by USE_BRAM) with the same entity and
--   ports: a chain of DEPTH registers, shifted when clk_en = '1'; data_out is
--   the last register (shiftout of altshift_taps, the input of DEPTH enabled
--   edges before).  RDP_pipeline.vhd carries addresses and colours with it
--   (DEPTH 7 and 8).  USE_BRAM only chose the Intel memory type: Vivado puts
--   a short chain into SRLs either way.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity Shiftreg is
  generic (
    USE_BRAM : std_logic;                                   -- unused (Intel memory type)
    DEPTH    : natural;                                     -- registers, at least 1
    BITS     : natural
  );
  port (
    clk      : in  std_logic;
    clk_en   : in  std_logic;
    data_in  : in  std_logic_vector(BITS-1 downto 0);
    data_out : out std_logic_vector(BITS-1 downto 0)        -- data_in of DEPTH enabled edges before
  );
end entity Shiftreg;

architecture rtl of Shiftreg is
  type chain_t is array (0 to DEPTH-1) of std_logic_vector(BITS-1 downto 0);
  signal chain : chain_t := (others => (others => '0'));
begin

  assert DEPTH >= 1 report "Shiftreg: DEPTH must be at least 1" severity failure;

  process (clk)
  begin
    if rising_edge(clk) then
      if clk_en = '1' then
        chain(0) <= data_in;
        for i in 1 to DEPTH-1 loop
          chain(i) <= chain(i-1);
        end loop;
      end if;
    end if;
  end process;

  data_out <= chain(DEPTH-1);

end architecture rtl;
