-------------------------------------------------------------------------------
-- Title      : BRAM cache in front of the DDR (back end of the SDRAM emulator)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : sdram_cache.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Back end of sdram_emu for the SDRAM regions that live in the DDR of the PS
--   (doc/ARCHITECTURE.md §3, stage C).  Same port as sdram_bram: one 16-bit
--   word per request, read data in request order.  Behind it an Avalon-MM
--   master to avl_axi_bridge (64-bit words, S_AXI_HP0).
--
--   Direct mapped, lines of 2**G_LINE_LOG2 64-bit words, 2**G_INDEX_BITS lines
--   in block RAM.  Word address of a request (16-bit words):
--     tag | index (G_INDEX_BITS) | beat (G_LINE_LOG2) | sub (2)
--   G_SPLIT = 1: the top address bit is the top index bit instead, the tag
--   takes the index bit it replaces:
--     top | tag | index - 1 bits | beat | sub  ->  index = top & index - 1 bits
--   Each half of the address space gets half of the lines, a line of one half
--   never replaces one of the other (SNES: ROM and WRAM with the same low
--   address bits replaced each other on nearly every miss).
--   Avalon word address = request address / 4 (byte address = 2 * request
--   address; the bridge adds the DDR base, G_BYTE_OFFSET).
--
--   Pipeline: a request is accepted into stage 1 (tag and data RAM are read
--   with its address on that edge) and resolved in the next cycle:
--     read hit    rvalid with the data in that cycle (latency 1, as sdram_bram)
--     write       write-through: the word goes into the write FIFO; on a hit
--                 the line is updated too (no allocation on a write miss)
--     read miss   ready stays low; the write FIFO drains, the line is fetched
--                 with one Avalon burst, then the request is looked up again
--   A new request is accepted in the cycle stage 1 resolves, so hits and writes
--   run at one request per cycle.  A read right after a write hit to the same
--   64-bit word gets the new word from a bypass register (the RAM gets the
--   write on the same edge the read address is taken).
--   ready and rvalid depend combinationally on the tag compare; sdram_emu turns
--   them into its stall output.
--
--   Miss classes for the event counters (measurement only, no effect on the
--   data path): a victim tag RAM keeps per line the tag the last line fetch
--   replaced.  A read miss is
--     ev_miss_vict    on that victim (the line came back: a 2-way cache would
--                     have hit, conflict miss)
--     ev_miss_vict_x  ... and the line that replaced it lies in the other half
--                     of the address space (top address bit differs: SNES
--                     ROM <-> WRAM; hashing that bit into the index would help)
--     ev_miss_seq     on the line after the line of the previous miss (a
--                     prefetch of the next line would have hit)
--     ev_miss_hi      in the upper half of the address space
--   ev_rd_hi counts the reads (ev_hit) in the upper half.
--
--   Coherence: the DDR region must only be written through this cache while
--   the core runs.  After reset all lines are invalidated (2**G_INDEX_BITS
--   cycles, ready low).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram_cache is
  generic (
    G_ADDR_BITS  : natural := 24;      -- word address bits of the back end port (16-bit words)
    G_LINE_LOG2  : natural := 2;       -- 64-bit words per line (1..4): 2 -> 32 bytes
    G_INDEX_BITS : natural := 9;       -- lines: 9 -> 512 lines, 16 KB
    G_SPLIT      : natural := 0;       -- 1: top address bit = top index bit (halves apart)
    G_WFIFO_LOG2 : natural := 4;       -- write FIFO depth 2**G_WFIFO_LOG2
    G_AVL_ADDR_W : natural := 29       -- Avalon word address bits (avl_axi_bridge)
  );
  port (
    clk               : in  std_logic;
    rst               : in  std_logic;             -- synchronous, active high

    -- back end port of sdram_emu (through the region decoder)
    req               : in  std_logic;
    we                : in  std_logic;
    addr              : in  std_logic_vector(G_ADDR_BITS - 1 downto 0);
    wdata             : in  std_logic_vector(15 downto 0);
    wstrb             : in  std_logic_vector(1 downto 0);
    ready             : out std_logic;
    rvalid            : out std_logic;
    rdata             : out std_logic_vector(15 downto 0);

    -- Avalon-MM master (avl_axi_bridge)
    avl_waitrequest   : in  std_logic;
    avl_burstcount    : out std_logic_vector(7 downto 0);
    avl_address       : out std_logic_vector(G_AVL_ADDR_W - 1 downto 0);
    avl_read          : out std_logic;
    avl_readdata      : in  std_logic_vector(63 downto 0);
    avl_readdatavalid : in  std_logic;
    avl_write         : out std_logic;
    avl_writedata     : out std_logic_vector(63 downto 0);
    avl_byteenable    : out std_logic_vector(7 downto 0);

    ev_hit            : out std_logic;             -- pulse: read data delivered (every read once,
                                                   -- a miss after its line fetch)
    ev_miss           : out std_logic;             -- pulse: read miss, line fetch starts
    ev_miss_hi        : out std_logic;             -- with ev_miss: address in the upper half
    ev_miss_vict      : out std_logic;             -- with ev_miss: the line the last fetch replaced
    ev_miss_vict_x    : out std_logic;             -- with ev_miss_vict: line in the other half replaced it
    ev_miss_seq       : out std_logic;             -- with ev_miss: line after the previous miss line
    ev_rd_hi          : out std_logic;             -- with ev_hit: address in the upper half
    ev_busy           : out std_logic;             -- cycle of a miss (drain, fill, replay)
    ev_drain          : out std_logic;             -- cycle of a miss waiting for the write FIFO
    ev_wfull          : out std_logic;             -- cycle a write waits for a free FIFO entry
    ev_write          : out std_logic;             -- pulse: write into the FIFO
    err               : out std_logic              -- sticky: read data outside a line fetch
  );
