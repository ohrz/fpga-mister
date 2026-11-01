-------------------------------------------------------------------------------
-- Title      : Testbench of the N64 SDRAM controller replacement
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : n64_sdram_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   cores/n64/sdram.vhd against a reference of the original rtl/sdram.sv: a
--   memory of 16-bit words, a 32-bit access at byte address a is word W =
--   a / 2 and W xor 1 when read (burst of 2, sequential: an odd W wraps) and
--   two single writes to W (din(15:0), be(1:0)) and W or 1 (din(31:16),
--   be(3:2)); ch3 in the 8-bit mode (FF & din(15:8) & FF & din(7:0), read the
--   low bytes).  Behind the replacement an Avalon slave model (random
--   waitrequest, random read latency 1..30, data in order), its words in a
--   window of 8 KB at byte address 0x4ABC000 (chip bit 26 set): every Avalon
--   address must lie in it.  Channel drivers as in N64.sv: ch1 like
--   SDRamMux (burst reads: the next request on ch1_reqprocessed while the
--   words still to come are >= 2, counted down on ch1_ready; a burst must
--   issue exactly its length; writes one at a time), ch2 like the ROM download (writes, request held
--   until ready).  Phases:
--     1. a ch1 write while init is set: no Avalon access, no ready; once
--        init is '0' it is served (one ready, the word reads back);
--     2. ch2 writes 64 words, ch1 reads them as one burst;
--     3. 400 random ch1 writes (random byte enables, 16-bit aligned
--        addresses, so odd W too) and burst reads of 1..8 words;
--     4. 60 random ch3 writes and reads;
--     5. ch1 burst reads of region A while ch2 writes region B, then ch1
--        reads region B;
--   and over all: ch1_reqprocessed only for ch1 reads, every channel's ready
--   only for its own requests, at most one read in flight.
--   Ends with "PASS" or a failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity n64_sdram_tb is
end entity;

