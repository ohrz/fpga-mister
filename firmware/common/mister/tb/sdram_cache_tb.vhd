-------------------------------------------------------------------------------
-- Title      : Testbench of sdram_cache with avl_axi_bridge and the AXI3 model
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : sdram_cache_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   A random back end user (like sdram_emu) sends word reads and writes with
--   byte enables: hot lines (hits), random addresses (misses, conflict
--   evictions), short sequential runs, reads right after a write to the same
--   word, idle gaps.  A request is held until accepted.  Read data must come
--   back in request order and match a reference memory; the DDR side is the
--   real avl_axi_bridge and axi3_mem_model with a minimum read latency.
--   Miss classes: a model of the tags (current and replaced line per index,
--   line of the previous miss) predicts ev_miss_hi/_vict/_vict_x/_seq at
--   every line fetch on the Avalon side; ev_rd_hi must come with every read
--   in the upper half.  sdram_cache_split_tb: the same with G_SPLIT = 1 (no
--   miss on a line replaced from the other half).
--   Ends with "PASS" (enough hits, misses and miss classes seen) or a failure.
--   VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity sdram_cache_tb is
  generic (
    G_OPS   : natural := 60000;
    G_SEED  : positive := 23;
    G_SPLIT : natural := 0
  );
end entity;

architecture tb of sdram_cache_tb is

  constant ADDR_BITS  : natural := 14;              -- 16 K words = 32 KB
  constant LINE_LOG2  : natural := 2;
  constant INDEX_BITS : natural := 4;               -- 16 lines of 16 words

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal done : boolean := false;

  signal req, we, ready, rvalid : std_logic := '0';
  signal addr  : std_logic_vector(ADDR_BITS - 1 downto 0) := (others => '0');
  signal wdata, rdata : std_logic_vector(15 downto 0) := (others => '0');
  signal wstrb : std_logic_vector(1 downto 0) := "00";
  signal ev_hit, ev_miss, err : std_logic;
  signal ev_miss_hi, ev_miss_vict, ev_miss_vict_x, ev_miss_seq, ev_rd_hi : std_logic;

  signal avl_waitrequest, avl_read, avl_readdatavalid, avl_write : std_logic;
  signal avl_burstcount : std_logic_vector(7 downto 0);
  signal avl_address    : std_logic_vector(28 downto 0);
  signal avl_readdata, avl_writedata : std_logic_vector(63 downto 0);
  signal avl_byteenable : std_logic_vector(7 downto 0);

  signal awaddr, araddr : std_logic_vector(31 downto 0);
  signal awlen, arlen   : std_logic_vector(3 downto 0);
  signal awsize, arsize : std_logic_vector(2 downto 0);
  signal awburst, arburst : std_logic_vector(1 downto 0);
  signal awvalid, awready, arvalid, arready : std_logic;
  signal wdata_x : std_logic_vector(63 downto 0);
  signal wstrb_x : std_logic_vector(7 downto 0);
  signal wlast, wvalid, wready, bvalid, bready : std_logic;
  signal rdata_x : std_logic_vector(63 downto 0);
  signal rlast, rvalid_x, rready : std_logic;
  signal axi_error : std_logic;

  type exp_t is array (0 to 1023) of std_logic_vector(15 downto 0);
  shared variable exp_q : exp_t;
  type exp_hi_t is array (0 to 1023) of std_logic;
  shared variable exp_hi : exp_hi_t;                -- top address bit of the read
  signal exp_wr     : natural := 0;
  signal reads_seen : natural := 0;
  signal hits, misses : natural := 0;
  type class_cnt_t is array (0 to 3) of natural;    -- hi, vict, vict_x, seq
  signal classes : class_cnt_t := (others => 0);

