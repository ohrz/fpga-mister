-------------------------------------------------------------------------------
-- Title      : Testbench of the N64 PLL replacements
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : n64_pll_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   cores/n64/pll.vhd, pll2.vhd and pll_cfg_small.vhd with the unisim
--   MMCME2_BASE, PLLE2_BASE and BUFGCTRL models, refclk 50 MHz, rst '0' as in
--   N64.sv, G_RST_CYCLES 1024 (the MMCM model needs more than 4 * 64 refclk
--   cycles to lock).
--   refclk starts only at T_START (CLK_50M starts after the PL configuration).
--   Checks:
--     pll_reset of pll and of both sources of pll2: the reset (external
--     names) is '1' before T_START and for RST_CYCLES refclk edges after it,
--     then '0'
--     pll: locked rises after the reset; then every rising edge of clk_1x,
--     clk_93 and clk_2x lies on its grid of 16, 10.667 and 8 ns counted from the
--     first clk_1x edge after lock where all three rise (common phase of the
--     2:3:4 clocks; without one the bench times out), so the period and phase,
--     high time half the period, outclk_3 stays '0'
--     pll2 (after both sources locked) with pll_cfg_small, written as N64.sv
--     does (addresses 0, 7, 2): mean period of clk_vid over 2000 periods,
--     each period within 0.1 ns of it, in this order
--       start (no write)            NTSC 20.5405 ns (48.684211 MHz) +- 1 ps
--       PAL divider to address 0    still NTSC (only address 7 counts)
--       PAL divider to address 7    PAL  20.1386 ns (49.655963 MHz) +- 1 ps
--       MPAL divider to address 7   NTSC again
--     from the first lock on no high or low phase of clk_vid shorter than
--     9.9 ns (glitch-free switch); waitrequest '0' at every write
--   Ends with "PASS" or a failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity n64_pll_tb is
end entity;

architecture tb of n64_pll_tb is
  constant T_START : time := 3 us;           -- first refclk edge
  constant RST_CYCLES : positive := 1024;
  signal refclk : std_logic := '0';
  signal run_ref : boolean := false;
  signal rst    : std_logic := '0';
  signal clk_1x, clk_93, clk_2x, sdram_clk, locked, clk_vid : std_logic;
  signal from_pll, to_pll : std_logic_vector(63 downto 0);
  signal cfg_wait, cfg_write : std_logic := '0';
  signal cfg_addr  : std_logic_vector(5 downto 0) := (others => '0');
  signal cfg_data  : std_logic_vector(31 downto 0) := (others => '0');
  signal vid_on    : boolean := false;           -- glitch check from the first lock of pll2
  signal t0     : time := 0 ns;              -- first common edge of the core clocks after lock
  type ok_t is array (0 to 2) of boolean;
  signal ok_grid : ok_t := (others => false);   -- clk_1x, clk_93, clk_2x checked
  signal ok_vid  : boolean := false;
  signal ok_rst  : boolean := false;

  constant TOL : time := 10 ps;
  type periods_t is array (0 to 2) of time;
  constant PERIODS : periods_t := (16 ns, 10666.667 ps, 8 ns);   -- clk_1x, clk_93, clk_2x
