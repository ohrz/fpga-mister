-------------------------------------------------------------------------------
-- Title      : System testbench of the SDRAM replacement (stage C)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : sdram_stagec_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   The random SDRAM controller of sdram_emu_tb runs as the "core" on a gated
--   clock (BUFGCE model: a pulse of the master clock or none, decided by ce of
--   core_clock_stall).  Behind its pins the whole stage C chain:
--     sdram_emu -> sdram_region -> b0 sdram_bram (bank 3, pinned)
--                               -> b1 sdram_cache -> avl_axi_bridge -> AXI3 DDR model
--   with a read latency of 20 cycles, and the pacer at 21/22.  The core counts
--   its own edges and must see an ideal SDRAM: every read beat at edge CL + 1,
--   counted in core edges, whatever the stalls.  The core reads the DQ bus as
--   mister_zynq builds it (dq_o where dq_oe = 1, else Z), so the beat must
--   still be driven at the sample edge after master cycles without a core
--   edge (pacer, stalls).  Also checked: no error flag
--   (emulator, region, cache, AXI), the derived clock (every 4th core edge,
--   always in the same phase, never without a master pulse) and the real time
--   (never more core edges than earned).  Ends with "PASS" or a failure.
--   VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity sdram_stagec_tb is
  generic (
    G_CYCLES : natural := 100000;      -- core cycles
    G_SEED   : positive := 13
  );
end entity;

architecture tb of sdram_stagec_tb is

  constant BANK_BITS : natural := 2;
  constant ROW_BITS  : natural := 4;
  constant COL_BITS  : natural := 5;
  constant ADDR_BITS : natural := BANK_BITS + ROW_BITS + COL_BITS;
  constant B0_BITS   : natural := ROW_BITS + COL_BITS;                    -- bank 3 in BRAM
  constant B0_MASK   : natural := 3 * 2 ** B0_BITS;
  constant NUM       : positive := 21;
  constant DEN       : positive := 22;
  constant DIV       : positive := 4;

  signal clk   : std_logic := '0';                   -- free running master clock
  signal gclk  : std_logic := '0';                   -- gated core clock (clk_mem)
  signal gdiv  : std_logic := '0';                   -- derived core clock (clk_sys)
  signal rst   : std_logic := '1';
  signal done  : boolean := false;

  signal cs_n, ras_n, cas_n, we_n : std_logic := '1';
  signal ba    : std_logic_vector(BANK_BITS - 1 downto 0) := (others => '0');
  signal a     : std_logic_vector(12 downto 0) := (others => '0');
  signal dqm   : std_logic_vector(1 downto 0) := "00";
  signal dq_i  : std_logic_vector(15 downto 0) := (others => '0');
  signal dq_o  : std_logic_vector(15 downto 0);
  signal dq_oe : std_logic;
  signal dq_bus : std_logic_vector(15 downto 0);    -- SDRAM_DQ as the core sees it (mister_zynq)

  signal ce, ce_div, stall : std_logic;
  signal err_late, err_mode, err_cache, err_region, axi_error : std_logic;

  signal be_req, be_we, be_ready, be_rvalid : std_logic;
  signal be_addr  : std_logic_vector(ADDR_BITS - 1 downto 0);
  signal be_wdata, be_rdata : std_logic_vector(15 downto 0);
  signal be_wstrb : std_logic_vector(1 downto 0);

  signal b0_req, b0_we, b0_ready, b0_rvalid : std_logic;
  signal b0_addr  : std_logic_vector(B0_BITS - 1 downto 0);
  signal b0_wdata, b0_rdata : std_logic_vector(15 downto 0);
  signal b0_wstrb : std_logic_vector(1 downto 0);
  signal b1_req, b1_we, b1_ready, b1_rvalid : std_logic;
  signal b1_addr  : std_logic_vector(ADDR_BITS - 1 downto 0);
  signal b1_wdata, b1_rdata : std_logic_vector(15 downto 0);
  signal b1_wstrb : std_logic_vector(1 downto 0);
  signal ev_hit, ev_miss : std_logic;

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

  signal master_cycles, stalls, misses, b0_reads, paced : natural := 0;