begin

  clk <= not clk after 5 ns when not done;

  dut : entity work.sdram_cache
    generic map (G_ADDR_BITS => ADDR_BITS, G_LINE_LOG2 => LINE_LOG2, G_INDEX_BITS => INDEX_BITS,
                 G_SPLIT => G_SPLIT, G_WFIFO_LOG2 => 3, G_AVL_ADDR_W => 29)
    port map (
      clk => clk, rst => rst,
      req => req, we => we, addr => addr, wdata => wdata, wstrb => wstrb,
      ready => ready, rvalid => rvalid, rdata => rdata,
      avl_waitrequest => avl_waitrequest, avl_burstcount => avl_burstcount, avl_address => avl_address,
      avl_read => avl_read, avl_readdata => avl_readdata, avl_readdatavalid => avl_readdatavalid,
      avl_write => avl_write, avl_writedata => avl_writedata, avl_byteenable => avl_byteenable,
      ev_hit => ev_hit, ev_miss => ev_miss, ev_miss_hi => ev_miss_hi, ev_miss_vict => ev_miss_vict,
      ev_miss_vict_x => ev_miss_vict_x, ev_miss_seq => ev_miss_seq, ev_rd_hi => ev_rd_hi, err => err);

  bridge : entity work.avl_axi_bridge
    port map (
      clk => clk, rst => rst,
      avl_waitrequest => avl_waitrequest, avl_burstcount => avl_burstcount,
      avl_address => avl_address, avl_read => avl_read, avl_readdata => avl_readdata,
      avl_readdatavalid => avl_readdatavalid, avl_write => avl_write,
      avl_writedata => avl_writedata, avl_byteenable => avl_byteenable,
      m_axi_awid => open, m_axi_awaddr => awaddr, m_axi_awlen => awlen, m_axi_awsize => awsize,
      m_axi_awburst => awburst, m_axi_awlock => open, m_axi_awcache => open, m_axi_awprot => open,
      m_axi_awqos => open, m_axi_awvalid => awvalid, m_axi_awready => awready,
      m_axi_wid => open, m_axi_wdata => wdata_x, m_axi_wstrb => wstrb_x, m_axi_wlast => wlast,
      m_axi_wvalid => wvalid, m_axi_wready => wready,
      m_axi_bid => (others => '0'), m_axi_bresp => "00", m_axi_bvalid => bvalid, m_axi_bready => bready,
      m_axi_arid => open, m_axi_araddr => araddr, m_axi_arlen => arlen, m_axi_arsize => arsize,
      m_axi_arburst => arburst, m_axi_arlock => open, m_axi_arcache => open, m_axi_arprot => open,
      m_axi_arqos => open, m_axi_arvalid => arvalid, m_axi_arready => arready,
      m_axi_rid => (others => '0'), m_axi_rdata => rdata_x, m_axi_rresp => "00", m_axi_rlast => rlast,
      m_axi_rvalid => rvalid_x, m_axi_rready => rready,
      axi_error => axi_error);

  ddr : entity work.axi3_mem_model
    generic map (G_WORD_BITS => ADDR_BITS - 2, G_RD_LAT => 20, G_SEED => G_SEED + 100)
    port map (
      clk => clk,
      awaddr => awaddr, awlen => awlen, awsize => awsize, awburst => awburst, awvalid => awvalid, awready => awready,
      wdata => wdata_x, wstrb => wstrb_x, wlast => wlast, wvalid => wvalid, wready => wready,
      bvalid => bvalid, bready => bready,
      araddr => araddr, arlen => arlen, arsize => arsize, arburst => arburst, arvalid => arvalid, arready => arready,
      rdata => rdata_x, rlast => rlast, rvalid => rvalid_x, rready => rready);

  ------------------------------------------------------------------------------
  -- back end user with a reference memory
  ------------------------------------------------------------------------------
  user : process
    type ref_t is array (0 to 2 ** ADDR_BITS - 1) of std_logic_vector(15 downto 0);
    variable ref : ref_t := (others => (others => '0'));
    type hot_t is array (0 to 3) of natural;
    variable hot : hot_t;
    variable s1, s2 : positive := G_SEED;
    variable r : real;
    variable a, last_wr, run : natural := 0;
    variable is_wr : boolean;
    variable d : std_logic_vector(15 downto 0);
    variable m : std_logic_vector(1 downto 0);
    variable n_exp, n_wr : natural := 0;
    variable rd_after_wr : boolean := false;

    impure function rnd(k : natural) return natural is
    begin
      uniform(s1, s2, r);
      return natural(floor(r * real(k)));
    end function;
  begin
    for i in hot'range loop hot(i) := rnd(2 ** ADDR_BITS); end loop;
    rst <= '1';
    for i in 1 to 4 loop wait until rising_edge(clk); end loop;
    rst <= '0';

    for op in 1 to G_OPS loop
      -- address: prelude, run on, read after write, hot line, or anywhere.  Prelude: per index a
      -- line with tag 1, then one with tag 0 (second fetch, the victim entry is still invalid
      -- and its tag bits are 0)
      if op <= 2 ** (INDEX_BITS + 1) then
        a := (((op - 1) / 2) + (op mod 2) * 2 ** INDEX_BITS) * 2 ** (LINE_LOG2 + 2);
      elsif run > 0 then
        a := (a + 1) mod 2 ** ADDR_BITS; run := run - 1;
      elsif rd_after_wr then
        a := last_wr;
      else
        case rnd(10) is
          when 0 to 5 => a := (hot(rnd(4)) / 16) * 16 + rnd(16);      -- a word of a hot line
          when 6      => a := rnd(2 ** ADDR_BITS); run := rnd(8);      -- sequential run
          when 7      => hot(rnd(4)) := rnd(2 ** ADDR_BITS); a := hot(0);
          when others => a := rnd(2 ** ADDR_BITS);
        end case;
      end if;
      is_wr := rnd(10) < 4 and not rd_after_wr and op > 2 ** (INDEX_BITS + 1);
      rd_after_wr := false;

      req  <= '1';
      addr <= std_logic_vector(to_unsigned(a, ADDR_BITS));
      if is_wr then
        d := std_logic_vector(to_unsigned(rnd(65536), 16));
        m := "11";
        if rnd(4) = 0 then m := std_logic_vector(to_unsigned(rnd(4), 2)); end if;
        we <= '1'; wdata <= d; wstrb <= m;
      else
        we <= '0'; wdata <= (others => 'X'); wstrb <= "XX";
      end if;
      loop
        wait until rising_edge(clk);
        exit when ready = '1';
      end loop;
      -- accepted on this edge
      if is_wr then
        if m(0) = '1' then ref(a)(7 downto 0) := d(7 downto 0); end if;
        if m(1) = '1' then ref(a)(15 downto 8) := d(15 downto 8); end if;
        n_wr := n_wr + 1;
        last_wr := a;
        rd_after_wr := rnd(4) = 0;
      else
        exp_q(n_exp mod 1024) := ref(a);
        exp_hi(n_exp mod 1024) := to_unsigned(a, ADDR_BITS)(ADDR_BITS - 1);
        n_exp := n_exp + 1;
        exp_wr <= n_exp;
      end if;
      req <= '0'; we <= '0'; addr <= (others => 'X');
      if rnd(4) = 0 then
        for i in 1 to rnd(4) loop wait until rising_edge(clk); end loop;
      end if;
    end loop;

    while reads_seen < n_exp loop wait until rising_edge(clk); end loop;
    for i in 1 to 20 loop wait until rising_edge(clk); end loop;
    assert err = '0' and axi_error = '0' report "error flag set" severity failure;
    -- every read ends with an ev_hit (a miss after its line fetch): first-try hits = hits - misses
    assert hits - misses > G_OPS / 10 and misses > G_OPS / 50
      report "too few hits (" & integer'image(hits - misses) & ") or misses (" & integer'image(misses) & ")"
      severity failure;
    assert classes(0) > misses / 4 and classes(1) > misses / 50 and
           (classes(2) > misses / 200 or G_SPLIT /= 0) and classes(3) > misses / 200
      report "too few miss classes: hi " & integer'image(classes(0)) & ", vict " & integer'image(classes(1)) &
             ", vict_x " & integer'image(classes(2)) & ", seq " & integer'image(classes(3)) severity failure;
    report "PASS: " & integer'image(G_OPS) & " requests, " & integer'image(n_exp) & " reads checked, " &
           integer'image(n_wr) & " writes, " & integer'image(hits - misses) & " read hits, " & integer'image(misses) &
           " read misses (hi " & integer'image(classes(0)) & ", vict " & integer'image(classes(1)) & ", vict_x " &
           integer'image(classes(2)) & ", seq " & integer'image(classes(3)) & ")";
    done <= true;
    wait;
  end process;

  checker : process
    variable n, h, mi : natural := 0;
  begin
    wait until rising_edge(clk);
    if rvalid = '1' then
      assert n < exp_wr report "read data without an outstanding read" severity failure;
      assert rdata = exp_q(n mod 1024)
        report "read " & integer'image(n) & ": got " & to_hstring(rdata) & " expected " &
               to_hstring(exp_q(n mod 1024)) severity failure;
      assert ev_rd_hi = exp_hi(n mod 1024) report "ev_rd_hi wrong at read " & integer'image(n) severity failure;
      n := n + 1;
      reads_seen <= n;
    end if;
    assert ev_rd_hi = '0' or ev_hit = '1' report "ev_rd_hi without ev_hit" severity failure;
    if ev_hit = '1' then h := h + 1; hits <= h; end if;
    if ev_miss = '1' then mi := mi + 1; misses <= mi; end if;
  end process;

  -- miss classes: the DUT flags of a miss against a tag model, compared at its line fetch
  classes_check : process
    constant LINE_BITS : natural := ADDR_BITS - 2 - LINE_LOG2;
    constant TAG_BITS  : natural := LINE_BITS - INDEX_BITS;
    type tag_t is array (0 to 2 ** INDEX_BITS - 1) of integer;     -- -1: invalid
    variable cur, prev : tag_t := (others => -1);
    variable last      : integer := -1;
    variable got       : std_logic_vector(3 downto 0);                  -- seq, vict_x, vict, hi
    variable pending   : boolean := false;
    variable line, idx, tag : natural;
    variable e         : std_logic_vector(3 downto 0);
    variable cnt       : class_cnt_t := (others => 0);
  begin
    wait until rising_edge(clk) and rst = '0';
    assert ev_miss = '1' or (ev_miss_hi = '0' and ev_miss_vict = '0' and ev_miss_seq = '0')
      report "miss class without ev_miss" severity failure;
    assert ev_miss_vict = '1' or ev_miss_vict_x = '0' report "ev_miss_vict_x without ev_miss_vict" severity failure;
    if ev_miss = '1' then
      assert not pending report "second miss before the line fetch" severity failure;
      got := ev_miss_seq & ev_miss_vict_x & ev_miss_vict & ev_miss_hi;
      pending := true;
    end if;
    if avl_read = '1' and avl_waitrequest = '0' then
      assert pending report "line fetch without a miss" severity failure;
      pending := false;
      line := to_integer(unsigned(avl_address(ADDR_BITS - 3 downto LINE_LOG2)));
      if G_SPLIT = 0 then
        idx := line mod 2 ** INDEX_BITS;
        tag := line / 2 ** INDEX_BITS;
      else                                                          -- top line bit = top index bit
        idx := (line / 2 ** (LINE_BITS - 1)) * 2 ** (INDEX_BITS - 1) + line mod 2 ** (INDEX_BITS - 1);
        tag := (line mod 2 ** (LINE_BITS - 1)) / 2 ** (INDEX_BITS - 1);
      end if;
      e    := "0000";
      if line >= 2 ** (LINE_BITS - 1) then e(0) := '1'; end if;
      if prev(idx) = tag then
        e(1) := '1';
        if G_SPLIT = 0 and cur(idx) >= 0 and (cur(idx) >= 2 ** (TAG_BITS - 1)) /= (tag >= 2 ** (TAG_BITS - 1)) then
          e(2) := '1';
        end if;
      end if;
      if last >= 0 and line = (last + 1) mod 2 ** LINE_BITS then e(3) := '1'; end if;
      assert got = e report "miss classes of line " & integer'image(line) & ": got " & to_string(got) &
                            " expected " & to_string(e) & " (seq vict_x vict hi)" severity failure;
      for i in 0 to 3 loop
        if e(i) = '1' then cnt(i) := cnt(i) + 1; end if;
      end loop;
      classes <= cnt;
      prev(idx) := cur(idx);
      cur(idx)  := tag;
      last      := line;
    end if;
  end process;

  -- Avalon master rule: a command held by waitrequest stays unchanged until accepted
  avl_rules : process
    variable p_rd, p_wr : std_logic := '0';
    variable p_addr : std_logic_vector(28 downto 0);
    variable p_cnt  : std_logic_vector(7 downto 0);
    variable p_data : std_logic_vector(63 downto 0);
    variable p_be   : std_logic_vector(7 downto 0);
  begin
    wait until rising_edge(clk);
    if rst = '0' and (p_rd = '1' or p_wr = '1') then
      assert avl_read = p_rd and avl_write = p_wr and avl_address = p_addr and avl_burstcount = p_cnt
        report "Avalon command changed while waitrequest was high" severity failure;
      assert p_wr = '0' or (avl_writedata = p_data and avl_byteenable = p_be)
        report "Avalon write data changed while waitrequest was high" severity failure;
    end if;
    assert not (avl_read = '1' and avl_write = '1') report "Avalon read and write at once" severity failure;
    p_rd := '0'; p_wr := '0';
    if avl_waitrequest = '1' then
      p_rd := avl_read; p_wr := avl_write;
      p_addr := avl_address; p_cnt := avl_burstcount; p_data := avl_writedata; p_be := avl_byteenable;
    end if;
  end process;

  timeout : process
  begin
    wait for 100 ms;
    assert done report "timeout" severity failure;
    wait;
  end process;

end architecture tb;

library ieee;
use ieee.std_logic_1164.all;

entity sdram_cache_split_tb is
end entity;

architecture tb of sdram_cache_split_tb is
begin
  split : entity work.sdram_cache_tb generic map (G_SPLIT => 1);
end architecture tb;