end entity sdram_cache;

architecture rtl of sdram_cache is

  constant C_TAG   : natural := G_ADDR_BITS - 2 - G_LINE_LOG2 - G_INDEX_BITS;
  constant C_DADDR : natural := G_INDEX_BITS + G_LINE_LOG2;        -- data RAM address bits
  constant C_WADDR : natural := G_ADDR_BITS - 2;                   -- 64-bit word address bits
  constant C_WF    : natural := 2 ** G_WFIFO_LOG2;

  type state_t is (S_INIT, S_RUN, S_DRAIN, S_FILL_REQ, S_FILL_DATA, S_REPLAY);
  signal state     : state_t;

  -- RAMs (read address registered, read first)
  type data_ram_t is array (0 to 2 ** C_DADDR - 1) of std_logic_vector(63 downto 0);
  type tag_ram_t is array (0 to 2 ** G_INDEX_BITS - 1) of std_logic_vector(C_TAG downto 0);  -- valid & tag
  signal data_ram  : data_ram_t;
  signal tag_ram   : tag_ram_t := (others => (others => '0'));
  signal vict_ram  : tag_ram_t := (others => (others => '0'));   -- tag the last fetch replaced
  signal rd_addr   : std_logic_vector(G_ADDR_BITS - 1 downto 0);
  signal d_q       : std_logic_vector(63 downto 0);
  signal t_q       : std_logic_vector(C_TAG downto 0);
  signal v_q       : std_logic_vector(C_TAG downto 0);
  signal v_wd      : std_logic_vector(C_TAG downto 0);
  signal old_tag   : std_logic_vector(C_TAG downto 0);           -- tag of the line a miss replaces
  signal last_line : std_logic_vector(C_WADDR - G_LINE_LOG2 - 1 downto 0);
  signal last_v    : std_logic;
  signal d_we      : std_logic;
  signal d_wa      : std_logic_vector(C_DADDR - 1 downto 0);
  signal d_wd      : std_logic_vector(63 downto 0);
  signal t_we      : std_logic;
  signal t_wa      : std_logic_vector(G_INDEX_BITS - 1 downto 0);
  signal t_wd      : std_logic_vector(C_TAG downto 0);

  -- stage 1
  signal s1_v      : std_logic;
  signal s1_we     : std_logic;
  signal s1_addr   : std_logic_vector(G_ADDR_BITS - 1 downto 0);
  signal s1_wdata  : std_logic_vector(15 downto 0);
  signal s1_wstrb  : std_logic_vector(1 downto 0);
  signal s1_sub    : std_logic_vector(1 downto 0);
  signal hit       : std_logic;
  signal word      : std_logic_vector(63 downto 0);  -- 64-bit word of stage 1
  signal merged    : std_logic_vector(63 downto 0);  -- word with the stage 1 write applied
  signal rd_hit    : std_logic;
  signal wr_go     : std_logic;
  signal ready_i   : std_logic;
  signal accept    : std_logic;

  -- bypass: the word written on the previous edge
  signal lw_v      : std_logic;
  signal lw_addr   : std_logic_vector(C_WADDR - 1 downto 0);
  signal lw_data   : std_logic_vector(63 downto 0);

  -- write FIFO: word address, data, byte enables of 16-bit writes
  type wf_addr_t is array (0 to C_WF - 1) of std_logic_vector(G_ADDR_BITS - 1 downto 0);
  type wf_data_t is array (0 to C_WF - 1) of std_logic_vector(17 downto 0);
  signal wf_addr   : wf_addr_t;
  signal wf_data   : wf_data_t;
  signal wf_wr     : unsigned(G_WFIFO_LOG2 - 1 downto 0);
  signal wf_rd     : unsigned(G_WFIFO_LOG2 - 1 downto 0);
  signal wf_cnt    : unsigned(G_WFIFO_LOG2 downto 0);
  signal wf_push   : std_logic;
  signal wf_pop    : std_logic;
  signal wf_head_a : std_logic_vector(G_ADDR_BITS - 1 downto 0);
  signal wf_head_d : std_logic_vector(17 downto 0);
  signal wf_sub    : std_logic_vector(1 downto 0);

  signal fill_cnt  : unsigned(G_LINE_LOG2 - 1 downto 0);
  signal init_idx  : unsigned(G_INDEX_BITS - 1 downto 0);
  signal avl_rd_i  : std_logic;
  signal avl_wr_i  : std_logic;
  signal err_i     : std_logic;

  function f_tag(a : std_logic_vector) return std_logic_vector is
  begin
    if G_SPLIT /= 0 then
      return a(G_ADDR_BITS - 2 downto G_ADDR_BITS - 1 - C_TAG);
    end if;
    return a(G_ADDR_BITS - 1 downto G_ADDR_BITS - C_TAG);
  end function;
  function f_index(a : std_logic_vector) return std_logic_vector is
  begin
    if G_SPLIT /= 0 then
      return a(G_ADDR_BITS - 1) & a(G_LINE_LOG2 + G_INDEX_BITS downto G_LINE_LOG2 + 2);
    end if;
    return a(G_LINE_LOG2 + G_INDEX_BITS + 1 downto G_LINE_LOG2 + 2);
  end function;
  function f_daddr(a : std_logic_vector) return std_logic_vector is
  begin
    return f_index(a) & a(G_LINE_LOG2 + 1 downto 2);
  end function;

