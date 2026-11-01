-------------------------------------------------------------------------------
-- Title      : Testbench of the PSX SDRAM controller replacement
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : psx_sdram_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-31
-------------------------------------------------------------------------------
-- Description:
--   cores/psx/sdram.vhd against a reference of what rtl/sdram.sv (PSX_MiSTer
--   cd17b5a) shows at its ports, with clk = 3 x clk_base, phase aligned (one
--   process makes both).  Reference: a byte memory with the
--   original's 16-bit word semantics: a 32-bit read at byte address a gives
--   16-bit word W = a/2 in bits 15:0 and W xor 1 in bits 31:16; a write puts
--   din(15:0) (be(1:0)) into W and din(31:16) (be(3:2)) into W or 1; ch1
--   cache/DMA reads give the words a + 4i with the column wrapping in the
--   1 KB row.  Behind the DUT an Avalon slave model: random waitrequest,
--   read latency, gaps between the beats of a burst, data in order and
--   sampled when the command is taken; every beat must lie in one of two
--   windows (32 KB at 0x0638000, 4 KB at 0x4A3F000 with address bit 26).
--   Protocol checker: command held while waitrequest, no read and write at
--   once, burstcount (reads 1..16, writes 1), no 4 KB crossing, no new
--   command while init.  The DMA write FIFO is the core's own
--   SyncFifoFallThrough (compiled from the checkout), written on clk3xIndex
--   as in dma.vhd.  Channel drivers as in the core: CPU (memorymux: one
--   ch1 read / ch2 write at a time, next request one clk_base cycle after
--   ready), DMA (dma.vhd: next block request at the edge it sees
--   dma_reqprocessed, address held until then), download and cheats on
--   ch3 (request held until ready).
--   Checks: read data (ch1_dout32 with ch1_ready, ch3_dout, dma_data per
--   dma_wr), cache: cache_wr one-hot and only for the words from addr to the
--   line end, cache_addr, cache_data, and word k of the line in the model
--   cache RAM (written at an earlier clk edge) by k clk_base edges after
--   ch1_ready; DMA: cnt+1 dma_wr in consecutive cycles per block, never two
--   blocks closer than the original allows (13 clk per block), one
--   dma_reqprocessed per block request; one ready per request on every
--   channel; dmafifo_read only when the FIFO holds a word; ram_idle low
--   while a read waits and with ch3_req; SDRAM pins inactive; at the end the
--   Avalon memory equals the reference byte for byte.
--   Phases: 0 init (requests held, no Avalon command); 1 download (ch3,
--   both windows); 2 600 random CPU operations; 3 300 DMA blocks (a fifth
--   of them wrap in the row); 4 DMA writes through the FIFO, CPU reads after
--   them; 5 CPU || cheats, DMA || cheats; 6 fast memory: read latency and
--   DMA block rate; 7 unused ports (ch1 write, ch2 read).  Prints the
--   latencies.  Ends with "PASS" or a failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity psx_sdram_tb is
end entity;