architecture tb of n64_sdram_tb is

  constant T_CLK  : time := 10 ns;
  constant BASE   : natural := 16#4ABC000#;              -- byte address of the window
  constant WORDS  : natural := 4096;                     -- 16-bit words in the window (8 KB)

  signal clk  : std_logic := '0';
  signal init : std_logic := '1';
  signal done : boolean := false;

  signal ch1_addr, ch2_addr, ch3_addr : std_logic_vector(26 downto 0) := (others => '0');
  signal ch1_dout, ch2_dout, ch1_din, ch2_din : std_logic_vector(31 downto 0) := (others => '0');
  signal ch3_dout, ch3_din : std_logic_vector(15 downto 0) := (others => '0');
  signal ch1_req, ch2_req, ch3_req : std_logic := '0';
  signal ch1_rnw, ch2_rnw, ch3_rnw : std_logic := '1';
  signal ch1_be : std_logic_vector(3 downto 0) := "1111";
  signal ch1_ready, ch1_reqprocessed, ch2_ready, ch3_ready : std_logic;

  signal mem_clk, mem_waitrequest, mem_readdatavalid, mem_read, mem_write : std_logic;
  signal mem_address : std_logic_vector(28 downto 0);
  signal mem_burstcount, mem_byteenable : std_logic_vector(7 downto 0);
  signal mem_readdata, mem_writedata : std_logic_vector(63 downto 0);
  signal sd_dq : std_logic_vector(15 downto 0);
  signal sd_ncs : std_logic;

  -- what the channels have asked for (to check ready and reqprocessed)
  signal ch1_rd_n, ch1_wr_n, ch2_n, ch3_n : natural := 0;
  signal ch1_ready_n, ch1_proc_n, ch2_ready_n, ch3_ready_n : natural := 0;
  signal max_out : natural := 0;

  -- phase 5: ch2 writes region B while ch1 reads region A
  signal ch2_go, ch2_fin : boolean := false;
  signal ch2_inv : boolean := false;                     -- second run: inverted data

  -- region B data of the ROM download (ch2), word k
  function b_data(k : natural) return std_logic_vector is
  begin
    return std_logic_vector(x"B0000000" + to_unsigned(k * 16#10203#, 32));
  end function;

begin

  clk <= not clk after T_CLK / 2 when not done;

  watchdog : process
  begin
    wait for 5 ms;
    assert done report "timeout" severity failure;
    wait;
  end process;

  dut : entity work.sdram
    port map (
      init => init, clk => clk,
      SDRAM_DQ => sd_dq, SDRAM_A => open, SDRAM_DQML => open, SDRAM_DQMH => open, SDRAM_BA => open,
      SDRAM_nCS => sd_ncs, SDRAM_nWE => open, SDRAM_nRAS => open, SDRAM_nCAS => open, SDRAM_CKE => open,
      ch1_addr => ch1_addr, ch1_dout => ch1_dout, ch1_din => ch1_din, ch1_req => ch1_req, ch1_rnw => ch1_rnw,
      ch1_be => ch1_be, ch1_ready => ch1_ready, ch1_reqprocessed => ch1_reqprocessed,
      ch2_addr => ch2_addr, ch2_dout => ch2_dout, ch2_din => ch2_din, ch2_req => ch2_req, ch2_rnw => ch2_rnw,
      ch2_ready => ch2_ready,
      ch3_addr => ch3_addr, ch3_dout => ch3_dout, ch3_din => ch3_din, ch3_req => ch3_req, ch3_rnw => ch3_rnw,
      ch3_ready => ch3_ready,
      mem_clk => mem_clk, mem_address => mem_address, mem_burstcount => mem_burstcount,
      mem_waitrequest => mem_waitrequest, mem_readdata => mem_readdata, mem_readdatavalid => mem_readdatavalid,
      mem_read => mem_read, mem_writedata => mem_writedata, mem_byteenable => mem_byteenable,
      mem_write => mem_write);

  ------------------------------------------------------------------------------
  -- Avalon slave: random waitrequest, reads in order after 1..30 cycles
  ------------------------------------------------------------------------------
  avl : process
    type mem_t is array (0 to WORDS / 4 - 1) of std_logic_vector(63 downto 0);
    variable mem : mem_t := (others => (others => '0'));
    type q_t is array (0 to 63) of std_logic_vector(63 downto 0);
    type qt_t is array (0 to 63) of natural;
    variable q : q_t;
    variable qt : qt_t;
    variable qw, qr, now_c, out_n : natural := 0;
    variable s1, s2 : positive := 7;
    variable r : real;
    variable i : natural;
  begin
    mem_waitrequest <= '1';
    mem_readdatavalid <= '0';
    loop
      wait until rising_edge(clk);
      now_c := now_c + 1;
      assert sd_dq = x"ZZZZ" and sd_ncs = '1' report "SDRAM pins active" severity failure;
      -- command accepted at this edge
      if mem_waitrequest = '0' and (mem_read = '1' or mem_write = '1') then
        assert mem_read = '0' or mem_write = '0' report "read and write at once" severity failure;
        assert mem_burstcount = x"01" report "burstcount " & to_hstring(mem_burstcount) severity failure;
        assert unsigned(mem_address(28 downto 10)) = BASE / 8192
          report "Avalon address " & to_hstring(mem_address) & " outside the window" severity failure;
        i := to_integer(unsigned(mem_address(9 downto 0)));
        if mem_write = '1' then
          for b in 0 to 7 loop
            if mem_byteenable(b) = '1' then
              mem(i)(8 * b + 7 downto 8 * b) := mem_writedata(8 * b + 7 downto 8 * b);
            end if;
          end loop;
        else
          uniform(s1, s2, r);
          q(qw mod 64) := mem(i);
          qt(qw mod 64) := now_c + 1 + integer(floor(r * 30.0));
          if qw > qr and qt(qw mod 64) < qt((qw - 1) mod 64) then
            qt(qw mod 64) := qt((qw - 1) mod 64);    -- in order
          end if;
          qw := qw + 1;
        end if;
      end if;
      if mem_readdatavalid = '1' then
        qr := qr + 1;
      end if;
      -- outputs for the next edge
      mem_readdatavalid <= '0';
      mem_readdata <= (others => 'X');
      if qr < qw and qt(qr mod 64) <= now_c then
        mem_readdatavalid <= '1';
        mem_readdata <= q(qr mod 64);
      end if;
      uniform(s1, s2, r);
      mem_waitrequest <= '1' when r < 0.3 else '0';
      -- reads issued and not answered (the DUT's tags)
      out_n := qw - qr;
      if out_n > max_out then
        max_out <= out_n;
      end if;
    end loop;
  end process;

  mem_clk_chk : process
  begin
    wait until rising_edge(mem_clk);
    assert clk = '1' and clk'last_event = 0 ns report "mem_clk is not clk" severity failure;
  end process;

  ------------------------------------------------------------------------------
  -- ready and reqprocessed only for what was asked
  ------------------------------------------------------------------------------
  mon : process
  begin
    wait until rising_edge(clk);
    if ch1_ready = '1' then ch1_ready_n <= ch1_ready_n + 1; end if;
    if ch1_reqprocessed = '1' then ch1_proc_n <= ch1_proc_n + 1; end if;
    if ch2_ready = '1' then ch2_ready_n <= ch2_ready_n + 1; end if;
    if ch3_ready = '1' then ch3_ready_n <= ch3_ready_n + 1; end if;
    wait for 1 ns;
    assert ch1_ready_n <= ch1_rd_n + ch1_wr_n report "ch1_ready without a request" severity failure;
    assert ch1_proc_n <= ch1_rd_n report "ch1_reqprocessed without a read" severity failure;
    assert ch2_ready_n <= ch2_n report "ch2_ready without a request" severity failure;
    assert ch3_ready_n <= ch3_n report "ch3_ready without a request" severity failure;
  end process;

  ------------------------------------------------------------------------------
  -- ch2: ROM download into region B (phase 5)
  ------------------------------------------------------------------------------
  ch2_proc : process
    procedure ch2_write(a : natural; d : std_logic_vector(31 downto 0)) is
    begin
      wait until rising_edge(clk);
      ch2_addr <= std_logic_vector(to_unsigned(a, 27)); ch2_din <= d; ch2_rnw <= '0';
      ch2_req <= '1'; ch2_n <= ch2_n + 1;
      wait until rising_edge(clk);
      ch2_req <= '0';
      loop
        wait until rising_edge(clk);
        exit when ch2_ready = '1';
      end loop;
    end procedure;
  begin
    loop
      wait until ch2_go;
      ch2_fin <= false;
      for k in 0 to 63 loop
        if ch2_inv then
          ch2_write(BASE + 4096 + 4 * k, not b_data(k));
        else
          ch2_write(BASE + 4096 + 4 * k, b_data(k));
        end if;
      end loop;
      ch2_fin <= true;
      wait until not ch2_go;
    end loop;
  end process;

  ------------------------------------------------------------------------------
  -- main: ch1 like SDRamMux, ch3, phases
  ------------------------------------------------------------------------------
  main : process
    -- reference: 16-bit words of the window
    type ref_t is array (0 to WORDS - 1) of std_logic_vector(15 downto 0);
    variable ref : ref_t := (others => (others => '0'));

    impure function word(a : natural) return natural is
    begin
      assert a >= BASE and a < BASE + 2 * WORDS report "address outside the window" severity failure;
      return (a - BASE) / 2;
    end function;

    impure function ref_read(a : natural) return std_logic_vector is
      variable w : natural := word(a);
    begin
      return ref(w - (w mod 2) + 1 - (w mod 2)) & ref(w);     -- W xor 1 & W
    end function;

    procedure ref_write(a : natural; d : std_logic_vector(31 downto 0); be : std_logic_vector(3 downto 0)) is
      variable w : natural := word(a);
      procedure put(i : natural; v : std_logic_vector(15 downto 0); e : std_logic_vector(1 downto 0)) is
      begin
        for b in 0 to 1 loop
          if e(b) = '1' then
            ref(i)(8 * b + 7 downto 8 * b) := v(8 * b + 7 downto 8 * b);
          end if;
        end loop;
      end procedure;
    begin
      put(w, d(15 downto 0), be(1 downto 0));
      put(w - (w mod 2) + 1, d(31 downto 16), be(3 downto 2));   -- W or 1
    end procedure;

    variable s1, s2 : positive := 3;
    variable r : real;

    impure function rnd(n : natural) return natural is
    begin
      uniform(s1, s2, r);
      return integer(floor(r * real(n)));
    end function;

    impure function rnd_v(n : natural) return std_logic_vector is
      variable v : std_logic_vector(n - 1 downto 0);
    begin
      for i in v'range loop
        v(i) := '1' when rnd(2) = 1 else '0';
      end loop;
      return v;
    end function;

    procedure ch1_write(a : natural; d : std_logic_vector(31 downto 0); be : std_logic_vector(3 downto 0)) is
    begin
      wait until rising_edge(clk);
      ch1_addr <= std_logic_vector(to_unsigned(a, 27)); ch1_din <= d; ch1_be <= be; ch1_rnw <= '0';
      ch1_req <= '1'; ch1_wr_n <= ch1_wr_n + 1;
      wait until rising_edge(clk);
      ch1_req <= '0';
      loop
        wait until rising_edge(clk);
        exit when ch1_ready = '1';
      end loop;
      ref_write(a, d, be);
    end procedure;

    -- SDRamMux WAITREAD as it is: remain = burst length, minus one on every ch1_ready (a word);
    -- on ch1_reqprocessed with remain >= 2 (the value before this edge) the next address (+4).
    -- It does not count what it has issued, so the burst must not issue more than n reads.
    procedure ch1_burst(a : natural; n : positive) is
      type exp_t is array (0 to 255) of std_logic_vector(31 downto 0);
      variable exp : exp_t;
      variable issued, got, remain : natural := 0;
      variable addr : natural := a;
    begin
      for k in 0 to n - 1 loop
        exp(k) := ref_read(a + 4 * k);
      end loop;
      wait until rising_edge(clk);
      ch1_addr <= std_logic_vector(to_unsigned(addr, 27)); ch1_rnw <= '1'; ch1_req <= '1';
      ch1_rd_n <= ch1_rd_n + 1;
      issued := 1;
      remain := n;
      while remain > 0 loop
        wait until rising_edge(clk);
        ch1_req <= '0';
        if ch1_reqprocessed = '1' and remain >= 2 then
          addr := addr + 4;
          ch1_addr <= std_logic_vector(to_unsigned(addr, 27)); ch1_req <= '1';
          ch1_rd_n <= ch1_rd_n + 1;
          issued := issued + 1;
        end if;
        if ch1_ready = '1' then
          assert ch1_dout = exp(got) report "ch1 read " & integer'image(got) & " of " & integer'image(n) &
            " at " & to_hstring(to_unsigned(a + 4 * got, 28)) & ": " & to_hstring(ch1_dout) & ", expected " &
            to_hstring(exp(got)) severity failure;
          got := got + 1;
          remain := remain - 1;
        end if;
      end loop;
      assert issued = n report "ch1 burst of " & integer'image(n) & " issued " & integer'image(issued) &
        " reads (SDRamMux counts only the words)" severity failure;
    end procedure;

    procedure ch3_write(a : natural; d : std_logic_vector(15 downto 0)) is
    begin
      wait until rising_edge(clk);
      ch3_addr <= std_logic_vector(to_unsigned(a, 27)); ch3_din <= d; ch3_rnw <= '0'; ch3_req <= '1';
      ch3_n <= ch3_n + 1;
      wait until rising_edge(clk);
      ch3_req <= '0';
      loop
        wait until rising_edge(clk);
        exit when ch3_ready = '1';
      end loop;
      ref_write(a, x"FF" & d(15 downto 8) & x"FF" & d(7 downto 0), "1111");
    end procedure;

    procedure ch3_read(a : natural) is
      variable e : std_logic_vector(31 downto 0) := ref_read(a);
    begin
      wait until rising_edge(clk);
      ch3_addr <= std_logic_vector(to_unsigned(a, 27)); ch3_rnw <= '1'; ch3_req <= '1';
      ch3_n <= ch3_n + 1;
      wait until rising_edge(clk);
      ch3_req <= '0';
      loop
        wait until rising_edge(clk);
        exit when ch3_ready = '1';
      end loop;
      assert ch3_dout = e(23 downto 16) & e(7 downto 0) report "ch3 read at " & to_hstring(to_unsigned(a, 28)) &
        ": " & to_hstring(ch3_dout) & ", expected " & to_hstring(e(23 downto 16) & e(7 downto 0))
        severity failure;
    end procedure;

    variable a, n : natural;
  begin
    -- 1. a write while init is set waits for init = '0' (sdram.sv keeps its ch1_rq)
    for i in 1 to 5 loop wait until rising_edge(clk); end loop;
    ch1_addr <= std_logic_vector(to_unsigned(BASE, 27)); ch1_din <= x"DEADBEEF"; ch1_be <= "1111";
    ch1_rnw <= '0'; ch1_req <= '1'; ch1_wr_n <= ch1_wr_n + 1;
    wait until rising_edge(clk);
    ch1_req <= '0';
    for i in 1 to 5 loop
      wait until rising_edge(clk);
      assert mem_write = '0' and mem_read = '0' and ch1_ready = '0' report "access during init" severity failure;
    end loop;
    init <= '0';
    n := 0;
    for i in 1 to 100 loop
      wait until rising_edge(clk);
      if ch1_ready = '1' then n := n + 1; end if;
    end loop;
    assert n = 1 report "write from init: " & integer'image(n) & " readies" severity failure;
    ref_write(BASE, x"DEADBEEF", "1111");
    ch1_burst(BASE, 1);

    -- 2. ch2 download of region B, ch1 reads it as one burst
    ch2_go <= true;
    wait until ch2_fin;
    for k in 0 to 63 loop
      ref_write(BASE + 4096 + 4 * k, b_data(k), "1111");
    end loop;
    ch1_burst(BASE + 4096, 64);

    -- 3. random ch1 writes and burst reads in region A (first 4 KB)
    for i in 1 to 400 loop
      a := BASE + 2 * rnd(2040);
      if rnd(2) = 0 then
        ch1_write(a, rnd_v(32), rnd_v(4));
      else
        n := 1 + rnd(8);
        ch1_burst(a, n);
      end if;
    end loop;

    -- 4. ch3 (8-bit mode)
    for i in 1 to 60 loop
      a := BASE + 2 * rnd(2040);
      if rnd(2) = 0 then
        ch3_write(a, rnd_v(16));
      else
        ch3_read(a);
      end if;
    end loop;

    -- 5. ch1 reads region A while ch2 writes region B again, then ch1 reads region B
    ch2_go <= false;
    wait until rising_edge(clk);
    ch1_burst(BASE + 4096, 64);                -- region B unchanged by phases 3 and 4
    for k in 0 to 63 loop
      ref_write(BASE + 4096 + 4 * k, not b_data(k), "1111");
    end loop;
    ch2_inv <= true;
    ch2_go <= true;
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    while not ch2_fin loop
      ch1_burst(BASE + 8 * rnd(240), 16);
    end loop;
    ch1_burst(BASE + 4096, 64);

    wait for 1 us;
    assert ch1_ready_n = ch1_rd_n + ch1_wr_n and ch1_proc_n = ch1_rd_n and ch2_ready_n = ch2_n and
      ch3_ready_n = ch3_n report "ready/reqprocessed counts: ch1 " & integer'image(ch1_ready_n) & "/" &
      integer'image(ch1_rd_n + ch1_wr_n) & ", proc " & integer'image(ch1_proc_n) & "/" & integer'image(ch1_rd_n) &
      ", ch2 " & integer'image(ch2_ready_n) & "/" & integer'image(ch2_n) & ", ch3 " & integer'image(ch3_ready_n) &
      "/" & integer'image(ch3_n) severity failure;
    assert max_out = 1 report "reads in flight at most " & integer'image(max_out) &
      ", expected 1 (ch1 one at a time, the drivers read one channel at a time)" severity failure;
    report "PASS";
    done <= true;
    wait;
  end process;

end architecture tb;
