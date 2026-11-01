-------------------------------------------------------------------------------
-- Title      : Testbench of avl_axi_bridge
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : avl_axi_bridge_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Random Avalon bursts (1..255 beats, byte enables, pipelined reads) against
--   an AXI3 memory model (axi3_mem_model) with random ready/valid gaps.
--   Checks: read data against a reference memory, AXI3 rules (at most 16 beats,
--   no burst across 4 KB, WLAST on the last beat, 8-byte INCR), no AXI error.
--   Quiescing: hold is set for random periods during the traffic; while idle = 1
--   no AXI transaction may be open or start (AR/AW/W valid, read beats or write
--   responses outstanding, counted on the AXI side), idle never without hold,
--   once set it stays until hold drops, and it must follow every hold within
--   C_IDLE_MAX cycles.
--   avl_axi_bridge_err_tb (G_ERR_PER > 0): about one in G_ERR_PER read beats
--   and write responses (avl_axi_bridge_werr_tb: write responses only, so a
--   read error cannot hide a missed write error) comes back as SLVERR or DECERR (stable while valid, as
--   AXI demands; HP2/HP3).  The traffic must run on unchanged
--   (data, ordering, quiescing), axi_error must be 0 before the first error
--   response is presented, 1 from the cycle after the first transferred one,
--   stay set (sticky) and clear with rst.
--   Withdrawn writes (G_WITHDRAW): about one write command in eight drops
--   avl_write after 0..5 cycles of waitrequest before its first beat was
--   accepted (a core reset or a DDRAM multiplexer switch).  The
--   memory must stay unchanged (reads checked against the reference), the
--   AXI side must stay legal (beats per AW, WLAST) and the traffic must go on;
--   withdrawals before, while and after an AW are counted and all must occur.
--   Ends with "PASS" or a failure.
--   VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity avl_axi_bridge_tb is
  generic (
    G_OPS  : natural := 3000;      -- Avalon commands
    G_SEED : positive := 7;
    G_ERR_PER : natural := 0;      -- 0: OKAY only; n: about one error response in n
    G_ERR_CH  : natural := 0;      -- errors on 0: R and B, 1: R only, 2: B only
    G_WITHDRAW : boolean := true   -- the master withdraws some write commands before acceptance
  );
end entity;

architecture tb of avl_axi_bridge_tb is

  constant C_WORDS : natural := 16384;              -- 128 KB memory model
  type mem_t is array (0 to C_WORDS - 1) of std_logic_vector(63 downto 0);

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal done : boolean := false;

  signal avl_waitrequest   : std_logic;
  signal avl_burstcount    : std_logic_vector(7 downto 0) := (others => '0');
  signal avl_address       : std_logic_vector(28 downto 0) := (others => '0');
  signal avl_read          : std_logic := '0';
  signal avl_readdata      : std_logic_vector(63 downto 0);
  signal avl_readdatavalid : std_logic;
  signal avl_write         : std_logic := '0';
  signal avl_writedata     : std_logic_vector(63 downto 0) := (others => '0');
  signal avl_byteenable    : std_logic_vector(7 downto 0) := (others => '0');

  signal awaddr, araddr : std_logic_vector(31 downto 0);
  signal awlen, arlen   : std_logic_vector(3 downto 0);
  signal awsize, arsize : std_logic_vector(2 downto 0);
  signal awburst, arburst : std_logic_vector(1 downto 0);
  signal awvalid, awready, arvalid, arready : std_logic;
  signal wdata  : std_logic_vector(63 downto 0);
  signal wstrb  : std_logic_vector(7 downto 0);
  signal wlast, wvalid, wready : std_logic;
  signal bvalid, bready : std_logic;
  signal rdata  : std_logic_vector(63 downto 0);
  signal rlast, rvalid, rready : std_logic;
  signal axi_error : std_logic;
  signal bresp, rresp : std_logic_vector(1 downto 0) := "00";
  signal errs_seen : natural := 0;                  -- error responses transferred
  signal hold, idle : std_logic := '0';
  signal holds_seen : natural := 0;
  constant C_IDLE_MAX : natural := 2000;            -- a 255-beat command with ready gaps

  -- expected read data (filled by the Avalon master at command time, checked on readdatavalid)
  type exp_t is array (0 to 65535) of std_logic_vector(63 downto 0);
  shared variable exp_q : exp_t;
  signal exp_wr : natural := 0;                     -- written by the master process only
  signal reads_seen : natural := 0;
  signal aw_count   : natural := 0;                 -- AW handshakes (open_mon)