architecture tb of psx_sdram_tb is

  constant T3     : time := 10 ns;                       -- clk (clk_3x); clk_base = 3 * T3
  constant A_BASE : natural := 16#0638000#;
  constant A_SIZE : natural := 16#8000#;
  constant B_BASE : natural := 16#4A3F000#;
  constant B_SIZE : natural := 16#1000#;
  constant NB     : natural := A_SIZE + B_SIZE;

  subtype slv32 is std_logic_vector(31 downto 0);
  type byte_array is array (natural range <>) of std_logic_vector(7 downto 0);
  type beat_array is array (natural range <>) of std_logic_vector(63 downto 0);
  type word_array is array (natural range <>) of slv32;
  type cline_t is array (0 to 3) of slv32;
  type cram_t is array (0 to 255) of cline_t;
  type ctime_t is array (0 to 255, 0 to 3) of time;

  function f_init(i : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned((i * 37 + (i / 256) * 11 + 5) mod 256, 8));
  end function;

  function init_ref return byte_array is
    variable r : byte_array(0 to NB - 1);
  begin
    for i in r'range loop
      r(i) := f_init(i);
    end loop;
    return r;
  end function;

  function init_amem return beat_array is
    variable r : beat_array(0 to NB / 8 - 1);
  begin
    for k in r'range loop
      for b in 0 to 7 loop
        r(k)(8 * b + 7 downto 8 * b) := f_init(8 * k + b);
      end loop;
    end loop;
    return r;
  end function;

  -- byte address -> index in ref (window A, then B)
  function bidx(a : natural) return natural is
  begin
    if a >= A_BASE and a < A_BASE + A_SIZE then
      return a - A_BASE;
    elsif a >= B_BASE and a < B_BASE + B_SIZE then
      return A_SIZE + a - B_BASE;
    end if;
    report "address " & to_hstring(to_unsigned(a, 28)) & " outside the windows" severity failure;
    return 0;
  end function;

  shared variable ref  : byte_array(0 to NB - 1) := init_ref;
  shared variable amem : beat_array(0 to NB / 8 - 1) := init_amem;

  -- original: 32-bit read at a (16-bit words W and W xor 1)
  impure function ref_read32(a : natural) return slv32 is
    variable w : natural := (a / 2) * 2;
    variable p : natural := ((a / 2) mod 2) * 0;
    variable lo, hi : std_logic_vector(15 downto 0);
    variable w1 : natural;
  begin
    if (a / 2) mod 2 = 0 then
      w1 := w + 2;
    else
      w1 := w - 2;
    end if;
    lo := ref(bidx(w + 1)) & ref(bidx(w));
    hi := ref(bidx(w1 + 1)) & ref(bidx(w1));
    return hi & lo;
  end function;

  -- original: word i of a 128-bit read (column wraps in the 1 KB row)
  impure function ref_word(a, i : natural) return slv32 is
  begin
    return ref_read32((a / 1024) * 1024 + (a + 4 * i) mod 1024);
  end function;

  -- original: 32-bit write, din(15:0) to W, din(31:16) to W or 1
  procedure ref_write32(a : natural; d : slv32; be : std_logic_vector(3 downto 0)) is
    variable w0 : natural := (a / 2) * 2;
    variable w1 : natural := ((a / 2) - ((a / 2) mod 2) + 1) * 2;
  begin
    for b in 0 to 1 loop
      if be(b) = '1' then
        ref(bidx(w0 + b)) := d(8 * b + 7 downto 8 * b);
      end if;
    end loop;
    for b in 0 to 1 loop
      if be(2 + b) = '1' then
        ref(bidx(w1 + b)) := d(16 + 8 * b + 7 downto 16 + 8 * b);
      end if;
    end loop;
  end procedure;

  function a27(a : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(a, 27));
  end function;

  -- DMA blocks expected (dma agent -> dma monitor)
  shared variable dq_word  : word_array(0 to 16383);
  shared variable dq_len   : word_array(0 to 16383);     -- block length at its first word, else 0
  shared variable dq_w     : natural := 0;
  -- cache line expected (cpu -> cache monitor)
  shared variable cx_active : boolean := false;
  shared variable cx_line   : natural := 0;
  shared variable cx_first  : natural := 0;
  shared variable cx_words  : cline_t;
  shared variable cx_done   : std_logic_vector(3 downto 0);

  signal clk, clk_base : std_logic := '0';
  signal done          : boolean := false;
  signal init          : std_logic := '1';
  signal refresh_force : std_logic := '0';

  -- DUT ports
  signal ch1_addr, ch2_addr, ch3_addr, dmafifo_adr : std_logic_vector(26 downto 0) := (others => '0');
  signal ch1_dout : std_logic_vector(127 downto 0);
  signal ch1_dout32, ch2_dout, ch3_dout, ch2_din, ch3_din, cache_data, dma_data, dmafifo_data : slv32;
  signal ch1_din : std_logic_vector(15 downto 0);
  signal ch1_req, ch1_rnw, ch1_dma, ch1_cache, ch1_ready, dma_wr, dma_rp : std_logic;
  signal ch1_cnt : std_logic_vector(1 downto 0);
  signal cache_wr, ch2_be, ch3_be : std_logic_vector(3 downto 0);
  signal cache_addr : std_logic_vector(7 downto 0);
  signal ch2_req, ch2_rnw, ch2_ready, ch3_req, ch3_rnw, ch3_ready : std_logic;
  signal dmafifo_empty, dmafifo_read, ram_idle : std_logic;
  signal sd_dq : std_logic_vector(15 downto 0);
  signal sd_ncs : std_logic;
  signal mem_clk, mem_waitrequest, mem_readdatavalid, mem_read, mem_write : std_logic;
  signal mem_address : std_logic_vector(28 downto 0);
  signal mem_burstcount, mem_byteenable : std_logic_vector(7 downto 0);
  signal mem_readdata, mem_writedata : std_logic_vector(63 downto 0);

  -- agents
  signal cpu_addr : std_logic_vector(26 downto 0) := (others => '0');
  signal cpu_req, cpu_cache : std_logic := '0';
  signal cpu_rnw : std_logic := '1';
  signal cpu_din16 : std_logic_vector(15 downto 0) := (others => '0');
  signal w_addr : std_logic_vector(26 downto 0) := (others => '0');
  signal w_din : slv32 := (others => '0');
  signal w_be : std_logic_vector(3 downto 0) := "1111";
  signal w_req : std_logic := '0';
  signal w_rnw : std_logic := '0';
  signal dma_addr : std_logic_vector(26 downto 0) := (others => '0');
  signal dma_cnt : std_logic_vector(1 downto 0) := "00";
  signal dma_req, dma_mode : std_logic := '0';

  -- DMA write FIFO (dma.vhd DMAfifoOut)
  signal fifo_din, fifo_dout : std_logic_vector(52 downto 0) := (others => '0');
  signal fifo_wr, fifo_wr3, fifo_full : std_logic := '0';
  signal tb_tog, tt3, tt3_1, tb_idx : std_logic := '0';

  -- agent control
  signal dma_go, dma_fin : boolean := false;
  signal dma_n_jobs, dma_base, dma_size, dma_wrap_pct, dma_cnt_fix : natural := 0;
  signal c3_go, c3_fin : boolean := false;
  signal c3_mode, c3_n, c3_base, c3_size : natural := 0;      -- mode 0 download, 1 cheats, 2 reads
  signal ff_go, ff_fin : boolean := false;
  signal ff_n, ff_base, ff_size : natural := 0;
  signal ff_last : natural := 0;                              -- address of the last word pushed
  signal ff_dense : boolean := false;                         -- no idle cycles between the words

  -- Avalon model mode
  signal avl_wait_pct : natural := 30;
  signal avl_lat_max  : natural := 30;

  -- counters: requests (agents) and responses (monitor)
  signal n_cpu_rd, n_ch1_wr, n_ch2_wr, n_ch2_rd, n_ch3, n_dma : natural := 0;
  signal n_ch1_rdy, n_ch2_rdy, n_ch3_rdy, n_dma_rp, n_fifo_rd, n_fifo_wr, n_dma_words : natural := 0;
  signal dq_r_s : natural := 0;
  signal cram : cram_t;
  signal ctime : ctime_t := (others => (others => 0 ns));

