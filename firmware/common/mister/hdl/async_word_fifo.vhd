-------------------------------------------------------------------------------
-- Title      : Dual-clock FIFO for a word stream of equal rates (e.g. TMDS symbols into a GT)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : async_word_fifo.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-11-07
-- Standard   : VHDL-2008
-------------------------------------------------------------------------------
-- Description:
--   Carries a stream of words between two clocks of exactly related rates but
--   unknown phase, e.g. TMDS symbol pairs from the pixel clock into the
--   TXUSRCLK2 of a transceiver (ZCU106: pixel = Si5324 refclk / 2, TXUSRCLK2 =
--   pixel / 2, the writer writes every other pixel clock).  The reader starts
--   once G_START words are in the FIFO and then reads every cycle.  An
--   underflow (only possible before the clocks run steadily) stops the reader
--   until G_START words are there again; the output then repeats the last word.
--   Gray-coded pointers, two synchronizer stages each way (the board XDC puts
--   set_bus_skew on the pointers); both resets are synchronous to their own
--   clock and must overlap.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity async_word_fifo is
  generic (
    G_WIDTH : positive := 60;
    G_ABITS : positive := 3;           -- depth 2**G_ABITS
    G_START : positive := 4            -- words before the reader starts
  );
  port (
    wr_clk   : in  std_logic;
    wr_rst   : in  std_logic;
    wr_en    : in  std_logic;
    wr_data  : in  std_logic_vector(G_WIDTH - 1 downto 0);
    wr_full  : out std_logic;
    rd_clk   : in  std_logic;
    rd_rst   : in  std_logic;
    rd_data  : out std_logic_vector(G_WIDTH - 1 downto 0);
    rd_run   : out std_logic;          -- reader running (one word per cycle)
    rd_under : out std_logic           -- sticky: an underflow happened
  );
end entity async_word_fifo;

architecture rtl of async_word_fifo is

  constant C_DEPTH : positive := 2 ** G_ABITS;

  type mem_t is array (0 to C_DEPTH - 1) of std_logic_vector(G_WIDTH - 1 downto 0);
  signal mem : mem_t;

  subtype ptr_t is unsigned(G_ABITS downto 0);

  function to_gray(b : ptr_t) return ptr_t is
  begin
    return b xor shift_right(b, 1);
  end function;

  function from_gray(g : ptr_t) return ptr_t is
    variable b : ptr_t;
  begin
    b(b'high) := g(g'high);
    for i in b'high - 1 downto 0 loop
      b(i) := b(i + 1) xor g(i);
    end loop;
    return b;
  end function;

  signal wr_bin, wr_gray       : ptr_t := (others => '0');
  signal rd_bin, rd_gray       : ptr_t := (others => '0');
  signal rd_gray_w1, rd_gray_w2 : ptr_t := (others => '0');   -- rd pointer in wr_clk
  signal wr_gray_r1, wr_gray_r2 : ptr_t := (others => '0');   -- wr pointer in rd_clk

  signal full_i  : std_logic;
  signal run     : std_logic := '0';
  signal under   : std_logic := '0';
  signal dout    : std_logic_vector(G_WIDTH - 1 downto 0) := (others => '0');

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of rd_gray_w1, rd_gray_w2, wr_gray_r1, wr_gray_r2 : signal is "TRUE";

begin

  -----------------------------------------------------------------------------
  -- write side
  -----------------------------------------------------------------------------
  full_i <= '1' when wr_gray = (not rd_gray_w2(G_ABITS downto G_ABITS - 1)) & rd_gray_w2(G_ABITS - 2 downto 0)
            else '0';
  wr_full <= full_i;

  process (wr_clk)
  begin
    if rising_edge(wr_clk) then
      rd_gray_w1 <= rd_gray;
      rd_gray_w2 <= rd_gray_w1;
      if wr_rst = '1' then
        wr_bin  <= (others => '0');
        wr_gray <= (others => '0');
      elsif wr_en = '1' and full_i = '0' then
        mem(to_integer(wr_bin(G_ABITS - 1 downto 0))) <= wr_data;
        wr_bin  <= wr_bin + 1;
        wr_gray <= to_gray(wr_bin + 1);
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- read side
  -----------------------------------------------------------------------------
  process (rd_clk)
    variable fill : ptr_t;
  begin
    if rising_edge(rd_clk) then
      wr_gray_r1 <= wr_gray;
      wr_gray_r2 <= wr_gray_r1;
      fill := from_gray(wr_gray_r2) - rd_bin;
      if rd_rst = '1' then
        rd_bin  <= (others => '0');
        rd_gray <= (others => '0');
        run     <= '0';
        under   <= '0';
      elsif run = '0' then
        if fill >= G_START then
          run <= '1';
        end if;
      elsif fill = 0 then
        run   <= '0';
        under <= '1';
      else
        dout    <= mem(to_integer(rd_bin(G_ABITS - 1 downto 0)));
        rd_bin  <= rd_bin + 1;
        rd_gray <= to_gray(rd_bin + 1);
      end if;
    end if;
  end process;

  rd_data  <= dout;
  rd_run   <= run;
  rd_under <= under;

end architecture rtl;
