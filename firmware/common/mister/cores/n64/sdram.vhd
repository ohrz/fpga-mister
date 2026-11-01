-------------------------------------------------------------------------------
-- Title      : N64 core profile: replacement of the SDRAM controller (stage D)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : sdram.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/sdram.sv of N64_MiSTer (three request/ready channels in front
--   of a 32 MB x 2 SDRAM) with the same name and channel ports.  Instead of
--   the SDRAM pins it drives a 64-bit Avalon-MM master (mem_*, clocked by
--   clk, mem_clk = clk) that the core profile wires through emu and
--   sys_top_zynq to mister_zynq (COREMEM -> avl_axi_bridge -> HP3).  The SDRAM
--   pins stay inactive (DQ high impedance, nCS high).
--
--   Address space: chX_addr(26:0) is a byte address (bit 26 = second chip),
--   byte address of the Avalon word = chX_addr(26:3) * 8.  Data are little
--   endian as on the SDRAM: chX_dout(15:0) is the 16-bit word at chX_addr,
--   SDRAM_DQ(7:0) the byte at the even address.
--
--   The original does each access as two 16-bit cycles on word W =
--   chX_addr(25:1), and this replacement keeps what that gives:
--     read   burst of 2, sequential: dout(15:0) = word W, dout(31:16) = word
--            W xor 1 (an odd W wraps to W - 1)
--     write  two single writes: dout(15:0) with be(1:0) to W, then
--            dout(31:16) with be(3:2) to W or 1 (an odd W gets both, the
--            second wins where its byte enable is set)
--     ch2, ch3  byte enables 1111; ch3 is the 8-bit mode: it writes
--            FF & din(15:8) & FF & din(7:0) and reads dout(7:0) = low byte of
--            W, dout(15:8) = low byte of W xor 1
--   Each access is one Avalon beat (burstcount 1).  Channel priority 1, 2, 3
--   as in the original; a request is latched until it is served.  Reads are
--   pipelined: up to 2**G_RD_LOG2 reads may wait for their data, which comes
--   back in order (Avalon readdatavalid) and ends in chX_dout with a
--   chX_ready pulse.  ch1_reqprocessed pulses together with the ch1_ready of
--   a read, not when the read is taken: the N64 SDRamMux requests the next
--   word of a burst on ch1_reqprocessed while its count of words still to
--   come is >= 2, and it counts down only on ch1_ready.  The original's data
--   come back before its next reqprocessed; with the latency of HP3 an
--   earlier pulse made SDRamMux issue more reads than the burst, and their
--   late ready pulses ended the next request (PI DMA) with wrong data.  So
--   ch1 has one read in flight at a time.  A write is done
--   (chX_ready) when the Avalon slave has accepted it; the bridge behind it
--   keeps a later read behind the write.  init (PLL not locked) holds new
--   accesses back; requests stay latched and are served once init is '0', as
--   in the original (its chX_rq survive the startup sequence; SDRamMux waits
--   for the ready of the first write of its reset sequence, which comes
--   before LOCKED: the MMCM outputs run earlier); reads already issued still
--   return.  init is the MMCM's LOCKED (N64.sv: ~pll_locked), asynchronous
--   to clk: it goes through two synchronizer stages before the take
--   decision.  Unsynchronized, a request latched while the MMCM locked can be
--   taken at the LOCKED edge by part of the logic only (request bit cleared,
--   command not issued) and is lost; the same race hung the PSX start
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram is
  generic (
    G_RD_LOG2 : natural := 3                       -- reads waiting for data: 2**G_RD_LOG2
  );
  port (
    init             : in    std_logic;
    clk              : in    std_logic;

    SDRAM_DQ         : inout std_logic_vector(15 downto 0);
    SDRAM_A          : out   std_logic_vector(12 downto 0);
    SDRAM_DQML       : out   std_logic;
    SDRAM_DQMH       : out   std_logic;
    SDRAM_BA         : out   std_logic_vector(1 downto 0);
    SDRAM_nCS        : out   std_logic;
    SDRAM_nWE        : out   std_logic;
    SDRAM_nRAS       : out   std_logic;
    SDRAM_nCAS       : out   std_logic;
    SDRAM_CKE        : out   std_logic;

    ch1_addr         : in    std_logic_vector(26 downto 0);
    ch1_dout         : out   std_logic_vector(31 downto 0);
    ch1_din          : in    std_logic_vector(31 downto 0);
    ch1_req          : in    std_logic;
    ch1_rnw          : in    std_logic;
    ch1_be           : in    std_logic_vector(3 downto 0);
    ch1_ready        : out   std_logic;
    ch1_reqprocessed : out   std_logic;

    ch2_addr         : in    std_logic_vector(26 downto 0);
    ch2_dout         : out   std_logic_vector(31 downto 0);
    ch2_din          : in    std_logic_vector(31 downto 0);
    ch2_req          : in    std_logic;
    ch2_rnw          : in    std_logic;
    ch2_ready        : out   std_logic;

    ch3_addr         : in    std_logic_vector(26 downto 0);
    ch3_dout         : out   std_logic_vector(15 downto 0);
    ch3_din          : in    std_logic_vector(15 downto 0);
    ch3_req          : in    std_logic;
    ch3_rnw          : in    std_logic;
    ch3_ready        : out   std_logic;

    -- Avalon-MM master, 64 bit (clk)
    mem_clk          : out   std_logic;
    mem_address      : out   std_logic_vector(28 downto 0);   -- 64-bit word address
    mem_burstcount   : out   std_logic_vector(7 downto 0);
    mem_waitrequest  : in    std_logic := '1';
    mem_readdata     : in    std_logic_vector(63 downto 0) := (others => '0');
    mem_readdatavalid : in   std_logic := '0';
    mem_read         : out   std_logic;
    mem_writedata    : out   std_logic_vector(63 downto 0);
    mem_byteenable   : out   std_logic_vector(7 downto 0);
    mem_write        : out   std_logic
  );
