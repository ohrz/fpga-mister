-------------------------------------------------------------------------------
-- Title      : PSX core profile: replacement of the SDRAM controller (stage D)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : sdram.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-31
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/sdram.sv of PSX_MiSTer (cd17b5a): same entity name, same
--   ports (clk = clk_3x, clk_base = clk_1x, phase aligned 3:1 from one MMCM,
--   as in the original).  Instead of the SDRAM pins it drives a 64-bit
--   Avalon-MM master (mem_*, clocked by clk, mem_clk = clk) that the core
--   profile wires to COREMEM (avl_axi_bridge -> HP3).  The SDRAM pins stay
--   inactive (DQ high impedance, nCS high).  The generics have defaults, the
--   Verilog instance in PSX.sv needs none.
--
--   Address space: chX_addr(26:0), dmafifo_adr(26:0) are byte addresses; the
--   Avalon word is addr(26:3), mem_address = "00000" & addr(26:3) (relative
--   to the image base, the frame adds it).  Little endian as on the SDRAM:
--   bits 7:0 of a 32-bit word are the byte at the lower address.  PSX.sv
--   uses 0x000_0000-0x07F_FFFF (RAM, 2 MB unless 8 MB), 0x080_0000-0x09F_FFFF
--   (four 512 KB BIOS slots) and 0x100_0000-0x17F_FFFF (EXE download).
--
--   What the original does and this replacement keeps (observable at the
--   ports, clk_base outputs registered on clk_base as there):
--     ch1 read   32 bit at addr (ch1_dout32 with a one-cycle ch1_ready);
--                ch1_cache: words addr, addr+4, .. up to the end of the 16-byte
--                line go to cache_wr/cache_data/cache_addr (clk, one word per
--                cycle, cache_wr one-hot = word in the line); ch1_ready one
--                clk cycle after the first cache word was written (the
--                original: with the second word), so word k of the line is in
--                the cache RAM before the core can read it (k clk_base cycles
--                after ch1_ready);
--                ch1_dma: ch1_cntDMA+1 words addr + 4i, inside the 1 KB SDRAM
--                row: the column counter wraps (addr(9:2) + i mod 256), as in
--                the original; dma_reqprocessed (one clk_base pulse) when the
--                read is taken, then dma_wr for cnt+1 consecutive clk_base
--                cycles with dma_data, no ch1_ready.  The start of one DMA
--                block to the next is at least G_DMA_GAP clk cycles (13: the
--                original's 13-state read cycle), so DMA is never faster than
--                the original (the DMA unit's 64-word input FIFO has no flow
--                control towards the RAM).
--     ch1 write  16 bit ch1_din at addr(26:1), both bytes; ch1_ready when
--                the Avalon slave took it (unused by PSX.sv: ch1_rnw = 1).
--     ch2 write  32 bit, byte enables ch2_be; ch2_ready when the write is
--                taken (the original: in STATE_IDLE, before it is done), the
--                Avalon slave keeps a later read behind it (avl_axi_bridge).
--     ch3        download (BIOS/EXE) and cheats: write 32 bit with ch3_be,
--                ch3_ready when the Avalon slave took it; read 32 bit
--                (ch3_dout, all four bytes valid: the original leaves the
--                bytes masked by ch3_be undefined), ch3_ready with the data.
--     ch2 read   32 bit to ch2_dout, one ch2_ready with the data (the
--                original gives a second, early one; unused: ch2_rnw = 0).
--     addr(1)=1  16-bit word W = addr(26:1) odd: reads give W in bits 15:0
--                and W-1 in bits 31:16 (burst of 2 wraps), writes put both
--                halves into W, the upper over the lower (cores/n64 sdram.vhd).
--     dmafifo    the DMA unit's fall-through FIFO (clk) is drained before
--                ch1..3 (priority as in the original, so a CPU read after a
--                DMA sees the data); 32-bit writes, all bytes; dmafifo_read
--                one clk cycle per word and at most every second cycle (the
--                FIFO's empty flag is registered); in the cycle after a
--                dmafifo_read nothing else is taken either, the FIFO may still
--                hold words.
--     priority   dmafifo, ch1, ch2, ch3; a request (chX_req, one clk_base
--                cycle) is latched on the first clk edge after the clk_base
--                edge (clk3xIndex as in the original) and served when the
--                command register is free; the inputs are read then (the core
--                holds them until ready).
--     init       (PLL not locked) and SDRAM_EN = 0 start no new access;
--                requests stay latched, reads already issued still return.
--                init is the MMCM's LOCKED (PSX.sv: ~pll_locked), asynchronous
--                to clk: it goes through two synchronizer stages before the
--                take decision.  Unsynchronized, the request the CPU made
--                while the MMCM locked (the core runs from the PL
--                configuration on) was taken at the LOCKED edge by part of
--                the logic only: job pointer advanced, descriptor not written,
--                request still latched (ILA, start hang); with no
--                reset here the read never completed.
--     ram_idle   '1' (clk_base) when nothing is latched, issued or waiting
--                for output, and ch3_req is 0 (not connected in PSX.sv).
--     refreshForce  no refresh here; ignored.
--   Deviations: no refresh cycles (the original pauses ~7 of 780 cycles), so
--   DMA blocks may come up to 1 % more often than there; the read latency is
--   that of the Avalon slave (DDR through HP3), longer than the original's
--   3 clk_base cycles; the original's stale byte enables for a DMA FIFO word
--   that follows a ch2 write to the same row (STATE_RW2) are not reproduced.
--
--   Structure: requests become read jobs (up to 2**G_JOBS_LOG2 in flight,
--   1..3 Avalon beats each, a second burst when a DMA block wraps in its 1 KB
--   row) or single-beat writes; one command register drives the Avalon
--   master.  Read data come back in order into per-job beat RAMs (distributed
--   RAM); the job at the head goes out when its output is free (DMA: the gap
--   has passed).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram is
  generic (
    G_JOBS_LOG2 : positive := 3;                   -- read jobs in flight: 2**G_JOBS_LOG2
    G_DMA_GAP   : positive := 13                   -- clk cycles between DMA blocks, >= 13
  );
  port (
    init             : in    std_logic;
    clk              : in    std_logic;           -- clk_3x
    clk_base         : in    std_logic;           -- clk_1x, rising edges on rising edges of clk

    SDRAM_EN         : in    std_logic := '1';

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
    SDRAM_CLK        : out   std_logic;

    refreshForce     : in    std_logic := '0';
    ram_idle         : out   std_logic;

    ch1_addr         : in    std_logic_vector(26 downto 0);
    ch1_dout         : out   std_logic_vector(127 downto 0);
    ch1_dout32       : out   std_logic_vector(31 downto 0);
    ch1_din          : in    std_logic_vector(15 downto 0) := (others => '0');
    ch1_req          : in    std_logic;
    ch1_rnw          : in    std_logic;
    ch1_dma          : in    std_logic;
    ch1_cntDMA       : in    std_logic_vector(1 downto 0);
    ch1_cache        : in    std_logic;
    ch1_ready        : out   std_logic;
    cache_wr         : out   std_logic_vector(3 downto 0);
    cache_data       : out   std_logic_vector(31 downto 0);
    cache_addr       : out   std_logic_vector(7 downto 0);
    dma_wr           : out   std_logic;
    dma_reqprocessed : out   std_logic;
    dma_data         : out   std_logic_vector(31 downto 0);

    ch2_addr         : in    std_logic_vector(26 downto 0);
    ch2_dout         : out   std_logic_vector(31 downto 0);
    ch2_din          : in    std_logic_vector(31 downto 0);
    ch2_req          : in    std_logic;
    ch2_rnw          : in    std_logic;
    ch2_be           : in    std_logic_vector(3 downto 0);
    ch2_ready        : out   std_logic;

    ch3_addr         : in    std_logic_vector(26 downto 0);
    ch3_dout         : out   std_logic_vector(31 downto 0);
    ch3_din          : in    std_logic_vector(31 downto 0) := (others => '0');
    ch3_req          : in    std_logic;
    ch3_rnw          : in    std_logic;
    ch3_be           : in    std_logic_vector(3 downto 0) := "1111";
    ch3_ready        : out   std_logic;

    dmafifo_adr      : in    std_logic_vector(26 downto 0);
    dmafifo_data     : in    std_logic_vector(31 downto 0);
    dmafifo_empty    : in    std_logic;
    dmafifo_read     : out   std_logic;

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

  constant C_JOBS : natural := 2 ** G_JOBS_LOG2;

  -- job kinds
  constant K_CPU   : std_logic_vector(2 downto 0) := "000";   -- ch1 32-bit read
  constant K_CACHE : std_logic_vector(2 downto 0) := "001";   -- ch1 cache line
  constant K_DMA   : std_logic_vector(2 downto 0) := "010";   -- ch1 DMA block
  constant K_CH2   : std_logic_vector(2 downto 0) := "011";
  constant K_CH3   : std_logic_vector(2 downto 0) := "100";

  -- job descriptor: kind(18:16) o0(15) swap(14) beats(13:12) cnt(11:10) cache line(9:2) first word(1:0)
  subtype desc_t is std_logic_vector(18 downto 0);
  type desc_array is array (0 to C_JOBS - 1) of desc_t;
  type beat_array is array (0 to C_JOBS - 1) of std_logic_vector(63 downto 0);

  subtype ptr_t is unsigned(G_JOBS_LOG2 downto 0);              -- one wrap bit

  -- 32-bit words k = 0..3 of a job from its beats (o0: first word in the upper half of beat 0,
  -- swap: odd 16-bit address, halves exchanged)
  function extract(b0, b1, b2 : std_logic_vector(63 downto 0); o0, swap : std_logic)
    return std_logic_vector is
    variable w6 : std_logic_vector(191 downto 0);
    variable w  : std_logic_vector(31 downto 0);
    variable r  : std_logic_vector(127 downto 0);
    variable j  : natural range 0 to 4;
  begin
    w6 := b2 & b1 & b0;
    for k in 0 to 3 loop
      if o0 = '1' then
        j := k + 1;
      else
        j := k;
      end if;
      w := w6(32 * j + 31 downto 32 * j);
      if swap = '1' then
        w := w(15 downto 0) & w(31 downto 16);
      end if;
      r(32 * k + 31 downto 32 * k) := w;
    end loop;
    return r;
  end function;

  -- clk_base domain
  signal tog1x       : std_logic := '0';
  signal ch1_rdy_b   : std_logic := '0';
  signal ch2_rdy_b   : std_logic := '0';
  signal ch3_rdy_b   : std_logic := '0';
  signal dma_rp_b    : std_logic := '0';
  signal dma_wr_b    : std_logic := '0';
  signal dma_ack     : std_logic := '0';
  signal dma_counter : unsigned(1 downto 0) := "00";
  signal dma_count   : unsigned(1 downto 0) := "00";
  signal idle_next   : std_logic := '0';

  -- clk domain
  signal tog3x, tog3x_1, idx : std_logic := '0';
  signal rq1, rq2, rq3       : std_logic := '0';
  signal ch1_rdy_3x          : std_logic := '0';
  signal ch2_rdy_3x          : std_logic := '0';
  signal ch3_rdy_3x          : std_logic := '0';
  signal dma_rp_3x           : std_logic := '0';
  signal dma_done            : std_logic := '0';
  signal dma_cnt_3x          : std_logic_vector(1 downto 0) := "00";
  signal dma_buf             : std_logic_vector(127 downto 0) := (others => '0');
  signal gap                 : natural range 0 to G_DMA_GAP := 0;
  signal fifo_rd             : std_logic := '0';

  signal cmd_rd, cmd_wr      : std_logic := '0';
  signal cmd_addr            : std_logic_vector(23 downto 0) := (others => '0');
  signal cmd_bc              : unsigned(1 downto 0) := "01";
  signal cmd_wdata           : std_logic_vector(63 downto 0) := (others => '0');
  signal cmd_be              : std_logic_vector(7 downto 0) := (others => '0');
  signal cmd_ack             : natural range 0 to 3 := 0;   -- write done: 1 ch1_ready, 3 ch3_ready
  signal b2_valid            : std_logic := '0';            -- second burst of a wrapping DMA block
  signal b2_addr             : std_logic_vector(23 downto 0) := (others => '0');
  signal b2_bc               : unsigned(1 downto 0) := "01";

  signal desc                : desc_array := (others => (others => '0'));
  signal bk0, bk1, bk2       : beat_array := (others => (others => '0'));
  signal alloc_p, ret_p, out_p : ptr_t := (others => '0');
  signal ret_beat            : unsigned(1 downto 0) := "00";
  signal init_s              : std_logic_vector(1 downto 0) := "11";   -- init synchronized to clk
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of init_s : signal is "TRUE";

  signal dout_r              : std_logic_vector(127 downto 0) := (others => '0');
  signal ch2_dout_r          : std_logic_vector(31 downto 0) := (others => '0');
  signal ch3_dout_r          : std_logic_vector(31 downto 0) := (others => '0');
  signal cache_wr_r          : std_logic_vector(3 downto 0) := "0000";
  signal cache_data_r        : std_logic_vector(31 downto 0) := (others => '0');
  signal cache_addr_r        : std_logic_vector(7 downto 0) := (others => '0');
  signal cs_mask             : std_logic_vector(3 downto 0) := "0000";
  signal cs_n                : natural range 0 to 3 := 0;   -- cache words still to write

begin

  assert G_DMA_GAP >= 13
    report "G_DMA_GAP < 13: a DMA block could overwrite the one clk_base still sends" severity failure;

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
  SDRAM_CLK  <= '0';

  mem_clk        <= clk;
  mem_address    <= "00000" & cmd_addr;
  mem_burstcount <= "000000" & std_logic_vector(cmd_bc);
  mem_read       <= cmd_rd;
  mem_write      <= cmd_wr;
  mem_writedata  <= cmd_wdata;
  mem_byteenable <= cmd_be;

  ch1_ready        <= ch1_rdy_b;
  ch2_ready        <= ch2_rdy_b;
  ch3_ready        <= ch3_rdy_b;
  dma_reqprocessed <= dma_rp_b;
  dma_wr           <= dma_wr_b;
  ch1_dout         <= dout_r;
  ch2_dout         <= ch2_dout_r;
  ch3_dout         <= ch3_dout_r;
  cache_wr         <= cache_wr_r;
  cache_data       <= cache_data_r;
  cache_addr       <= cache_addr_r;
  dmafifo_read     <= fifo_rd;
  ram_idle         <= idle_next and not ch3_req;

  ------------------------------------------------------------------------------
  -- clk_base: ready pulses, ch1_dout32, DMA words (as the original)
  ------------------------------------------------------------------------------
  base : process (clk_base)
  begin
    if rising_edge(clk_base) then
      ch1_rdy_b <= ch1_rdy_3x;
      ch2_rdy_b <= ch2_rdy_3x;
      ch3_rdy_b <= ch3_rdy_3x;
      dma_rp_b  <= dma_rp_3x;
      tog1x     <= not tog1x;

      idle_next <= '0';
      if rq1 = '0' and rq2 = '0' and rq3 = '0' and cmd_rd = '0' and cmd_wr = '0' and b2_valid = '0' and
         alloc_p = out_p and cs_n = 0 then
        idle_next <= '1';
      end if;

      if ch1_rdy_3x = '1' then
        ch1_dout32 <= dout_r(31 downto 0);
      end if;

      dma_wr_b <= '0';
      dma_ack  <= '0';
      if dma_wr_b = '1' and dma_counter < dma_count then
        dma_wr_b    <= '1';
        dma_counter <= dma_counter + 1;
        case to_integer(dma_counter) is
          when 0      => dma_data <= dma_buf(63 downto 32);
          when 1      => dma_data <= dma_buf(95 downto 64);
          when others => dma_data <= dma_buf(127 downto 96);
        end case;
      end if;
      if dma_done = '1' then
        dma_ack     <= '1';
        dma_wr_b    <= '1';
        dma_data    <= dma_buf(31 downto 0);
        dma_counter <= "00";
        dma_count   <= unsigned(dma_cnt_3x);
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- clk: requests, Avalon commands, read data, outputs
  ------------------------------------------------------------------------------
  main : process (clk)
    variable free     : boolean;
    variable take     : natural range 0 to 4;
    variable a        : std_logic_vector(26 downto 0);
    variable d        : std_logic_vector(31 downto 0);
    variable be       : std_logic_vector(3 downto 0);
    variable rd       : boolean;
    variable kind     : std_logic_vector(2 downto 0);
    variable nw       : natural range 1 to 4;
    variable tot, c1  : natural range 0 to 3;
    variable room     : natural range 1 to 128;
    variable lane     : natural range 0 to 3;
    variable w16      : std_logic_vector(15 downto 0);
    variable be16     : std_logic_vector(1 downto 0);
    variable used     : ptr_t;
    variable dsc      : desc_t;
    variable words    : std_logic_vector(127 downto 0);
    variable slot     : natural range 0 to C_JOBS - 1;
    variable cfirst   : natural range 0 to 3;
    variable cpu_free : boolean;
  begin
    if rising_edge(clk) then
      -- clk3xIndex: '1' on the first clk edge after a clk_base edge
      tog3x   <= tog1x;
      tog3x_1 <= tog3x;
      if tog3x_1 = tog1x then
        idx <= '1';
      else
        idx <= '0';
      end if;

      -- handshakes towards clk_base
      if ch1_rdy_b = '1' then ch1_rdy_3x <= '0'; end if;
      if ch2_rdy_b = '1' then ch2_rdy_3x <= '0'; end if;
      if ch3_rdy_b = '1' then ch3_rdy_3x <= '0'; end if;
      if dma_rp_b = '1' then dma_rp_3x <= '0'; end if;
      if dma_ack = '1' then dma_done <= '0'; end if;
      if gap > 0 then gap <= gap - 1; end if;

      init_s <= init_s(0) & init;

      rq1 <= rq1 or (ch1_req and idx);
      rq2 <= rq2 or (ch2_req and idx);
      rq3 <= rq3 or (ch3_req and idx);

      fifo_rd <= '0';

      -- Avalon command taken at this edge
      free := (cmd_rd = '0' and cmd_wr = '0') or mem_waitrequest = '0';
      if mem_waitrequest = '0' then
        if cmd_wr = '1' then
          if cmd_ack = 1 then ch1_rdy_3x <= '1'; end if;
          if cmd_ack = 3 then ch3_rdy_3x <= '1'; end if;
        end if;
        cmd_rd <= '0';
        cmd_wr <= '0';
      end if;

      -- read data, in order, into the beat RAMs of the job at ret_p
      if mem_readdatavalid = '1' then
        slot := to_integer(ret_p(G_JOBS_LOG2 - 1 downto 0));
        case to_integer(ret_beat) is
          when 0      => bk0(slot) <= mem_readdata;
          when 1      => bk1(slot) <= mem_readdata;
          when others => bk2(slot) <= mem_readdata;
        end case;
        if ret_beat = unsigned(desc(slot)(13 downto 12)) - 1 then
          ret_beat <= "00";
          ret_p    <= ret_p + 1;
        else
          ret_beat <= ret_beat + 1;
        end if;
      end if;

      -- next command
      if free then
        if b2_valid = '1' then
          cmd_rd   <= '1';
          cmd_addr <= b2_addr;
          cmd_bc   <= b2_bc;
          b2_valid <= '0';
        elsif init_s(1) = '0' and SDRAM_EN = '1' then
          used := alloc_p - out_p;
          take := 0;
          a := (others => '0'); d := (others => '0'); be := "1111"; rd := false; kind := K_CPU; nw := 1;
          if fifo_rd = '1' then
            take := 0;                                -- FIFO flags not updated yet: nothing passes it
          elsif dmafifo_empty = '0' then
            take := 1;
          elsif (rq1 = '1' or (ch1_req = '1' and idx = '1')) and
                (ch1_rnw = '0' or (used < C_JOBS and (ch1_dma = '0' or (dma_rp_3x = '0' and dma_rp_b = '0')))) then
            take := 2;
          elsif (rq2 = '1' or (ch2_req = '1' and idx = '1')) and
                ((ch2_rnw = '0' and ch2_rdy_3x = '0' and ch2_rdy_b = '0') or (ch2_rnw = '1' and used < C_JOBS)) then
            take := 3;
          elsif (rq3 = '1' or (ch3_req = '1' and idx = '1')) and (ch3_rnw = '0' or used < C_JOBS) then
            take := 4;
          end if;

          case take is
            when 1 =>
              a := dmafifo_adr; d := dmafifo_data;
              fifo_rd <= '1';
              cmd_ack <= 0;
            when 2 =>
              rq1 <= '0';
              a := ch1_addr; d := x"0000" & ch1_din;
              if ch1_rnw = '1' then
                rd := true;
                if ch1_dma = '1' then
                  kind := K_DMA;
                  nw := to_integer(unsigned(ch1_cntDMA)) + 1;
                  dma_rp_3x <= '1';
                elsif ch1_cache = '1' then
                  kind := K_CACHE;
                  nw := 4 - to_integer(unsigned(ch1_addr(3 downto 2)));
                end if;
              else
                cmd_ack <= 1;
              end if;
            when 3 =>
              rq2 <= '0';
              a := ch2_addr; d := ch2_din; be := ch2_be;
              if ch2_rnw = '1' then
                rd := true; kind := K_CH2;
              else
                ch2_rdy_3x <= '1';
                cmd_ack <= 0;
              end if;
            when 4 =>
              rq3 <= '0';
              a := ch3_addr; d := ch3_din; be := ch3_be;
              if ch3_rnw = '1' then
                rd := true; kind := K_CH3;
              else
                cmd_ack <= 3;
              end if;
            when others =>
              null;
          end case;

          if take /= 0 and rd then
            -- read job: words addr + 4i, i < nw, the column wraps in the 1 KB row
            if a(2) = '1' then
              tot := (nw + 2) / 2;
            else
              tot := (nw + 1) / 2;
            end if;
            room := 128 - to_integer(unsigned(a(9 downto 3)));
            if tot <= room then
              c1 := tot;
            else
              c1 := room;
            end if;
            cmd_rd   <= '1';
            cmd_addr <= a(26 downto 3);
            cmd_bc   <= to_unsigned(c1, 2);
            if c1 < tot then
              b2_valid <= '1';
              b2_addr  <= a(26 downto 10) & "0000000";
              b2_bc    <= to_unsigned(tot - c1, 2);
            end if;
            dsc := kind & a(2) & a(1) & std_logic_vector(to_unsigned(tot, 2)) &
                   std_logic_vector(to_unsigned(nw - 1, 2)) & a(11 downto 4) & a(3 downto 2);
            desc(to_integer(alloc_p(G_JOBS_LOG2 - 1 downto 0))) <= dsc;
            alloc_p <= alloc_p + 1;
          elsif take /= 0 then
            -- write: one beat
            cmd_wr   <= '1';
            cmd_addr <= a(26 downto 3);
            cmd_bc   <= "01";
            cmd_be   <= (others => '0');
            lane := to_integer(unsigned(a(2 downto 1)));
            if take = 2 then
              -- ch1: 16 bit, both bytes
              cmd_wdata <= d(15 downto 0) & d(15 downto 0) & d(15 downto 0) & d(15 downto 0);
              cmd_be(2 * lane + 1 downto 2 * lane) <= "11";
            elsif a(1) = '0' then
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
      end if;

      -- cache words 1..3 (word 0 goes with the output below)
      cache_wr_r <= "0000";
      if cs_n > 0 then
        cache_wr_r   <= cs_mask;
        cache_data_r <= dout_r(32 * (4 - cs_n) + 31 downto 32 * (4 - cs_n));
        cs_mask      <= cs_mask(2 downto 0) & '0';
        cs_n         <= cs_n - 1;
        if cs_n = 3 then
          ch1_rdy_3x <= '1';                      -- word 0 is written at this edge
        end if;
      end if;

      -- output of the job at the head when it is complete
      if ret_p /= out_p then
        slot     := to_integer(out_p(G_JOBS_LOG2 - 1 downto 0));
        dsc      := desc(slot);
        words    := extract(bk0(slot), bk1(slot), bk2(slot), dsc(15), dsc(14));
        cpu_free := ch1_rdy_3x = '0' and ch1_rdy_b = '0' and cs_n = 0;
        cfirst   := to_integer(unsigned(dsc(1 downto 0)));
        if dsc(18 downto 16) = K_CPU and cpu_free then
          dout_r     <= words;
          ch1_rdy_3x <= '1';
          out_p      <= out_p + 1;
        elsif dsc(18 downto 16) = K_CACHE and cpu_free then
          dout_r       <= words;
          cache_addr_r <= dsc(9 downto 2);
          cache_data_r <= words(31 downto 0);
          cache_wr_r   <= (others => '0');
          cache_wr_r(cfirst) <= '1';
          cs_mask      <= (others => '0');
          if cfirst < 3 then
            cs_mask(cfirst + 1) <= '1';
          end if;
          cs_n         <= 3;
          out_p        <= out_p + 1;
        elsif dsc(18 downto 16) = K_DMA and dma_done = '0' and gap = 0 then
          dma_buf    <= words;
          dma_cnt_3x <= dsc(11 downto 10);
          dma_done   <= '1';
          gap        <= G_DMA_GAP - 1;
          out_p      <= out_p + 1;
        elsif dsc(18 downto 16) = K_CH2 and ch2_rdy_3x = '0' and ch2_rdy_b = '0' then
          ch2_dout_r <= words(31 downto 0);
          ch2_rdy_3x <= '1';
          out_p      <= out_p + 1;
        elsif dsc(18 downto 16) = K_CH3 and ch3_rdy_3x = '0' and ch3_rdy_b = '0' then
          ch3_dout_r <= words(31 downto 0);
          ch3_rdy_3x <= '1';
          out_p      <= out_p + 1;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