begin

  clkgen : process
    variable k : natural := 0;
  begin
    while not done loop
      if k mod 2 = 0 then
        clk <= '1';
      else
        clk <= '0';
      end if;
      if k mod 6 = 0 then
        clk_base <= '1';
      elsif k mod 6 = 3 then
        clk_base <= '0';
      end if;
      k := k + 1;
      wait for T3 / 2;
    end loop;
    wait;
  end process;

  watchdog : process
  begin
    wait for 30 ms;
    assert done report "timeout" severity failure;
    wait;
  end process;

  -- ch1 as in psx_top: DMA or CPU (cpuPaused), ch2 the CPU writes
  ch1_addr  <= dma_addr when dma_mode = '1' else cpu_addr;
  ch1_req   <= dma_req or cpu_req;
  ch1_dma   <= dma_mode;
  ch1_cache <= cpu_cache and not dma_mode;
  ch1_cnt   <= dma_cnt;
  ch1_rnw   <= cpu_rnw;
  ch1_din   <= cpu_din16;
  ch2_addr  <= w_addr;
  ch2_din   <= w_din;
  ch2_be    <= w_be;
  ch2_req   <= w_req;
  ch2_rnw   <= w_rnw;

  dut : entity work.sdram
    port map (
      init => init, clk => clk, clk_base => clk_base, SDRAM_EN => '1',
      SDRAM_DQ => sd_dq, SDRAM_A => open, SDRAM_DQML => open, SDRAM_DQMH => open, SDRAM_BA => open,
      SDRAM_nCS => sd_ncs, SDRAM_nWE => open, SDRAM_nRAS => open, SDRAM_nCAS => open, SDRAM_CKE => open,
      SDRAM_CLK => open,
      refreshForce => refresh_force, ram_idle => ram_idle,
      ch1_addr => ch1_addr, ch1_dout => ch1_dout, ch1_dout32 => ch1_dout32, ch1_din => ch1_din,
      ch1_req => ch1_req, ch1_rnw => ch1_rnw, ch1_dma => ch1_dma, ch1_cntDMA => ch1_cnt,
      ch1_cache => ch1_cache, ch1_ready => ch1_ready,
      cache_wr => cache_wr, cache_data => cache_data, cache_addr => cache_addr,
      dma_wr => dma_wr, dma_reqprocessed => dma_rp, dma_data => dma_data,
      ch2_addr => ch2_addr, ch2_dout => ch2_dout, ch2_din => ch2_din, ch2_req => ch2_req,
      ch2_rnw => ch2_rnw, ch2_be => ch2_be, ch2_ready => ch2_ready,
      ch3_addr => ch3_addr, ch3_dout => ch3_dout, ch3_din => ch3_din, ch3_req => ch3_req,
      ch3_rnw => ch3_rnw, ch3_be => ch3_be, ch3_ready => ch3_ready,
      dmafifo_adr => dmafifo_adr, dmafifo_data => dmafifo_data, dmafifo_empty => dmafifo_empty,
      dmafifo_read => dmafifo_read,
      mem_clk => mem_clk, mem_address => mem_address, mem_burstcount => mem_burstcount,
      mem_waitrequest => mem_waitrequest, mem_readdata => mem_readdata, mem_readdatavalid => mem_readdatavalid,
      mem_read => mem_read, mem_writedata => mem_writedata, mem_byteenable => mem_byteenable,
      mem_write => mem_write);

  ------------------------------------------------------------------------------
  -- DMA write FIFO of dma.vhd: written once per clk_base cycle on clk3xIndex
  ------------------------------------------------------------------------------
  tog : process (clk_base)
  begin
    if rising_edge(clk_base) then
      tb_tog <= not tb_tog;
    end if;
  end process;

  idxp : process (clk)
  begin
    if rising_edge(clk) then
      tt3  <= tb_tog;
      tt3_1 <= tt3;
      if tt3_1 = tb_tog then tb_idx <= '1'; else tb_idx <= '0'; end if;
    end if;
  end process;

  fifo_wr3 <= tb_idx and fifo_wr;

  fifo : entity work.SyncFifoFallThrough
    generic map (SIZE => 64, DATAWIDTH => 53, NEARFULLDISTANCE => 56, NEAREMPTYDISTANCE => 2)
    port map (clk => clk, reset => '0', Din => fifo_din, Wr => fifo_wr3, Full => fifo_full, NearFull => open,
              Dout => fifo_dout, Rd => dmafifo_read, Empty => dmafifo_empty, NearEmpty => open);

  dmafifo_adr  <= "0000" & fifo_dout(52 downto 32) & "00";
  dmafifo_data <= fifo_dout(31 downto 0);

  ------------------------------------------------------------------------------
  -- Avalon slave
  ------------------------------------------------------------------------------
  avl : process
    constant QN : natural := 1024;
    type q_t is array (0 to QN - 1) of std_logic_vector(63 downto 0);
    type qt_t is array (0 to QN - 1) of natural;
    variable q : q_t;
    variable qt : qt_t;
    variable qw, qr, now_c, t, k : natural := 0;
    variable s1, s2 : positive := 7;
    variable r : real;
    variable last_t : natural := 0;
  begin
    mem_waitrequest <= '1';
    mem_readdatavalid <= '0';
    loop
      wait until rising_edge(clk);
      now_c := now_c + 1;
      if mem_waitrequest = '0' and (mem_read = '1' or mem_write = '1') then
        k := bidx(to_integer(unsigned(mem_address)) * 8) / 8;
        if mem_write = '1' then
          for b in 0 to 7 loop
            if mem_byteenable(b) = '1' then
              amem(k)(8 * b + 7 downto 8 * b) := mem_writedata(8 * b + 7 downto 8 * b);
            end if;
          end loop;
        else
          uniform(s1, s2, r);
          t := now_c + 1 + integer(floor(r * real(avl_lat_max)));
          for i in 0 to to_integer(unsigned(mem_burstcount)) - 1 loop
            k := bidx((to_integer(unsigned(mem_address)) + i) * 8) / 8;
            if t < last_t then
              t := last_t;
            end if;
            q(qw mod QN) := amem(k);
            qt(qw mod QN) := t;
            last_t := t + 1;
            uniform(s1, s2, r);
            if avl_lat_max > 1 and r < 0.3 then
              t := last_t + 1 + integer(floor(r * 6.0));      -- gap inside the burst
            else
              t := last_t;
            end if;
            qw := qw + 1;
          end loop;
        end if;
      end if;
      if mem_readdatavalid = '1' then
        qr := qr + 1;
      end if;
      mem_readdatavalid <= '0';
      mem_readdata <= (others => 'X');
      if qr < qw and qt(qr mod QN) <= now_c then
        mem_readdatavalid <= '1';
        mem_readdata <= q(qr mod QN);
      end if;
      uniform(s1, s2, r);
      if r * 100.0 < real(avl_wait_pct) then
        mem_waitrequest <= '1';
      else
        mem_waitrequest <= '0';
      end if;
    end loop;
  end process;

  -- Avalon rules, SDRAM pins, init
  avl_chk : process
    variable p_rd, p_wr, p_wait, init_p : std_logic := '0';
    variable p_addr : std_logic_vector(28 downto 0);
    variable p_bc, p_be : std_logic_vector(7 downto 0);
    variable p_wd : std_logic_vector(63 downto 0);
    variable a0, a1 : natural;
  begin
    wait until rising_edge(clk);
    assert sd_dq = x"ZZZZ" and sd_ncs = '1' report "SDRAM pins active" severity failure;
    assert mem_read = '0' or mem_write = '0' report "read and write at once" severity failure;
    if (p_rd = '1' or p_wr = '1') and p_wait = '1' then
      assert mem_read = p_rd and mem_write = p_wr and mem_address = p_addr and mem_burstcount = p_bc
        report "Avalon command changed while waitrequest" severity failure;
      if p_wr = '1' then
        assert mem_writedata = p_wd and mem_byteenable = p_be
          report "Avalon write data changed while waitrequest" severity failure;
      end if;
    elsif mem_read = '1' or mem_write = '1' then
      -- a new command
      assert init_p = '0' report "Avalon command while init" severity failure;
      if mem_read = '1' then
        assert unsigned(mem_burstcount) >= 1 and unsigned(mem_burstcount) <= 16
          report "read burstcount " & to_hstring(mem_burstcount) severity failure;
      else
        assert mem_burstcount = x"01" report "write burstcount " & to_hstring(mem_burstcount) severity failure;
        assert mem_byteenable /= x"00" report "write without byte enables" severity failure;
      end if;
      a0 := to_integer(unsigned(mem_address)) * 8;
      a1 := a0 + to_integer(unsigned(mem_burstcount)) * 8 - 1;
      assert a0 / 4096 = a1 / 4096 report "burst crosses 4 KB" severity failure;
    end if;
    p_rd := mem_read; p_wr := mem_write; p_wait := mem_waitrequest; p_addr := mem_address;
    p_bc := mem_burstcount; p_be := mem_byteenable; p_wd := mem_writedata;
    init_p := init;
  end process;

  mem_clk_chk : process
  begin
    wait until rising_edge(mem_clk);
    assert clk = '1' and clk'last_event = 0 ns report "mem_clk is not clk" severity failure;
  end process;

  ------------------------------------------------------------------------------
  -- cache RAM of cpu.vhd (clk) and the cache_wr check
  ------------------------------------------------------------------------------
  cache_mon : process
    variable n1 : natural;
    variable i : natural;
  begin
    wait until rising_edge(clk);
    if cache_wr /= "0000" then
      n1 := 0;
      for b in 0 to 3 loop
        if cache_wr(b) = '1' then n1 := n1 + 1; i := b; end if;
      end loop;
      assert n1 = 1 report "cache_wr not one-hot: " & to_string(cache_wr) severity failure;
      assert cx_active report "cache_wr without a cache read" severity failure;
      assert to_integer(unsigned(cache_addr)) = cx_line report "cache_addr" severity failure;
      assert i >= cx_first report "cache_wr before the requested word" severity failure;
      assert cache_data = cx_words(i - cx_first)
        report "cache_data word " & integer'image(i) & ": " & to_hstring(cache_data) & " expected " &
               to_hstring(cx_words(i - cx_first)) severity failure;
      assert cx_done(i) = '0' report "cache word written twice" severity failure;
      cx_done(i) := '1';
      cram(cx_line)(i) <= cache_data;
      ctime(cx_line, i) <= now;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- responses: one per request; DMA blocks; FIFO reads; ram_idle with ch3_req
  ------------------------------------------------------------------------------
  mon : process
  begin
    wait until rising_edge(clk_base);
    if ch1_ready = '1' then n_ch1_rdy <= n_ch1_rdy + 1; end if;
    if ch2_ready = '1' then n_ch2_rdy <= n_ch2_rdy + 1; end if;
    if ch3_ready = '1' then n_ch3_rdy <= n_ch3_rdy + 1; end if;
    if dma_rp = '1' then n_dma_rp <= n_dma_rp + 1; end if;
    assert ch3_req = '0' or ram_idle = '0' report "ram_idle with ch3_req" severity failure;
    wait for 1 ns;
    assert n_ch1_rdy <= n_cpu_rd + n_ch1_wr report "ch1_ready without a request" severity failure;
    assert n_ch2_rdy <= n_ch2_wr + n_ch2_rd report "ch2_ready without a request" severity failure;
    assert n_ch3_rdy <= n_ch3 report "ch3_ready without a request" severity failure;
    assert n_dma_rp <= n_dma report "dma_reqprocessed without a DMA request" severity failure;
  end process;

  fifo_mon : process
  begin
    wait until rising_edge(clk);
    assert fifo_full = '0' report "DMA FIFO full" severity failure;
    if dmafifo_read = '1' then
      assert dmafifo_empty = '0' report "dmafifo_read on an empty FIFO" severity failure;
      n_fifo_rd <= n_fifo_rd + 1;
    end if;
  end process;

  dma_mon : process
    variable dq_r, left, blocks : natural := 0;
    variable t_first, t_prev : time := 0 ns;
  begin
    wait until rising_edge(clk_base);
    if dma_wr = '1' then
      assert dq_r < dq_w report "dma_wr without a DMA block" severity failure;
      assert dma_data = dq_word(dq_r)
        report "dma_data " & to_hstring(dma_data) & " expected " & to_hstring(dq_word(dq_r)) severity failure;
      if unsigned(dq_len(dq_r)) /= 0 then
        assert left = 0 report "DMA block starts inside the previous one" severity failure;
        left := to_integer(unsigned(dq_len(dq_r))) - 1;
        if blocks = 0 then
          t_first := now;
        else
          assert now - t_prev >= 12 * T3 report "DMA blocks closer than 4 clk_base cycles" severity failure;
          assert now - t_first >= (13 * blocks - 2) * T3
            report "DMA blocks faster than the original (13 clk per block)" severity failure;
        end if;
        t_prev := now;
        blocks := blocks + 1;
      else
        assert left > 0 report "dma_wr after the end of the block" severity failure;
        left := left - 1;
      end if;
      dq_r := dq_r + 1;
      n_dma_words <= n_dma_words + 1;
    else
      assert left = 0 report "gap inside a DMA block" severity failure;
    end if;
    dq_r_s <= dq_r;
  end process;

  ------------------------------------------------------------------------------
  -- DMA agent (dma.vhd read handling)
  ------------------------------------------------------------------------------
  dma_agent : process
    variable s1, s2 : positive := 31;
    variable r : real;
    variable a, cnt, off : natural;
    variable t : natural;
  begin
    wait until dma_go;
    dma_mode <= '1';
    wait until rising_edge(clk_base);
    for j in 0 to dma_n_jobs - 1 loop
      uniform(s1, s2, r);
      if dma_cnt_fix < 4 then
        cnt := dma_cnt_fix;
      else
        cnt := integer(floor(r * 4.0));
      end if;
      uniform(s1, s2, r);
      if r * 100.0 < real(dma_wrap_pct) then
        uniform(s1, s2, r);
        off := ((integer(floor(r * real(dma_size))) / 1024) * 1024) + 1012 + 4 * integer(floor(r * 3.0));
      else
        uniform(s1, s2, r);
        off := 4 * integer(floor(r * real(dma_size / 4)));
      end if;
      a := dma_base + off mod dma_size;
      for i in 0 to cnt loop
        dq_word(dq_w + i) := ref_word(a, i);
        dq_len(dq_w + i) := (others => '0');
      end loop;
      dq_len(dq_w) := std_logic_vector(to_unsigned(cnt + 1, 32));
      dq_w := dq_w + cnt + 1;
      dma_addr <= a27(a);
      dma_cnt  <= std_logic_vector(to_unsigned(cnt, 2));
      dma_req  <= '1';
      n_dma    <= n_dma + 1;
      wait until rising_edge(clk_base);
      dma_req  <= '0';
      t := 0;
      while dma_rp /= '1' loop
        wait until rising_edge(clk_base);
        t := t + 1;
        assert t < 2000 report "no dma_reqprocessed" severity failure;
      end loop;
    end loop;
    -- all words out
    t := 0;
    while dq_r_s < dq_w loop
      wait until rising_edge(clk_base);
      t := t + 1;
      assert t < 5000 report "DMA words missing" severity failure;
    end loop;
    wait until rising_edge(clk_base);
    dma_mode <= '0';
    dma_fin <= true;
    wait until not dma_go;
    dma_fin <= false;
  end process;

  ------------------------------------------------------------------------------
  -- ch3 agent: download (PSX.sv ramdownload), cheats (cheats.vhd), reads
  ------------------------------------------------------------------------------
  ch3_agent : process
    variable s1, s2 : positive := 77;
    variable r : real;
    variable a, t : natural;
    variable d : slv32;
    variable be : std_logic_vector(3 downto 0);
    procedure op(addr : natural; rnw : std_logic; din : slv32; ben : std_logic_vector(3 downto 0)) is
      variable exp : slv32;
    begin
      if rnw = '0' then
        ref_write32(addr, din, ben);
      else
        exp := ref_read32(addr);
      end if;
      ch3_addr <= a27(addr); ch3_rnw <= rnw; ch3_din <= din; ch3_be <= ben;
      ch3_req <= '1';
      n_ch3 <= n_ch3 + 1;
      wait until rising_edge(clk_base);
      ch3_req <= '0';
      t := 0;
      while ch3_ready /= '1' loop
        wait until rising_edge(clk_base);
        t := t + 1;
        assert t < 2000 report "no ch3_ready" severity failure;
      end loop;
      if rnw = '1' then
        assert ch3_dout = exp
          report "ch3 read " & to_hstring(to_unsigned(addr, 28)) & ": " & to_hstring(ch3_dout) & " expected " &
                 to_hstring(exp) severity failure;
      end if;
      wait until rising_edge(clk_base);
    end procedure;
    function rbe(x : real) return std_logic_vector is
    begin
      return std_logic_vector(to_unsigned(1 + integer(floor(x * 15.0)), 4));
    end function;
  begin
    ch3_req <= '0'; ch3_rnw <= '1'; ch3_be <= "1111"; ch3_din <= (others => '0');
    loop
      wait until c3_go;
      wait until rising_edge(clk_base);
      for j in 0 to c3_n - 1 loop
        uniform(s1, s2, r);
        d := std_logic_vector(to_unsigned(integer(floor(r * 65536.0)), 16)) & std_logic_vector(to_unsigned(j * 7919 mod 65536, 16));
        case c3_mode is
          when 0 =>
            op(c3_base + 4 * j, '0', d, "1111");
            uniform(s1, s2, r);
            for i in 1 to integer(floor(r * 3.0)) loop     -- ioctl pace
              wait until rising_edge(clk_base);
            end loop;
          when 1 =>
            uniform(s1, s2, r);
            a := c3_base + 4 * integer(floor(r * real(c3_size / 4)));
            uniform(s1, s2, r);
            if r < 0.2 then a := a + 2; end if;
            uniform(s1, s2, r);
            op(a, '1', x"00000000", rbe(r));
            uniform(s1, s2, r);
            be := rbe(r);
            op(a, '0', d, be);
          when others =>
            uniform(s1, s2, r);
            op(c3_base + 4 * integer(floor(r * real(c3_size / 4))), '1', x"00000000", "1111");
        end case;
      end loop;
      c3_fin <= true;
      wait until not c3_go;
      c3_fin <= false;
    end loop;
  end process;

  ------------------------------------------------------------------------------
  -- DMA writes through the FIFO (dma.vhd fifoOut_Wr, once per clk_base cycle)
  ------------------------------------------------------------------------------
  fifo_agent : process
    variable s1, s2 : positive := 1234;
    variable r : real;
    variable a : natural;
    variable d : slv32;
  begin
    loop
      wait until ff_go;
      wait until rising_edge(clk_base);
      for j in 0 to ff_n - 1 loop
        uniform(s1, s2, r);
        a := ff_base + 4 * integer(floor(r * real(ff_size / 4)));
        uniform(s1, s2, r);
        d := std_logic_vector(to_unsigned(integer(floor(r * 65536.0)), 16)) & std_logic_vector(to_unsigned(j, 16));
        ref_write32(a, d, "1111");
        fifo_din <= std_logic_vector(to_unsigned(a / 4, 21)) & d;
        fifo_wr <= '1';
        n_fifo_wr <= n_fifo_wr + 1;
        ff_last <= a;
        wait until rising_edge(clk_base);
        fifo_wr <= '0';
        uniform(s1, s2, r);
        if r > 0.5 and not ff_dense then
          for i in 1 to integer(floor(r * 4.0)) - 1 loop
            wait until rising_edge(clk_base);
          end loop;
        end if;
      end loop;
      ff_fin <= true;
      wait until not ff_go;
      ff_fin <= false;
    end loop;
  end process;

  ------------------------------------------------------------------------------
  -- main: phases and the CPU agent (memorymux)
  ------------------------------------------------------------------------------
  main : process
    variable s1, s2 : positive := 4242;
    variable r : real;
    variable lat_min, lat_max, lat_sum, lat_n : natural := 0;
    variable a, k : natural;
    variable d : slv32;
    variable t_dma0 : time;

    procedure tick is
    begin
      wait until rising_edge(clk_base);
    end procedure;

    -- wait for ready (sampled at clk_base edges); returns the cycles since the request
    procedure wait_ready(signal rdy : std_logic; check_idle : boolean; cyc : out natural) is
      variable n : natural := 1;
    begin
      while rdy /= '1' loop
        if check_idle and n >= 2 then
          assert ram_idle = '0' report "ram_idle while a read waits" severity failure;
        end if;
        tick;
        n := n + 1;
        assert n < 3000 report "no ready" severity failure;
      end loop;
      cyc := n;
    end procedure;

    procedure stat(n : natural) is
    begin
      if lat_n = 0 or n < lat_min then lat_min := n; end if;
      if n > lat_max then lat_max := n; end if;
      lat_sum := lat_sum + n;
      lat_n := lat_n + 1;
    end procedure;

    procedure cpu_read(addr : natural; cache : boolean) is
      variable first, n, cyc : natural;
      variable ew : cline_t;
      variable t0, r0 : time;
      variable line : natural;
    begin
      first := (addr / 4) mod 4;
      line := (addr / 16) mod 256;
      n := 1;
      if cache then
        n := 4 - first;
      end if;
      for i in 0 to n - 1 loop
        ew(i) := ref_word(addr, i);
      end loop;
      if cache then
        cx_line := line; cx_first := first; cx_words := ew; cx_done := "0000"; cx_active := true;
      end if;
      t0 := now;
      cpu_addr <= a27(addr); cpu_rnw <= '1';
      if cache then cpu_cache <= '1'; else cpu_cache <= '0'; end if;
      cpu_req <= '1';
      n_cpu_rd <= n_cpu_rd + 1;
      tick;
      cpu_req <= '0';
      wait_ready(ch1_ready, true, cyc);
      stat(cyc);
      assert ch1_dout32 = ew(0)
        report "ch1 read " & to_hstring(to_unsigned(addr, 28)) & ": " & to_hstring(ch1_dout32) & " expected " &
               to_hstring(ew(0)) severity failure;
      if cache then
        -- ch1_ready rose at r0 (one clk_base cycle ago); word k of the line must be in the cache
        -- RAM at a clk edge before r0 + k clk_base cycles (the original: word k at D + 2k clk,
        -- ch1_ready rises 1..3 clk after D)
        r0 := now - 3 * T3;
        tick;
        tick;
        for i in 0 to n - 1 loop
          assert cram(line)(first + i) = ew(i) and ctime(line, first + i) > t0 and
                 ctime(line, first + i) < r0 + i * 3 * T3
            report "cache word " & integer'image(first + i) & " not written " & integer'image(i) &
                   " clk_base cycles after ch1_ready rose" severity failure;
        end loop;
        for i in 0 to 3 loop
          assert (cx_done(i) = '1') = (i >= first) report "cache words written: " & to_string(cx_done)
            severity failure;
        end loop;
        cx_active := false;
      end if;
      -- the next request at this edge (memorymux: ram_ena one cycle after ram_done)
    end procedure;

    procedure cpu_write(addr : natural; din : slv32; be : std_logic_vector(3 downto 0)) is
      variable cyc : natural;
    begin
      ref_write32(addr, din, be);
      w_addr <= a27(addr); w_din <= din; w_be <= be; w_rnw <= '0';
      w_req <= '1';
      n_ch2_wr <= n_ch2_wr + 1;
      tick;
      w_req <= '0';
      wait_ready(ch2_ready, false, cyc);
    end procedure;

    procedure cpu_random(n : natural; base, size : natural) is
      variable be : std_logic_vector(3 downto 0);
    begin
      for j in 0 to n - 1 loop
        uniform(s1, s2, r);
        a := base + 4 * integer(floor(r * real(size / 4)));
        uniform(s1, s2, r);
        d := std_logic_vector(to_unsigned(integer(floor(r * 65536.0)), 16)) &
             std_logic_vector(to_unsigned((j * 40503) mod 65536, 16));
        uniform(s1, s2, r);
        be := std_logic_vector(to_unsigned(1 + integer(floor(r * 15.0)), 4));
        uniform(s1, s2, r);
        if r < 0.35 then
          uniform(s1, s2, r);
          if r < 0.1 then a := a + 2; end if;
          cpu_write(a, d, be);
        elsif r < 0.65 then
          uniform(s1, s2, r);
          if r < 0.1 then a := a + 2; end if;
          cpu_read(a, false);
        elsif r < 0.9 then
          cpu_read(a, true);
        else
          cpu_write(a, d, be);
          cpu_read(a, false);                        -- right behind the write
        end if;
      end loop;
    end procedure;

    procedure run_dma(n, base, size, wrap_pct, cnt_fix : natural) is
    begin
      dma_n_jobs <= n; dma_base <= base; dma_size <= size; dma_wrap_pct <= wrap_pct; dma_cnt_fix <= cnt_fix;
      dma_go <= true;
      wait until dma_fin;
      dma_go <= false;
      tick;
    end procedure;

    procedure run_c3(mode, n, base, size : natural) is
    begin
      c3_mode <= mode; c3_n <= n; c3_base <= base; c3_size <= size;
      c3_go <= true;
      wait until c3_fin;
      c3_go <= false;
      tick;
    end procedure;

    procedure report_lat(name : string) is
    begin
      report name & ": ch1 read request -> ch1_ready min " & integer'image(lat_min) & " max " &
             integer'image(lat_max) & " mean " & integer'image(lat_sum / lat_n) & " clk_base cycles (" &
             integer'image(lat_n) & " reads)";
      lat_n := 0; lat_min := 0; lat_max := 0; lat_sum := 0;
    end procedure;

  begin
    -- phase 0: requests during init are held, no Avalon command
    for i in 1 to 4 loop tick; end loop;
    c3_mode <= 0; c3_n <= 1; c3_base <= A_BASE + 16#7F00#; c3_size <= 4;
    c3_go <= true;
    cpu_addr <= a27(A_BASE + 16#10#); cpu_cache <= '0'; cpu_rnw <= '1';
    cpu_req <= '1';
    n_cpu_rd <= n_cpu_rd + 1;
    tick;
    cpu_req <= '0';
    for i in 1 to 40 loop
      assert ch1_ready = '0' and ch3_ready = '0' report "ready while init" severity failure;
      tick;
    end loop;
    init <= '0';
    k := 0;
    while ch1_ready /= '1' loop
      tick; k := k + 1;
      assert k < 1000 report "held ch1 read not served" severity failure;
    end loop;
    assert ch1_dout32 = ref_read32(A_BASE + 16#10#) report "held ch1 read data" severity failure;
    if not c3_fin then wait until c3_fin; end if;
    c3_go <= false;
    tick;
    report "phase 0 (init) done";

    -- phase 1: download into both windows, read some back
    run_c3(0, 512, A_BASE, 2048);
    run_c3(0, 64, B_BASE + 16#400#, 256);
    run_c3(2, 64, A_BASE, 2048);
    run_c3(2, 32, B_BASE + 16#400#, 256);
    report "phase 1 (download) done";

    -- phase 2: random CPU operations
    cpu_random(600, A_BASE, 16#4000#);
    for i in 1 to 10 loop tick; end loop;
    assert ram_idle = '1' report "ram_idle low with nothing to do" severity failure;
    report_lat("phase 2 (CPU, random memory)");

    -- phase 3: DMA blocks, a fifth wraps in the 1 KB row
    run_dma(300, A_BASE + 16#4000#, 16#4000#, 20, 4);
    report "phase 3 (DMA reads) done";

    -- phase 4: DMA writes through the FIFO, then CPU reads of them
    ff_n <= 300; ff_base <= A_BASE + 16#4000#; ff_size <= 16#2000#;
    ff_go <= true;
    wait until ff_fin;
    ff_go <= false;
    tick;
    for j in 0 to 39 loop
      uniform(s1, s2, r);
      cpu_read(A_BASE + 16#4000# + 4 * integer(floor(r * 2048.0)), false);
    end loop;
    -- a CPU read one clk_base cycle after the last FIFO word (priority of the FIFO); slow memory,
    -- words back to back, so that the FIFO still holds words when the read comes
    avl_wait_pct <= 70;
    ff_dense <= true;
    for j in 0 to 39 loop
      ff_n <= 1 + j mod 8;
      ff_go <= true;
      wait until ff_fin;
      ff_go <= false;
      cpu_read(ff_last, false);
    end loop;
    ff_dense <= false;
    avl_wait_pct <= 30;
    report "phase 4 (DMA writes) done";

    -- phase 5: CPU || cheats, DMA || cheats
    c3_mode <= 1; c3_n <= 100; c3_base <= A_BASE + 16#6000#; c3_size <= 16#2000#;
    c3_go <= true;
    cpu_random(200, A_BASE, 16#4000#);
    if not c3_fin then wait until c3_fin; end if;
    c3_go <= false;
    tick;
    c3_mode <= 1; c3_n <= 60; c3_base <= A_BASE + 16#6000#; c3_size <= 16#2000#;
    c3_go <= true;
    run_dma(100, A_BASE + 16#4000#, 16#2000#, 20, 4);
    if not c3_fin then wait until c3_fin; end if;
    c3_go <= false;
    tick;
    report_lat("phases 4-5 (CPU, random memory)");

    -- phase 6: fast memory: read latency and DMA block rate
    avl_wait_pct <= 0; avl_lat_max <= 1;
    for i in 1 to 20 loop tick; end loop;
    for j in 0 to 19 loop
      cpu_read(A_BASE + 64 * j, false);
    end loop;
    report_lat("phase 6 (CPU, memory latency 1)");
    for j in 0 to 9 loop
      cpu_read(A_BASE + 64 * j + 4 * (j mod 4), true);
    end loop;
    report_lat("phase 6 (CPU cache line, memory latency 1)");
    t_dma0 := now;
    run_dma(60, A_BASE + 16#4000#, 16#4000#, 0, 3);
    report "phase 6: 60 DMA blocks of 4 words in " & integer'image((now - t_dma0) / (3 * T3)) &
           " clk_base cycles (original: 13 clk = 4.33 clk_base per block)";
    avl_wait_pct <= 30; avl_lat_max <= 30;

    -- phase 7: ports PSX.sv does not use (ch1 write 16 bit, ch2 read)
    for j in 0 to 19 loop
      uniform(s1, s2, r);
      a := A_BASE + 2 * integer(floor(r * 4096.0));
      d := std_logic_vector(to_unsigned(j * 2654435 mod 65536, 16)) & std_logic_vector(to_unsigned(j * 977, 16));
      ref(bidx(a)) := d(7 downto 0);
      ref(bidx(a + 1)) := d(15 downto 8);
      cpu_addr <= a27(a); cpu_rnw <= '0'; cpu_din16 <= d(15 downto 0); cpu_cache <= '0';
      cpu_req <= '1';
      n_ch1_wr <= n_ch1_wr + 1;
      tick;
      cpu_req <= '0';
      wait_ready(ch1_ready, false, k);
      tick;
      cpu_rnw <= '1';
      w_addr <= a27(a - a mod 4); w_rnw <= '1'; w_req <= '1';
      n_ch2_rd <= n_ch2_rd + 1;
      tick;
      w_req <= '0';
      wait_ready(ch2_ready, false, k);
      assert ch2_dout = ref_read32(a - a mod 4) report "ch2 read" severity failure;
      tick;
      w_rnw <= '0';
    end loop;
    report "phase 7 (ch1 write, ch2 read) done";

    -- end: counts and memory
    for i in 1 to 50 loop tick; end loop;
    assert n_ch1_rdy = n_cpu_rd + n_ch1_wr report "ch1_ready count " & integer'image(n_ch1_rdy) severity failure;
    assert n_ch2_rdy = n_ch2_wr + n_ch2_rd report "ch2_ready count" severity failure;
    assert n_ch3_rdy = n_ch3 report "ch3_ready count" severity failure;
    assert n_dma_rp = n_dma report "dma_reqprocessed count" severity failure;
    assert n_dma_words = dq_w report "dma words" severity failure;
    assert n_fifo_rd = n_fifo_wr report "FIFO words written " & integer'image(n_fifo_rd) & " of " &
                                        integer'image(n_fifo_wr) severity failure;
    for i in 0 to NB - 1 loop
      assert amem(i / 8)(8 * (i mod 8) + 7 downto 8 * (i mod 8)) = ref(i)
        report "memory byte " & integer'image(i) & " differs from the reference" severity failure;
    end loop;
    report "requests: CPU reads " & integer'image(n_cpu_rd) & ", ch2 writes " & integer'image(n_ch2_wr) &
           ", ch3 " & integer'image(n_ch3) & ", DMA blocks " & integer'image(n_dma) & " (" &
           integer'image(dq_w) & " words), FIFO words " & integer'image(n_fifo_wr);
    report "PASS";
    done <= true;
    wait;
  end process;

end architecture tb;
