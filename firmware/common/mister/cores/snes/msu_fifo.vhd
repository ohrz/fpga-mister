-------------------------------------------------------------------------------
-- Title      : SNES core profile: replacement of the MSU-1 audio FIFO
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : msu_fifo.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/chip/MSU1/msu_fifo.v (dcfifo, show-ahead, 2**DEPTH words)
--   with the same name, parameters and ports.  The only instance
--   (msu_audio.v) clocks both sides with clk, so this is a synchronous FIFO
--   on wrclk; rdclk must be the same clock and is not used.
--     show-ahead  q holds the oldest word while rdempty is '0'; rdreq takes it
--     flags       rdempty, wrfull and the fill level (wrusedw = rdusedw, the
--                 low DEPTH bits of the count as on Intel) without the
--                 synchronizer delay of the dcfifo: the reader sees a word
--                 one clock after it is written (dcfifo: several), which the
--                 instance tolerates (it only waits for words)
--     aclr        asynchronous clear of both sides (empties the FIFO)
--     overflow/underflow checking: wrreq when full and rdreq when empty are
--                 ignored
--   Memory: block RAM read on the clock with the next read address; a word
--   written to that address in the same clock is passed through.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity msu_fifo is
  generic (
    WIDTH : positive := 32;
    DEPTH : positive := 10
  );
  port (
    aclr    : in  std_logic;
    wrclk   : in  std_logic;
    wrreq   : in  std_logic;
    data    : in  std_logic_vector(WIDTH - 1 downto 0);
    wrfull  : out std_logic;
    wrusedw : out std_logic_vector(DEPTH - 1 downto 0);
    rdclk   : in  std_logic;
    rdreq   : in  std_logic;
    q       : out std_logic_vector(WIDTH - 1 downto 0);
    rdempty : out std_logic;
    rdusedw : out std_logic_vector(DEPTH - 1 downto 0)
  );
end entity msu_fifo;

architecture rtl of msu_fifo is
  type ram_t is array (0 to 2 ** DEPTH - 1) of std_logic_vector(WIDTH - 1 downto 0);
  signal ram : ram_t;

  signal wr_ptr, rd_ptr, rd_next : unsigned(DEPTH - 1 downto 0) := (others => '0');
  signal count                   : unsigned(DEPTH downto 0) := (others => '0');
  signal push, pop, empty, full  : std_logic;
  signal q_r                     : std_logic_vector(WIDTH - 1 downto 0) := (others => '0');
begin

  empty   <= '1' when count = 0 else '0';
  full    <= count(DEPTH);
  push    <= wrreq and not full;
  pop     <= rdreq and not empty;
  rd_next <= rd_ptr + 1 when pop = '1' else rd_ptr;

  process (wrclk, aclr)
  begin
    if aclr = '1' then
      wr_ptr <= (others => '0');
      rd_ptr <= (others => '0');
      count  <= (others => '0');
    elsif rising_edge(wrclk) then
      if push = '1' then
        wr_ptr <= wr_ptr + 1;
      end if;
      rd_ptr <= rd_next;
      if push = '1' and pop = '0' then
        count <= count + 1;
      elsif push = '0' and pop = '1' then
        count <= count - 1;
      end if;
    end if;
  end process;

  -- block RAM: write port and registered read of the next head word
  process (wrclk)
  begin
    if rising_edge(wrclk) then
      if push = '1' then
        ram(to_integer(wr_ptr)) <= data;
      end if;
      if push = '1' and wr_ptr = rd_next then
        q_r <= data;                    -- written to the head address in this clock
      else
        q_r <= ram(to_integer(rd_next));
      end if;
    end if;
  end process;

  q       <= q_r;
  rdempty <= empty;
  wrfull  <= full;
  wrusedw <= std_logic_vector(count(DEPTH - 1 downto 0));
  rdusedw <= std_logic_vector(count(DEPTH - 1 downto 0));

end architecture rtl;