begin

  ------------------------------------------------------------------------------
  -- clocks: master clock and the BUFGCE outputs change in the same delta cycle
  -- (ce is sampled just before the rising edge, where it has settled)
  ------------------------------------------------------------------------------
  clocks : process
    variable en, en_div : std_logic := '0';
  begin
    while not done loop
      wait for 5 ns;
      en := ce; en_div := ce_div;
      clk <= '1'; gclk <= en; gdiv <= en_div;
      wait for 5 ns;
      clk <= '0'; gclk <= '0'; gdiv <= '0';
    end loop;
    wait;
  end process;

  reset : process
  begin
    rst <= '1';
    for i in 1 to 4 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait;
  end process;

  ------------------------------------------------------------------------------
  -- stage C chain
  ------------------------------------------------------------------------------
  pacer : entity work.core_clock_stall
    generic map (G_NUM => NUM, G_DEN => DEN, G_BUCKET => 64, G_DIV1 => DIV, G_DIV2 => 0)
    port map (clk => clk, rst => rst, stall => stall, ce => ce, ce_div1 => ce_div, ce_div2 => open, lag => open);

  emu : entity work.sdram_emu
    generic map (G_BANK_BITS => BANK_BITS, G_ROW_BITS => ROW_BITS, G_COL_BITS => COL_BITS, G_RD_ADJ => 0)
    port map (
      clk => clk, rst => rst, ce => ce,
      sd_cs_n => cs_n, sd_ras_n => ras_n, sd_cas_n => cas_n, sd_we_n => we_n, sd_ba => ba, sd_a => a,
      sd_dqm => dqm, sd_dq_i => dq_i, sd_dq_o => dq_o, sd_dq_oe => dq_oe,
      be_req => be_req, be_we => be_we, be_addr => be_addr, be_wdata => be_wdata, be_wstrb => be_wstrb,
      be_ready => be_ready, be_rvalid => be_rvalid, be_rdata => be_rdata,
      stall => stall, err_late => err_late, err_mode => err_mode);

  dq_bus <= dq_o when dq_oe = '1' else (others => 'Z');

  region : entity work.sdram_region
    generic map (G_ADDR_BITS => ADDR_BITS, G_B0_MASK => B0_MASK, G_B0_MATCH => B0_MASK,
                 G_B0_SEL => 2 ** B0_BITS - 1, G_B0_BITS => B0_BITS)
    port map (
      clk => clk, rst => rst,
      req => be_req, we => be_we, addr => be_addr, wdata => be_wdata, wstrb => be_wstrb,
      ready => be_ready, rvalid => be_rvalid, rdata => be_rdata,
      b0_req => b0_req, b0_we => b0_we, b0_addr => b0_addr, b0_wdata => b0_wdata, b0_wstrb => b0_wstrb,
      b0_ready => b0_ready, b0_rvalid => b0_rvalid, b0_rdata => b0_rdata,
      b1_req => b1_req, b1_we => b1_we, b1_addr => b1_addr, b1_wdata => b1_wdata, b1_wstrb => b1_wstrb,
      b1_ready => b1_ready, b1_rvalid => b1_rvalid, b1_rdata => b1_rdata,
      err => err_region);

  bram : entity work.sdram_bram
    generic map (G_ADDR_BITS => B0_BITS)
    port map (clk => clk, req => b0_req, we => b0_we, addr => b0_addr, wdata => b0_wdata, wstrb => b0_wstrb,
              ready => b0_ready, rvalid => b0_rvalid, rdata => b0_rdata);

  cache : entity work.sdram_cache
    generic map (G_ADDR_BITS => ADDR_BITS, G_LINE_LOG2 => 2, G_INDEX_BITS => 4, G_WFIFO_LOG2 => 3,
                 G_AVL_ADDR_W => 29)
    port map (
      clk => clk, rst => rst,
      req => b1_req, we => b1_we, addr => b1_addr, wdata => b1_wdata, wstrb => b1_wstrb,
      ready => b1_ready, rvalid => b1_rvalid, rdata => b1_rdata,
      avl_waitrequest => avl_waitrequest, avl_burstcount => avl_burstcount, avl_address => avl_address,
      avl_read => avl_read, avl_readdata => avl_readdata, avl_readdatavalid => avl_readdatavalid,
      avl_write => avl_write, avl_writedata => avl_writedata, avl_byteenable => avl_byteenable,
      ev_hit => ev_hit, ev_miss => ev_miss, err => err_cache);

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
  -- statistics on the master clock
  ------------------------------------------------------------------------------
  stats : process
    variable mc, st, mi, b0r, pa : natural := 0;
  begin
    wait until rising_edge(clk);
    if rst = '0' then
      mc := mc + 1;
      if ce = '0' then st := st + 1; end if;
      if ce = '0' and stall = '0' then pa := pa + 1; end if;          -- held by the pacer
      if ev_miss = '1' then mi := mi + 1; end if;
      if b0_req = '1' and b0_we = '0' then b0r := b0r + 1; end if;
      master_cycles <= mc; stalls <= st; misses <= mi; b0_reads <= b0r; paced <= pa;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- derived clock: every DIV-th core edge, always the same phase
  ------------------------------------------------------------------------------
  derived : process
    variable edges : natural := 0;
    variable phase : integer := -1;
  begin
    wait until rising_edge(gclk);
    if gdiv = '1' then
      if phase < 0 then phase := edges mod DIV; end if;
      assert edges mod DIV = phase report "derived clock out of phase" severity failure;
    end if;
    edges := edges + 1;
  end process;

  derived_pulse : process
  begin
    wait until rising_edge(gdiv);
    assert gclk = '1' report "derived clock pulse without a core clock pulse" severity failure;
  end process;

  ------------------------------------------------------------------------------
  -- the core: random SDRAM controller on the gated clock (as in sdram_emu_tb)
  ------------------------------------------------------------------------------
  core : process
    type ref_t is array (0 to 2 ** ADDR_BITS - 1) of std_logic_vector(15 downto 0);
    variable ref : ref_t := (others => (others => '0'));
    type exp_t is array (0 to 63) of std_logic_vector(15 downto 0);
    variable exp_d : exp_t;
    variable exp_v : std_logic_vector(0 to 63) := (others => '0');
    type rows_t is array (0 to 2 ** BANK_BITS - 1) of natural;
    variable row_of : rows_t := (others => 0);
    variable row_ok : std_logic_vector(0 to 2 ** BANK_BITS - 1) := (others => '0');

    -- mode register as the model sees it
    variable bl : natural := 1;                     -- G_MODE_INIT of the DUT: BL 1, CL 2
    variable cl : natural := 2;
    variable interleave, single_wr : boolean := false;
    -- burst of the model
    variable b_on, b_we : boolean := false;
    variable b_bank, b_row, b_col, b_cnt, b_len : natural := 0;

    variable s1, s2 : positive := G_SEED;
    variable r : real;
    variable n, checked, writes, mrs_cnt : natural := 0;
    variable kind : natural;
    variable bank, col, addr, cbeat : natural;
    variable new_rw, rw_we, term : boolean;
    variable d : std_logic_vector(15 downto 0);
    variable m : std_logic_vector(1 downto 0);
    variable quiet : natural := 0;                  -- cycles without a read in flight

    impure function rnd(k : natural) return natural is
    begin
      uniform(s1, s2, r);
      return natural(floor(r * real(k)));
    end function;

    -- working set: every 5000 cycles either the whole memory (cache misses) or
    -- bank 0 rows 0..7 (fits the cache, read only) and bank 3 (BRAM), where the
    -- pacer limits
    variable hot : boolean := false;

    impure function pick_bank return natural is
    begin
      if hot then return 3 * rnd(2); else return rnd(2 ** BANK_BITS); end if;
    end function;

    impure function pick_row return natural is
    begin
      if hot then return rnd(8); else return rnd(2 ** ROW_BITS); end if;
    end function;

    procedure cmd(c : std_logic_vector(3 downto 0)) is
    begin
      cs_n <= c(3); ras_n <= c(2); cas_n <= c(1); we_n <= c(0);
    end procedure;

    -- column of beat i, written independently of the DUT's function
    function burst_col(start, i, len : natural; il : boolean) return natural is
      variable base : natural := start - (start mod len);
    begin
      if il then
        return base + to_integer(to_unsigned(start mod len, 3) xor to_unsigned(i, 3));
      else
        return base + ((start + i) mod len);
      end if;
    end function;

  begin
    wait until rst = '0';

    while n < G_CYCLES loop
      wait until rising_edge(gclk);
      n := n + 1;
      if n mod 5000 = 0 then
        hot := rnd(2) = 0;
        row_ok := (others => '0');                  -- rows are opened again from the new working set
      end if;
      -- this edge ends cycle n - 1: the core samples a due read beat
      if exp_v((n - 1) mod 64) = '1' then
        assert dq_bus = exp_d((n - 1) mod 64)
          report "cycle " & integer'image(n - 1) & ": read " & to_hstring(dq_bus) & " expected " &
                 to_hstring(exp_d((n - 1) mod 64)) severity failure;
        exp_v((n - 1) mod 64) := '0';
        checked := checked + 1;
      end if;
      -- the command of cycle n
      cmd("0111"); ba <= (others => '0'); a <= (others => '0'); dqm <= "00"; dq_i <= (others => 'X');
      new_rw := false; term := false;
      kind := rnd(100);
      if kind < 40 then
        null;                                                   -- NOP
      elsif kind < 70 then
        bank := pick_bank;
        if row_ok(bank) = '0' then
          row_of(bank) := pick_row; row_ok(bank) := '1';
          cmd("0011"); ba <= std_logic_vector(to_unsigned(bank, BANK_BITS));
          a <= std_logic_vector(to_unsigned(row_of(bank), 13));
        else
          col := rnd(2 ** COL_BITS);
          rw_we := rnd(2) = 0 and not (hot and bank = 0);       -- hot: bank 0 read only (no DDR traffic)
          if rw_we then cmd("0100"); else cmd("0101"); end if;
          ba <= std_logic_vector(to_unsigned(bank, BANK_BITS));
          a  <= std_logic_vector(to_unsigned(col, 13)) or "0010000000000";   -- A10 (auto precharge) is ignored
          new_rw := true;
          b_on := true; b_we := rw_we; b_bank := bank; b_row := row_of(bank); b_col := col; b_cnt := 0;
          if rw_we and single_wr then b_len := 1; else b_len := bl; end if;
        end if;
      elsif kind < 80 then
        bank := pick_bank;                                      -- ACTIVE (a new row, open burst keeps its row)
        row_of(bank) := pick_row; row_ok(bank) := '1';
        cmd("0011"); ba <= std_logic_vector(to_unsigned(bank, BANK_BITS));
        a <= std_logic_vector(to_unsigned(row_of(bank), 13));
      elsif kind < 84 then
        cmd("0010"); term := true;                               -- PRECHARGE (all banks, A10)
        a <= "0010000000000"; row_ok := (others => '0');
      elsif kind < 87 then
        cmd("0110"); term := true;                               -- BURST TERMINATE
      elsif kind < 90 then
        cmd("0001");                                             -- REFRESH
      elsif kind < 93 and quiet >= 8 and not b_on then
        -- MODE REGISTER SET, only with nothing in flight (as the SDRAM requires)
        case rnd(4) is when 0 => bl := 1; when 1 => bl := 2; when 2 => bl := 4; when others => bl := 8; end case;
        cl := 2 + rnd(2);
        interleave := rnd(2) = 0;
        single_wr := rnd(3) = 0;
        a <= "000" & std_logic_vector(to_unsigned(boolean'pos(single_wr), 1)) & "00" &
             std_logic_vector(to_unsigned(cl, 3)) & std_logic_vector(to_unsigned(boolean'pos(interleave), 1)) &
             std_logic_vector(to_unsigned(natural(log2(real(bl))), 3));
        cmd("0000");
        mrs_cnt := mrs_cnt + 1;
      end if;

      -- the beat of cycle n (a new READ/WRITE was set up above with b_cnt = 0)
      if term then b_on := false; end if;
      if b_on and b_cnt < b_len then
        cbeat := burst_col(b_col, b_cnt, b_len, interleave);
        if b_len = 1 then cbeat := b_col; end if;
        addr := (b_bank * 2 ** ROW_BITS + b_row) * 2 ** COL_BITS + cbeat;
        if b_we then
          d := std_logic_vector(to_unsigned(rnd(65536), 16));
          m := std_logic_vector(to_unsigned(rnd(4), 2));
          if rnd(2) = 0 then m := "00"; end if;
          dq_i <= d; dqm <= m;
          if m(0) = '0' then ref(addr)(7 downto 0) := d(7 downto 0); end if;
          if m(1) = '0' then ref(addr)(15 downto 8) := d(15 downto 8); end if;
          writes := writes + 1;
        else
          exp_d((n + cl) mod 64) := ref(addr);
          exp_v((n + cl) mod 64) := '1';
          quiet := 0;
        end if;
        b_cnt := b_cnt + 1;
        if b_cnt = b_len then b_on := false; end if;
      end if;
      if exp_v = (exp_v'range => '0') then quiet := quiet + 1; end if;
    end loop;

    for i in 1 to 10 loop wait until rising_edge(gclk); end loop;
    assert err_late = '0' and err_mode = '0' and err_cache = '0' and err_region = '0' and axi_error = '0'
      report "error flag set" severity failure;
    assert master_cycles > 0 and n <= 1 + (master_cycles * NUM) / DEN
      report "the core ran faster than nominal" severity failure;
    assert misses > G_CYCLES / 200 and b0_reads > G_CYCLES / 100 and paced > G_CYCLES / 100
      report "stimulus too weak: " & integer'image(misses) & " misses, " & integer'image(b0_reads) &
             " BRAM region reads, " & integer'image(paced) & " paced" severity failure;
    report "PASS: " & integer'image(n) & " core cycles in " & integer'image(master_cycles) &
           " master cycles (" & integer'image(stalls) & " withheld, " & integer'image(paced) & " by the pacer), " &
           integer'image(checked) &
           " read beats checked, " & integer'image(writes) & " write beats, " & integer'image(mrs_cnt) &
           " mode changes, " & integer'image(misses) & " cache misses, " & integer'image(b0_reads) &
           " BRAM region reads";
    done <= true;
    wait;
  end process;

  timeout : process
  begin
    wait for 100 ms;
    assert done report "timeout" severity failure;
    wait;
  end process;

end architecture tb;