begin

  assert C_TAG >= 1 and G_LINE_LOG2 >= 1 and G_LINE_LOG2 <= 4 and G_SPLIT <= 1 and G_INDEX_BITS >= 1 + G_SPLIT
    report "sdram_cache: no tag bits left, line not 2..16 words, or G_SPLIT not 0/1" severity failure;

  ------------------------------------------------------------------------------
  -- RAMs
  ------------------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      if d_we = '1' then
        data_ram(to_integer(unsigned(d_wa))) <= d_wd;
      end if;
      d_q <= data_ram(to_integer(unsigned(f_daddr(rd_addr))));
    end if;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if t_we = '1' then
        tag_ram(to_integer(unsigned(t_wa))) <= t_wd;
      end if;
      t_q <= tag_ram(to_integer(unsigned(f_index(rd_addr))));
    end if;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if t_we = '1' then
        vict_ram(to_integer(unsigned(t_wa))) <= v_wd;
      end if;
      v_q <= vict_ram(to_integer(unsigned(f_index(rd_addr))));
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- stage 1: tag compare, read data, write merge
  ------------------------------------------------------------------------------
  hit <= '1' when t_q(C_TAG) = '1' and t_q(C_TAG - 1 downto 0) = f_tag(s1_addr) else '0';

  word <= lw_data when lw_v = '1' and lw_addr = s1_addr(G_ADDR_BITS - 1 downto 2) else d_q;

  process (word, s1_addr, s1_wdata, s1_wstrb)
    variable m   : std_logic_vector(63 downto 0);
    variable sub : natural range 0 to 3;
  begin
    m   := word;
    sub := to_integer(unsigned(s1_addr(1 downto 0)));
    if s1_wstrb(0) = '1' then m(16 * sub + 7 downto 16 * sub) := s1_wdata(7 downto 0); end if;
    if s1_wstrb(1) = '1' then m(16 * sub + 15 downto 16 * sub + 8) := s1_wdata(15 downto 8); end if;
    merged <= m;
  end process;

  s1_sub <= s1_addr(1 downto 0);
  with s1_sub select rdata <=
    word(15 downto 0)  when "00",
    word(31 downto 16) when "01",
    word(47 downto 32) when "10",
    word(63 downto 48) when others;

  rd_hit  <= '1' when state = S_RUN and s1_v = '1' and s1_we = '0' and hit = '1' else '0';
  wr_go   <= '1' when state = S_RUN and s1_v = '1' and s1_we = '1' and wf_cnt < C_WF else '0';
  ready_i <= '1' when state = S_RUN and (s1_v = '0' or rd_hit = '1' or wr_go = '1') else '0';
  accept  <= req and ready_i;
  rd_addr <= addr when accept = '1' else s1_addr;   -- otherwise stage 1 reads its own word again

  ready   <= ready_i;
  rvalid  <= rd_hit;
  ev_hit  <= rd_hit;
  ev_rd_hi <= rd_hit and s1_addr(G_ADDR_BITS - 1);
  ev_busy  <= '1' when state = S_DRAIN or state = S_FILL_REQ or state = S_FILL_DATA or state = S_REPLAY else '0';
  ev_drain <= '1' when state = S_DRAIN else '0';
  ev_wfull <= '1' when state = S_RUN and s1_v = '1' and s1_we = '1' and wf_cnt = C_WF else '0';
  ev_write <= wr_go;

  ------------------------------------------------------------------------------
  -- RAM writes: write hit or line fetch; tags: line fetch or invalidation
  ------------------------------------------------------------------------------
  d_we <= '1' when (wr_go = '1' and hit = '1') or (state = S_FILL_DATA and avl_readdatavalid = '1') else '0';
  d_wa <= f_daddr(s1_addr) when state = S_RUN else
          f_index(s1_addr) & std_logic_vector(fill_cnt);
  d_wd <= merged when state = S_RUN else avl_readdata;

  t_we <= '1' when state = S_INIT or (state = S_FILL_DATA and avl_readdatavalid = '1' and fill_cnt = 2 ** G_LINE_LOG2 - 1)
          else '0';
  t_wa <= std_logic_vector(init_idx) when state = S_INIT else f_index(s1_addr);
  t_wd <= (others => '0') when state = S_INIT else '1' & f_tag(s1_addr);
  v_wd <= (others => '0') when state = S_INIT else old_tag;

  ------------------------------------------------------------------------------
  -- write FIFO and Avalon master (writes single beats, line fetch one burst)
  ------------------------------------------------------------------------------
  wf_push   <= wr_go;
  wf_head_a <= wf_addr(to_integer(wf_rd));
  wf_head_d <= wf_data(to_integer(wf_rd));
  avl_rd_i  <= '1' when state = S_FILL_REQ else '0';
  avl_wr_i  <= '1' when state /= S_FILL_REQ and wf_cnt /= 0 else '0';
  wf_pop    <= avl_wr_i and not avl_waitrequest;

  avl_read       <= avl_rd_i;
  avl_write      <= avl_wr_i;
  avl_burstcount <= std_logic_vector(to_unsigned(2 ** G_LINE_LOG2, 8)) when avl_rd_i = '1' else x"01";
  process (avl_rd_i, s1_addr, wf_head_a)
    variable a : std_logic_vector(C_WADDR - 1 downto 0);
  begin
    if avl_rd_i = '1' then
      a := s1_addr(G_ADDR_BITS - 1 downto 2);
      a(G_LINE_LOG2 - 1 downto 0) := (others => '0');     -- line start
    else
      a := wf_head_a(G_ADDR_BITS - 1 downto 2);
    end if;
    avl_address <= std_logic_vector(resize(unsigned(a), G_AVL_ADDR_W));
  end process;
  avl_writedata <= wf_head_d(15 downto 0) & wf_head_d(15 downto 0) & wf_head_d(15 downto 0) & wf_head_d(15 downto 0);
  wf_sub <= wf_head_a(1 downto 0);
  process (wf_sub, wf_head_d)
    variable be : std_logic_vector(7 downto 0);
  begin
    be := (others => '0');
    case wf_sub is
      when "00"   => be(1 downto 0) := wf_head_d(17 downto 16);
      when "01"   => be(3 downto 2) := wf_head_d(17 downto 16);
      when "10"   => be(5 downto 4) := wf_head_d(17 downto 16);
      when others => be(7 downto 6) := wf_head_d(17 downto 16);
    end case;
    avl_byteenable <= be;
  end process;

  ------------------------------------------------------------------------------
  -- state
  ------------------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      ev_miss        <= '0';
      ev_miss_hi     <= '0';
      ev_miss_vict   <= '0';
      ev_miss_vict_x <= '0';
      ev_miss_seq    <= '0';

      -- stage 1
      if accept = '1' then
        s1_v     <= '1';
        s1_we    <= we;
        s1_addr  <= addr;
        s1_wdata <= wdata;
        s1_wstrb <= wstrb;
      elsif rd_hit = '1' or wr_go = '1' then
        s1_v <= '0';
      end if;

      -- bypass of the word written on this edge
      lw_v    <= wr_go and hit;
      lw_addr <= s1_addr(G_ADDR_BITS - 1 downto 2);
      lw_data <= merged;

      -- write FIFO
      if wf_push = '1' then
        wf_addr(to_integer(wf_wr)) <= s1_addr;
        wf_data(to_integer(wf_wr)) <= s1_wstrb & s1_wdata;
        wf_wr <= wf_wr + 1;
      end if;
      if wf_pop = '1' then
        wf_rd <= wf_rd + 1;
      end if;
      if wf_push = '1' and wf_pop = '0' then
        wf_cnt <= wf_cnt + 1;
      elsif wf_push = '0' and wf_pop = '1' then
        wf_cnt <= wf_cnt - 1;
      end if;

      case state is
        when S_INIT =>
          init_idx <= init_idx + 1;
          if init_idx = 2 ** G_INDEX_BITS - 1 then
            state <= S_RUN;
          end if;

        when S_RUN =>
          if s1_v = '1' and s1_we = '0' and hit = '0' then
            state   <= S_DRAIN;
            ev_miss <= '1';
            -- miss classes (measurement)
            old_tag    <= t_q;
            ev_miss_hi <= s1_addr(G_ADDR_BITS - 1);
            if v_q(C_TAG) = '1' and v_q(C_TAG - 1 downto 0) = f_tag(s1_addr) then
              ev_miss_vict <= '1';
              -- top address bit of the occupant: tag MSB; with G_SPLIT the index (same half)
              if G_SPLIT = 0 and t_q(C_TAG) = '1' and t_q(C_TAG - 1) /= s1_addr(G_ADDR_BITS - 1) then
                ev_miss_vict_x <= '1';
              end if;
            end if;
            if last_v = '1' and unsigned(s1_addr(G_ADDR_BITS - 1 downto G_LINE_LOG2 + 2)) = unsigned(last_line) + 1 then
              ev_miss_seq <= '1';
            end if;
            last_line <= s1_addr(G_ADDR_BITS - 1 downto G_LINE_LOG2 + 2);
            last_v    <= '1';
          end if;

        when S_DRAIN =>                              -- older writes reach the DDR first
          if wf_cnt = 0 then
            state <= S_FILL_REQ;
          end if;

        when S_FILL_REQ =>
          fill_cnt <= (others => '0');
          if avl_waitrequest = '0' then
            state <= S_FILL_DATA;
          end if;

        when S_FILL_DATA =>
          if avl_readdatavalid = '1' then
            fill_cnt <= fill_cnt + 1;
            if fill_cnt = 2 ** G_LINE_LOG2 - 1 then
              state <= S_REPLAY;                     -- tag written on this edge
            end if;
          end if;

        when S_REPLAY =>                             -- stage 1 reads tag and data again
          state <= S_RUN;
      end case;

      if avl_readdatavalid = '1' and state /= S_FILL_DATA then
        err_i <= '1';
      end if;

      if rst = '1' then
        state    <= S_INIT;
        init_idx <= (others => '0');
        s1_v     <= '0';
        lw_v     <= '0';
        wf_wr    <= (others => '0');
        wf_rd    <= (others => '0');
        wf_cnt   <= (others => '0');
        fill_cnt <= (others => '0');
        err_i    <= '0';
        last_v   <= '0';
      end if;
    end if;
  end process;

  err <= err_i;

end architecture rtl;
