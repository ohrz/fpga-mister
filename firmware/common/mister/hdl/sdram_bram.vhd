-------------------------------------------------------------------------------
-- Title      : BRAM back end of the SDRAM emulator (stage B)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : sdram_bram.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   2**G_ADDR_BITS words of 16 bit in block RAM behind the back end port of
--   sdram_emu: always ready, read data one cycle after the request (be_rvalid),
--   byte writes.  The low G_ADDR_BITS of the request address select the word;
--   the region decoder in front of it decides which requests come here.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram_bram is
  generic (
    G_ADDR_BITS : natural := 16                     -- 64 K words = 128 KB
  );
  port (
    clk       : in  std_logic;
    req       : in  std_logic;
    we        : in  std_logic;
    addr      : in  std_logic_vector(G_ADDR_BITS - 1 downto 0);
    wdata     : in  std_logic_vector(15 downto 0);
    wstrb     : in  std_logic_vector(1 downto 0);
    ready     : out std_logic;
    rvalid    : out std_logic;
    rdata     : out std_logic_vector(15 downto 0)
  );
end entity sdram_bram;

architecture rtl of sdram_bram is
  type byte_ram_t is array (0 to 2 ** G_ADDR_BITS - 1) of std_logic_vector(7 downto 0);
  signal ram_lo, ram_hi : byte_ram_t := (others => (others => '0'));
begin

  ready <= '1';

  process (clk)
    variable a : natural range 0 to 2 ** G_ADDR_BITS - 1;
  begin
    if rising_edge(clk) then
      a := to_integer(unsigned(addr));
      rvalid <= req and not we;
      if req = '1' and we = '1' then
        if wstrb(0) = '1' then ram_lo(a) <= wdata(7 downto 0); end if;
        if wstrb(1) = '1' then ram_hi(a) <= wdata(15 downto 8); end if;
      end if;
      rdata <= ram_hi(a) & ram_lo(a);               -- read first (old data on a write)
    end if;
  end process;

end architecture rtl;