begin

  run_ref <= true after T_START;

  process
  begin
    wait until run_ref;
    loop
      refclk <= '1';
      wait for 10 ns;
      refclk <= '0';
      wait for 10 ns;
    end loop;
  end process;

  dut : entity work.pll
    generic map (G_RST_CYCLES => RST_CYCLES)
    port map (refclk => refclk, rst => rst, outclk_0 => clk_1x, outclk_1 => clk_93, outclk_2 => clk_2x,
              outclk_3 => sdram_clk, locked => locked);
  dut2 : entity work.pll2
    generic map (G_RST_CYCLES => RST_CYCLES)
    port map (refclk => refclk, rst => rst, outclk_0 => clk_vid, reconfig_to_pll => to_pll,
              reconfig_from_pll => from_pll);
  cfg : entity work.pll_cfg_small
    port map (mgmt_clk => refclk, mgmt_reset => '0', mgmt_waitrequest => cfg_wait, mgmt_write => cfg_write,
              mgmt_address => cfg_addr, mgmt_writedata => cfg_data, reconfig_to_pll => to_pll,
              reconfig_from_pll => from_pll);

  -- pll_reset: MMCM reset from configuration until RST_CYCLES refclk edges after refclk started
  process
    alias rst1 is <<signal .n64_pll_tb.dut.mmcm_rst : std_logic>>;
    alias rst2 is <<signal .n64_pll_tb.dut2.mmcm_rst : std_logic>>;
    alias rst3 is <<signal .n64_pll_tb.dut2.pll_rst : std_logic>>;
    variable n : natural := 0;
  begin
    wait for T_START - 1 ns;
    assert rst1 = '1' and rst2 = '1' and rst3 = '1' report "PLL/MMCM reset not '1' before refclk started"
      severity failure;
    while rst1 = '1' or rst2 = '1' or rst3 = '1' loop
      wait until rising_edge(refclk);
      assert rst1 = rst2 and rst1 = rst3 report "the resets of pll and pll2 differ" severity failure;
      n := n + 1;
      assert n <= RST_CYCLES + 2 report "MMCM reset longer than RST_CYCLES refclk edges" severity failure;
    end loop;
    assert n >= RST_CYCLES report "MMCM reset only " & integer'image(n) & " refclk edges" severity failure;
    ok_rst <= true;
    wait;
  end process;

  -- grid check of one pll output: rising edges at t0 + k * period, high time period / 2
  grid : for i in 0 to 2 generate
    signal c : std_logic;
  begin
    c <= clk_1x when i = 0 else clk_93 when i = 1 else clk_2x;
    process
      constant PERIOD : time := PERIODS(i);
      variable n : natural := 0;
      variable tr, d : time;
    begin
      wait until t0 > 0 ns;
      while n < 500 loop
        wait until rising_edge(c);
        tr := now;
        d := (tr - t0) mod PERIOD;
        assert d <= TOL or PERIOD - d <= TOL
          report "clock " & integer'image(i) & ": rising edge at " & time'image(tr) & " off the " &
                 time'image(PERIOD) & " grid from " & time'image(t0) severity failure;
        wait until falling_edge(c);
        assert abs ((now - tr) - PERIOD / 2) <= TOL
          report "clock " & integer'image(i) & ": high time " & time'image(now - tr) severity failure;
        n := n + 1;
      end loop;
      ok_grid(i) <= true;
      wait;
    end process;
  end generate;

  process
  begin
    assert locked /= '1' report "locked before the reset ended" severity failure;
    wait until locked = '1' for 200 us;
    assert locked = '1' report "pll: no lock within 200 us" severity failure;
    -- grid origin: a clk_1x edge where clk_93 and clk_2x rise too (every 32 ns at 2:3:4)
    loop
      wait until rising_edge(clk_1x);
      wait for TOL;
      exit when clk_93 = '1' and clk_93'last_event <= 2 * TOL and clk_2x = '1' and clk_2x'last_event <= 2 * TOL;
    end loop;
    t0 <= now - TOL;
    wait;
  end process;

  -- clk_vid: rates in the order NTSC, NTSC (write to address 0), PAL, NTSC (MPAL)
  process
    alias locked2 is <<signal .n64_pll_tb.dut2.lock_i : std_logic>>;
    constant P_NTSC : time := 20540.54 ps;  -- 925 MHz / 19
    constant P_PAL  : time := 20138.57 ps;  -- 676.5625 MHz / 13.625
    constant DSM_PAL  : std_logic_vector(31 downto 0) := x"F02C4355";   -- VCLK_DSM_PAL of N64.sv
    constant DSM_MPAL : std_logic_vector(31 downto 0) := x"C0CB062C";   -- VCLK_DSM_MPAL

    procedure measure(p : time; what : string) is
      variable t1, tp : time;
    begin
      wait for 2 us;                          -- the switch and the BUFGCTRL handover
      wait until rising_edge(clk_vid);
      t1 := now;
      tp := now;
      for k in 1 to 2000 loop
        wait until rising_edge(clk_vid);
        assert abs ((now - tp) - p) <= 100 ps
          report what & ": clk_vid period " & time'image(now - tp) severity failure;
        tp := now;
      end loop;
      assert abs ((now - t1) / 2000 - p) <= 1 ps
        report what & ": clk_vid mean period " & time'image((now - t1) / 2000) & ", expected " & time'image(p)
        severity failure;
      report what & ": clk_vid mean period " & time'image((now - t1) / 2000);
    end procedure;

    -- one region change as N64.sv writes it: address 0, 7 (divider), 2; data of 7 at address a7
    procedure region(d : std_logic_vector(31 downto 0); a7 : std_logic_vector(5 downto 0)) is
      type addr_t is array (0 to 2) of std_logic_vector(5 downto 0);
      constant ADDR : addr_t := ("000000", a7, "000010");
    begin
      for k in 0 to 2 loop
        wait until rising_edge(refclk);
        cfg_addr <= ADDR(k);
        cfg_data <= d when k = 1 else (others => '0');
        cfg_write <= '1';
        wait until rising_edge(refclk);
        assert cfg_wait = '0' report "pll_cfg_small: waitrequest" severity failure;
        cfg_write <= '0';
      end loop;
    end procedure;
  begin
    wait until locked2 = '1';
    vid_on <= true;
    wait for 1 us;
    measure(P_NTSC, "start");
    region(DSM_PAL, "000000");
    measure(P_NTSC, "PAL divider to address 0");
    region(DSM_PAL, "000111");
    measure(P_PAL, "PAL");
    region(DSM_MPAL, "000111");
    measure(P_NTSC, "MPAL");
    ok_vid <= true;
    wait;
  end process;

  -- glitch-free switch: no phase of clk_vid shorter than 9.9 ns once pll2 has locked
  process
    variable te : time := 0 ns;
  begin
    wait until vid_on;
    wait on clk_vid;
    te := now;
    loop
      wait on clk_vid until ok_vid for 1 ms;
      exit when ok_vid;
      assert now - te >= 9.9 ns
        report "clk_vid phase of " & time'image(now - te) & " (glitch)" severity failure;
      te := now;
    end loop;
    wait;
  end process;

  process
  begin
    wait on sdram_clk;
    assert now = 0 ns report "outclk_3 changed at " & time'image(now) severity failure;
  end process;

  process
  begin
    wait until ok_grid = (0 to 2 => true) and ok_vid and ok_rst for 2 ms;
    assert ok_grid = (0 to 2 => true) and ok_vid and ok_rst report "timeout: grid " & boolean'image(ok_grid(0)) & boolean'image(ok_grid(1)) &
      boolean'image(ok_grid(2)) & ", clk_vid " & boolean'image(ok_vid) & ", reset " & boolean'image(ok_rst)
      severity failure;
    assert sdram_clk = '0' report "outclk_3 not '0'" severity failure;
    report "PASS";
    std.env.finish;                         -- a stopped refclk makes the MMCM model fail
    wait;
  end process;

end architecture tb;