end entity sdram;

architecture rtl of sdram is

  constant C_DEPTH : natural := 2 ** G_RD_LOG2;

  -- read tag: channel (1..3) and 16-bit lane of word W in the Avalon word
  type tag_t is record
    ch   : natural range 1 to 3;
    lane : unsigned(1 downto 0);
  end record;
  type tag_array is array (0 to C_DEPTH - 1) of tag_t;

  signal rq        : std_logic_vector(1 to 3) := "000";
  signal cmd_rd    : std_logic := '0';
  signal cmd_wr    : std_logic := '0';
  signal cmd_ch    : natural range 1 to 3 := 1;
  signal cmd_addr  : std_logic_vector(28 downto 0) := (others => '0');
  signal cmd_wdata : std_logic_vector(63 downto 0) := (others => '0');
  signal cmd_be    : std_logic_vector(7 downto 0) := (others => '0');
  signal tags      : tag_array := (others => (ch => 1, lane => "00"));
  signal tag_wr    : unsigned(G_RD_LOG2 - 1 downto 0) := (others => '0');
  signal tag_rd    : unsigned(G_RD_LOG2 - 1 downto 0) := (others => '0');
  signal rd_n      : natural range 0 to C_DEPTH := 0;              -- reads taken, data not back
  signal init_s    : std_logic_vector(1 downto 0) := "11";         -- init synchronized to clk
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of init_s : signal is "TRUE";

