-------------------------------------------------------------------------------
-- Title      : Region decoder of the SDRAM emulator back end
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : sdram_region.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Splits the back end port of sdram_emu between two back ends
--   (doc/ARCHITECTURE.md §3, stage C):
--     b0  a region pinned in block RAM (sdram_bram), e.g. the VRAM of a core
--         whose accesses must never wait
--     b1  everything else, the cache in front of the DDR (sdram_cache)
--   A request goes to b0 when (addr and G_B0_MASK) = G_B0_MATCH.  The b0
--   address is built from the address bits set in G_B0_SEL, packed from bit 0
--   upwards (so a region spread over the bank/row/column bits of a core's
--   address map becomes one contiguous BRAM address); G_B0_BITS = number of
--   bits set in G_B0_SEL.  Address bits outside G_B0_SEL are ignored inside
--   the region (mirrors).
--   Read data returns in request order: a read is only passed to one back end
--   when the other one has no read outstanding (counted, the read data of the
--   current cycle included).  Writes are not held: the two regions do not
--   overlap.  Both back ends must return read data in their own request order.
--   The masks are naturals, so G_ADDR_BITS <= 31.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram_region is
  generic (
    G_ADDR_BITS : natural := 24;       -- flat word address of sdram_emu
    G_B0_MASK   : natural := 0;        -- address bits that select b0
    G_B0_MATCH  : natural := 0;        -- their value for b0
    G_B0_SEL    : natural := 16#FFFF#; -- address bits that form the b0 address (packed)
    G_B0_BITS   : natural := 16;       -- bits set in G_B0_SEL
    G_OUT_BITS  : natural := 5         -- width of the outstanding read counters
  );
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;

    -- from sdram_emu
    req       : in  std_logic;
    we        : in  std_logic;
    addr      : in  std_logic_vector(G_ADDR_BITS - 1 downto 0);
    wdata     : in  std_logic_vector(15 downto 0);
    wstrb     : in  std_logic_vector(1 downto 0);
    ready     : out std_logic;
    rvalid    : out std_logic;
    rdata     : out std_logic_vector(15 downto 0);

    -- b0: pinned region (sdram_bram)
    b0_req    : out std_logic;
    b0_we     : out std_logic;
    b0_addr   : out std_logic_vector(G_B0_BITS - 1 downto 0);
    b0_wdata  : out std_logic_vector(15 downto 0);
    b0_wstrb  : out std_logic_vector(1 downto 0);
    b0_ready  : in  std_logic;
    b0_rvalid : in  std_logic;
    b0_rdata  : in  std_logic_vector(15 downto 0);

    -- b1: the rest (sdram_cache)
    b1_req    : out std_logic;
    b1_we     : out std_logic;
    b1_addr   : out std_logic_vector(G_ADDR_BITS - 1 downto 0);
    b1_wdata  : out std_logic_vector(15 downto 0);
    b1_wstrb  : out std_logic_vector(1 downto 0);
    b1_ready  : in  std_logic;
    b1_rvalid : in  std_logic;
    b1_rdata  : in  std_logic_vector(15 downto 0);

    err       : out std_logic          -- sticky: read data from both back ends at once
  );
end entity sdram_region;

architecture rtl of sdram_region is

  constant C_MASK  : unsigned(G_ADDR_BITS - 1 downto 0) := to_unsigned(G_B0_MASK, G_ADDR_BITS);
  constant C_MATCH : unsigned(G_ADDR_BITS - 1 downto 0) := to_unsigned(G_B0_MATCH, G_ADDR_BITS);
  constant C_SEL   : unsigned(G_ADDR_BITS - 1 downto 0) := to_unsigned(G_B0_SEL, G_ADDR_BITS);

  signal sel0      : std_logic;
  signal idle0     : std_logic;        -- b0 has no read outstanding after this cycle
  signal idle1     : std_logic;
  signal ok        : std_logic;
  signal out0      : unsigned(G_OUT_BITS - 1 downto 0);
  signal out1      : unsigned(G_OUT_BITS - 1 downto 0);
  signal go0       : std_logic;
  signal go1       : std_logic;
  signal err_i     : std_logic;

  function popcount(v : unsigned) return natural is
    variable n : natural := 0;
  begin
    for i in v'range loop
      if v(i) = '1' then n := n + 1; end if;
    end loop;
    return n;
  end function;

begin

  assert popcount(C_SEL) = G_B0_BITS and (C_MASK and C_MATCH) = C_MATCH
    report "sdram_region: G_B0_BITS /= bits set in G_B0_SEL, or G_B0_MATCH outside G_B0_MASK" severity failure;

  sel0  <= '1' when (unsigned(addr) and C_MASK) = C_MATCH else '0';

  idle0 <= '1' when out0 = 0 or (out0 = 1 and b0_rvalid = '1') else '0';
  idle1 <= '1' when out1 = 0 or (out1 = 1 and b1_rvalid = '1') else '0';
  ok    <= '1' when we = '1' or (sel0 = '1' and idle1 = '1') or (sel0 = '0' and idle0 = '1') else '0';

  b0_req   <= req and sel0 and ok;
  b1_req   <= req and not sel0 and ok;
  ready    <= ok and b0_ready when sel0 = '1' else ok and b1_ready;

  process (addr)
    variable a : std_logic_vector(G_B0_BITS - 1 downto 0);
    variable k : natural;
  begin
    a := (others => '0');
    k := 0;
    for i in 0 to G_ADDR_BITS - 1 loop
      if C_SEL(i) = '1' then
        a(k) := addr(i);
        k := k + 1;
      end if;
    end loop;
    b0_addr <= a;
  end process;

  b0_we    <= we;
  b0_wdata <= wdata;
  b0_wstrb <= wstrb;
  b1_we    <= we;
  b1_addr  <= addr;
  b1_wdata <= wdata;
  b1_wstrb <= wstrb;

  rvalid <= b0_rvalid or b1_rvalid;
  rdata  <= b1_rdata when b1_rvalid = '1' else b0_rdata;

  go0 <= req and sel0 and ok and b0_ready and not we;
  go1 <= req and not sel0 and ok and b1_ready and not we;

  process (clk)
  begin
    if rising_edge(clk) then
      if go0 = '1' and b0_rvalid = '0' then
        out0 <= out0 + 1;
      elsif go0 = '0' and b0_rvalid = '1' then
        out0 <= out0 - 1;
      end if;
      if go1 = '1' and b1_rvalid = '0' then
        out1 <= out1 + 1;
      elsif go1 = '0' and b1_rvalid = '1' then
        out1 <= out1 - 1;
      end if;
      if b0_rvalid = '1' and b1_rvalid = '1' then
        err_i <= '1';
      end if;
      if rst = '1' then
        out0  <= (others => '0');
        out1  <= (others => '0');
        err_i <= '0';
      end if;
    end if;
  end process;

  err <= err_i;

end architecture rtl;