begin

  clk <= not clk after 5 ns when not done;

  dut : entity work.avl_axi_bridge
    port map (
      clk => clk, rst => rst, hold => hold, idle => idle,
      avl_waitrequest => avl_waitrequest, avl_burstcount => avl_burstcount,
      avl_address => avl_address, avl_read => avl_read, avl_readdata => avl_readdata,
      avl_readdatavalid => avl_readdatavalid, avl_write => avl_write,
      avl_writedata => avl_writedata, avl_byteenable => avl_byteenable,
      m_axi_awid => open, m_axi_awaddr => awaddr, m_axi_awlen => awlen, m_axi_awsize => awsize,
      m_axi_awburst => awburst, m_axi_awlock => open, m_axi_awcache => open, m_axi_awprot => open,
      m_axi_awqos => open, m_axi_awvalid => awvalid, m_axi_awready => awready,
      m_axi_wid => open, m_axi_wdata => wdata, m_axi_wstrb => wstrb, m_axi_wlast => wlast,
      m_axi_wvalid => wvalid, m_axi_wready => wready,
      m_axi_bid => (others => '0'), m_axi_bresp => bresp, m_axi_bvalid => bvalid, m_axi_bready => bready,
      m_axi_arid => open, m_axi_araddr => araddr, m_axi_arlen => arlen, m_axi_arsize => arsize,
      m_axi_arburst => arburst, m_axi_arlock => open, m_axi_arcache => open, m_axi_arprot => open,
      m_axi_arqos => open, m_axi_arvalid => arvalid, m_axi_arready => arready,
      m_axi_rid => (others => '0'), m_axi_rdata => rdata, m_axi_rresp => rresp, m_axi_rlast => rlast,
      m_axi_rvalid => rvalid, m_axi_rready => rready,
      axi_error => axi_error
    );

  ------------------------------------------------------------------------------
  -- AXI3 memory model
  ------------------------------------------------------------------------------
  axi_mem : entity work.axi3_mem_model
    generic map (G_WORD_BITS => 14, G_RD_LAT => 0, G_SEED => G_SEED + 100)
    port map (
      clk => clk,
      awaddr => awaddr, awlen => awlen, awsize => awsize, awburst => awburst, awvalid => awvalid, awready => awready,
      wdata => wdata, wstrb => wstrb, wlast => wlast, wvalid => wvalid, wready => wready,
      bvalid => bvalid, bready => bready,
      araddr => araddr, arlen => arlen, arsize => arsize, arburst => arburst, arvalid => arvalid, arready => arready,
      rdata => rdata, rlast => rlast, rvalid => rvalid, rready => rready);

  ------------------------------------------------------------------------------
  -- Avalon master with a reference memory
  ------------------------------------------------------------------------------
  master : process
    variable ref : mem_t := (others => (others => '0'));
    variable s1, s2 : positive := G_SEED;
    variable r : real;
    variable addr, cnt, n_exp : natural;
    variable be : std_logic_vector(7 downto 0);
    variable d  : std_logic_vector(63 downto 0);
    variable wd, gone : boolean;
    variable wd_wait, aw0 : natural;
    variable n_wd_pre, n_wd_awv, n_wd_aw : natural := 0;  -- withdrawals before / while / after an AW

    impure function rnd(n : natural) return natural is     -- 0 .. n-1
    begin
      uniform(s1, s2, r);
      return natural(floor(r * real(n)));
    end function;
    impure function rnd64 return std_logic_vector is
      variable v : std_logic_vector(63 downto 0);
    begin
      for i in 0 to 3 loop v(16 * i + 15 downto 16 * i) := std_logic_vector(to_unsigned(rnd(65536), 16)); end loop;
      return v;
    end function;
  begin
    rst <= '1';
    for i in 1 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    n_exp := 0;
    for op in 1 to G_OPS loop
      -- mostly short bursts, some long ones (ascal), some near the 4 KB boundary
      case rnd(4) is
        when 0      => cnt := 1 + rnd(255);
        when others => cnt := 1 + rnd(16);
      end case;
      if rnd(4) = 0 then
        addr := (1 + rnd(C_WORDS / 512 - 2)) * 512 - rnd(20);
      else
        addr := rnd(C_WORDS - cnt);
      end if;
      if addr + cnt > C_WORDS then addr := C_WORDS - cnt; end if;

      if rnd(2) = 0 then
        -- write burst: every beat held until accepted
        avl_address    <= std_logic_vector(to_unsigned(addr, 29));
        avl_burstcount <= std_logic_vector(to_unsigned(cnt, 8));
        wd := false;
        wd_wait := 0;
        if G_WITHDRAW then
          wd := rnd(8) = 0;
          wd_wait := rnd(6);
        end if;
        aw0 := aw_count;
        gone := false;
        for i in 0 to cnt - 1 loop
          be := std_logic_vector(to_unsigned(rnd(256), 8));
          if rnd(2) = 0 then be := x"FF"; end if;
          d := rnd64;
          avl_write <= '1'; avl_writedata <= d; avl_byteenable <= be;
          loop
            wait until rising_edge(clk);
            exit when avl_waitrequest = '0';
            -- withdraw the first beat while it is not accepted
            if wd and i = 0 then
              if wd_wait = 0 then gone := true; exit; end if;
              wd_wait := wd_wait - 1;
            end if;
          end loop;
          if gone then
            -- values before this edge: awvalid and awready both 1 = the AW is accepted at it
            if aw_count /= aw0 or (awvalid = '1' and awready = '1') then
              n_wd_aw := n_wd_aw + 1;                 -- AW accepted, its W beats are owed
            elsif awvalid = '1' then
              n_wd_awv := n_wd_awv + 1;               -- AW presented, cannot be taken back
            else
              n_wd_pre := n_wd_pre + 1;
            end if;
            avl_write <= '0';                         -- visible for at least one edge
            wait until rising_edge(clk);
            exit;                                     -- the reference stays unchanged
          end if;
          for b in 0 to 7 loop
            if be(b) = '1' then ref(addr + i)(8 * b + 7 downto 8 * b) := d(8 * b + 7 downto 8 * b); end if;
          end loop;
          -- an idle cycle between beats now and then
          if rnd(8) = 0 then avl_write <= '0'; wait until rising_edge(clk); end if;
        end loop;
        avl_write <= '0';
      else
        -- read burst: expected data is the reference now
        for i in 0 to cnt - 1 loop
          exp_q((n_exp + i) mod 65536) := ref(addr + i);
        end loop;
        n_exp := n_exp + cnt;
        avl_address    <= std_logic_vector(to_unsigned(addr, 29));
        avl_burstcount <= std_logic_vector(to_unsigned(cnt, 8));
        avl_read <= '1';
        loop
          wait until rising_edge(clk);
          exit when avl_waitrequest = '0';
        end loop;
        -- Avalon: read data only after the command was accepted (a master such as PSX memcard.vhd
        -- starts counting its beats with the acceptance); the checker sees the new count from the
        -- next edge on
        exp_wr <= n_exp;
        avl_read <= '0';
      end if;
      if rnd(4) = 0 then wait until rising_edge(clk); end if;
    end loop;
    -- all read data back
    while reads_seen < n_exp loop wait until rising_edge(clk); end loop;
    for i in 1 to 50 loop wait until rising_edge(clk); end loop;
    if G_ERR_PER = 0 then
      assert axi_error = '0' report "axi_error set" severity failure;
    else
      assert errs_seen >= 10 report "only " & integer'image(errs_seen) & " error responses" severity failure;
      assert axi_error = '1' report "axi_error not set after error responses" severity failure;
      rst <= '1';
      wait until rising_edge(clk);
      rst <= '0';
      wait until rising_edge(clk);
      assert axi_error = '0' report "axi_error not cleared by rst" severity failure;
    end if;
    if G_WITHDRAW then
      assert n_wd_pre >= 5 and n_wd_awv >= 5 and n_wd_aw >= 5 report "withdrawals: " &
        integer'image(n_wd_pre) & " before, " & integer'image(n_wd_awv) & " while, " &
        integer'image(n_wd_aw) & " after AW" severity failure;
    end if;
    assert holds_seen >= 10 report "only " & integer'image(holds_seen) & " hold periods" severity failure;
    report "PASS: " & integer'image(G_OPS) & " Avalon commands, " & integer'image(n_exp) &
      " read beats checked, " & integer'image(holds_seen) & " hold periods, " &
      integer'image(errs_seen) & " error responses, " & integer'image(n_wd_pre) & "/" &
      integer'image(n_wd_awv) & "/" & integer'image(n_wd_aw) & " writes withdrawn before/while/after AW";
    done <= true;
    wait;
  end process;

  checker : process
    variable n : natural := 0;
  begin
    wait until rising_edge(clk);
    if avl_readdatavalid = '1' then
      assert n < exp_wr report "read data before its read command was accepted" severity failure;
      assert avl_readdata = exp_q(n mod 65536)
        report "read beat " & integer'image(n) & ": got " & to_hstring(avl_readdata) &
               " expected " & to_hstring(exp_q(n mod 65536)) severity failure;
      n := n + 1;
      reads_seen <= n;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- quiescing: random hold periods, open AXI transactions counted on the AXI side
  ------------------------------------------------------------------------------
  holder : process
    variable s1, s2 : positive := G_SEED + 17;
    variable r : real;
    variable n : natural;
  begin
    hold <= '0';
    wait until rst = '0';
    while not done loop
      uniform(s1, s2, r);
      for i in 0 to natural(floor(r * 3000.0)) loop
        wait until rising_edge(clk);
        exit when done;
      end loop;
      exit when done;
      hold <= '1';
      n := 0;
      loop
        wait until rising_edge(clk);
        exit when idle = '1';
        n := n + 1;
        assert n < C_IDLE_MAX report "no idle " & integer'image(C_IDLE_MAX) & " cycles after hold"
          severity failure;
      end loop;
      uniform(s1, s2, r);
      for i in 0 to natural(floor(r * 200.0)) loop wait until rising_edge(clk); end loop;
      holds_seen <= holds_seen + 1;
      hold <= '0';
    end loop;
    wait;
  end process;

  open_mon : process
    variable rd_open : integer := 0;                 -- read beats requested on AR, not yet on R
    variable wr_open : integer := 0;                 -- AW accepted without a B response
    variable idle_d  : std_logic := '0';
  begin
    wait until rising_edge(clk);
    assert not (idle_d = '1' and hold = '1' and idle = '0') report "idle dropped while hold is set"
      severity failure;
    idle_d := idle;
    if idle = '1' then
      assert hold = '1' report "idle without hold" severity failure;
      assert rd_open = 0 and wr_open = 0 report "idle with open AXI transactions: " &
        integer'image(rd_open) & " read beats, " & integer'image(wr_open) & " writes" severity failure;
      assert arvalid = '0' and awvalid = '0' and wvalid = '0' report "AXI request while idle" severity failure;
    end if;
    if arvalid = '1' and arready = '1' then rd_open := rd_open + to_integer(unsigned(arlen)) + 1; end if;
    if rvalid = '1' and rready = '1' then rd_open := rd_open - 1; end if;
    if awvalid = '1' and awready = '1' then wr_open := wr_open + 1; aw_count <= aw_count + 1; end if;
    if bvalid = '1' and bready = '1' then wr_open := wr_open - 1; end if;
  end process;

  ------------------------------------------------------------------------------
  -- error responses (G_ERR_PER > 0): a new random resp only after the handshake, so it
  -- stays stable while valid; the sticky flag is checked against what was presented
  ------------------------------------------------------------------------------
  resp_gen : process
    variable s1, s2 : positive := G_SEED + 31;
    variable r : real;
    variable presented, transferred : boolean := false;
    variable n : natural := 0;

    impure function pick return std_logic_vector is
    begin
      uniform(s1, s2, r);
      if G_ERR_PER = 0 or r * real(G_ERR_PER) >= 1.0 then return "00"; end if;
      uniform(s1, s2, r);
      if r < 0.5 then return "10"; else return "11"; end if;   -- SLVERR, DECERR
    end function;
  begin
    wait until rising_edge(clk);
    if rst = '1' then
      presented := false; transferred := false;
    else
      if transferred then
        assert axi_error = '1' report "axi_error not set (or not sticky) after an error response" severity failure;
      elsif not presented then
        assert axi_error = '0' report "axi_error without an error response" severity failure;
      end if;
      if (rvalid = '1' and rresp /= "00") or (bvalid = '1' and bresp /= "00") then presented := true; end if;
      if (rvalid = '1' and rready = '1' and rresp /= "00") or (bvalid = '1' and bready = '1' and bresp /= "00") then
        transferred := true;
        if rvalid = '1' and rready = '1' and rresp /= "00" then n := n + 1; end if;
        if bvalid = '1' and bready = '1' and bresp /= "00" then n := n + 1; end if;
        errs_seen <= n;
      end if;
    end if;
    if (rvalid = '0' or rready = '1') and G_ERR_CH /= 2 then rresp <= pick; end if;
    if (bvalid = '0' or bready = '1') and G_ERR_CH /= 1 then bresp <= pick; end if;
  end process;

  timeout : process
  begin
    wait for 20 ms;
    assert done report "timeout" severity failure;
    wait;
  end process;

end architecture tb;

entity avl_axi_bridge_err_tb is
end entity;

architecture tb of avl_axi_bridge_err_tb is
begin
  err : entity work.avl_axi_bridge_tb generic map (G_ERR_PER => 40);
end architecture tb;

entity avl_axi_bridge_werr_tb is
end entity;

architecture tb of avl_axi_bridge_werr_tb is
begin
  err : entity work.avl_axi_bridge_tb generic map (G_ERR_PER => 40, G_ERR_CH => 2);
end architecture tb;