begin

  SDRAM_DQ   <= (others => 'Z');
  SDRAM_A    <= (others => '0');
  SDRAM_BA   <= "00";
  SDRAM_DQML <= '1';
  SDRAM_DQMH <= '1';
  SDRAM_nCS  <= '1';
  SDRAM_nWE  <= '1';
  SDRAM_nRAS <= '1';
  SDRAM_nCAS <= '1';
  SDRAM_CKE  <= '1';

  mem_clk        <= clk;
  mem_address    <= cmd_addr;
  mem_burstcount <= x"01";
  mem_read       <= cmd_rd;
  mem_write      <= cmd_wr;
  mem_writedata  <= cmd_wdata;
  mem_byteenable <= cmd_be;

  process (clk)
    variable ready   : std_logic_vector(1 to 3);
    variable free    : boolean;
    variable ch      : natural range 0 to 3;
    variable a       : std_logic_vector(26 downto 0);
    variable d       : std_logic_vector(31 downto 0);
    variable be      : std_logic_vector(3 downto 0);
    variable rnw     : std_logic;
    variable lane    : natural range 0 to 3;
    variable pair    : natural range 0 to 3;
    variable w16     : std_logic_vector(15 downto 0);
    variable be16    : std_logic_vector(1 downto 0);
    variable lo, hi  : std_logic_vector(15 downto 0);
    variable t       : tag_t;
    variable n       : natural range 0 to C_DEPTH;
  begin
    if rising_edge(clk) then
      ready := "000";
      ch1_reqprocessed <= '0';
      n := rd_n;

      -- Avalon command accepted: a write is done
      free := (cmd_rd = '0' and cmd_wr = '0') or mem_waitrequest = '0';
      if mem_waitrequest = '0' then
        if cmd_wr = '1' then
          ready(cmd_ch) := '1';
        end if;
        cmd_rd <= '0';
        cmd_wr <= '0';
      end if;

      -- read data, in order of the tags
      if mem_readdatavalid = '1' then
        t := tags(to_integer(tag_rd));
        tag_rd <= tag_rd + 1;
        n := n - 1;
        lane := to_integer(t.lane);
        lo := mem_readdata(16 * lane + 15 downto 16 * lane);
        pair := lane + 1 - 2 * (lane mod 2);         -- W xor 1
        hi := mem_readdata(16 * pair + 15 downto 16 * pair);
        case t.ch is
          when 1 => ch1_dout <= hi & lo; ch1_reqprocessed <= '1';
          when 2 => ch2_dout <= hi & lo;
          when 3 => ch3_dout <= hi(7 downto 0) & lo(7 downto 0);
        end case;
        ready(t.ch) := '1';
      end if;

      -- next request, priority ch1, ch2, ch3 (the inputs are held until served)
      ch := 0;
      if rq(1) = '1' or ch1_req = '1' then
        ch := 1; a := ch1_addr; d := ch1_din; be := ch1_be; rnw := ch1_rnw;
      elsif rq(2) = '1' or ch2_req = '1' then
        ch := 2; a := ch2_addr; d := ch2_din; be := "1111"; rnw := ch2_rnw;
      elsif rq(3) = '1' or ch3_req = '1' then
        ch := 3; a := ch3_addr; d := x"FF" & ch3_din(15 downto 8) & x"FF" & ch3_din(7 downto 0); be := "1111";
        rnw := ch3_rnw;
      end if;
      if ch /= 0 and rnw = '1' and rd_n = C_DEPTH then
        ch := 0;                                    -- every tag in use: wait for read data
      end if;

      init_s <= init_s(0) & init;

      rq(1) <= rq(1) or ch1_req;
      rq(2) <= rq(2) or ch2_req;
      rq(3) <= rq(3) or ch3_req;
      if free and ch /= 0 and init_s(1) = '0' then
        rq(ch) <= '0';
        cmd_ch <= ch;
        cmd_addr <= "00000" & a(26 downto 3);
        lane := to_integer(unsigned(a(2 downto 1)));
        if rnw = '1' then
          cmd_rd <= '1';
          tags(to_integer(tag_wr)) <= (ch => ch, lane => unsigned(a(2 downto 1)));
          tag_wr <= tag_wr + 1;
          n := n + 1;
        else
          cmd_wr <= '1';
          cmd_be <= (others => '0');
          if a(1) = '0' then
            -- words W and W + 1: one 32-bit lane
            cmd_wdata <= d & d;
            cmd_be(4 * (lane / 2) + 3 downto 4 * (lane / 2)) <= be;
          else
            -- odd W: both halves to W, the upper one over the lower one
            for b in 0 to 1 loop
              if be(2 + b) = '1' then
                w16(8 * b + 7 downto 8 * b) := d(16 + 8 * b + 7 downto 16 + 8 * b);
              else
                w16(8 * b + 7 downto 8 * b) := d(8 * b + 7 downto 8 * b);
              end if;
            end loop;
            be16 := be(3 downto 2) or be(1 downto 0);
            cmd_wdata <= w16 & w16 & w16 & w16;
            cmd_be(2 * lane + 1 downto 2 * lane) <= be16;
          end if;
        end if;
      end if;

      rd_n <= n;
      ch1_ready <= ready(1);
      ch2_ready <= ready(2);
      ch3_ready <= ready(3);
    end if;
  end process;

end architecture rtl;
