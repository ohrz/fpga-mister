-------------------------------------------------------------------------------
-- Title      : Testbench of the PSX PLL replacements
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : psx_pll_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-31
-------------------------------------------------------------------------------
-- Description:
--   cores/psx/pll.vhd, pll2.vhd and pll_cfg.vhd with the unisim MMCME2_BASE,
--   PLLE2_BASE and BUFGCTRL models, refclk 50 MHz, rst '0' as in PSX.sv,
--   G_RST_CYCLES 1024 (the MMCM model needs more than 4 * 64 refclk cycles to
--   lock).  refclk starts only at T_START (CLK_50M starts after the PL
--   configuration).
--   Checks:
--     pll_reset of pll and of both sources of pll2: the reset (external
--     names) is '1' before T_START and for RST_CYCLES refclk edges after it,
--     then '0'
--     pll: locked rises after the reset; then every rising edge of clk_1x,
--     clk_2x and clk_3x lies on its grid of 29.538, 14.769 and 9.846 ns
--     (812.5 MHz / 24, 12, 8) counted from the first clk_1x edge after lock
--     where all three rise (common phase of the 1:2:3 clocks; without one the
--     bench times out), so the period and phase, high time half the period
--     pll2 (after both sources locked) with pll_cfg, written as PSX.sv does
--     (addresses 0, 5, 7, 2): mean period of clk_vid over 2000 periods, each
--     period within 0.1 ns of it, in this order
--       start (no write)              NTSC 18.6207 ns (53.703704 MHz) +- 1 ps
--       PAL divider to address 5      still NTSC (only address 7 counts)
--       PAL divider to address 7      PAL  18.7952 ns (53.205128 MHz) +- 1 ps
--       NTSC divider to address 7     NTSC again
--       PAL, then the fast-forward divider to address 7   NTSC
--     from the first lock on no high or low phase of clk_vid shorter than
--     9.2 ns (glitch-free switch); waitrequest '0' at every write
--   Ends with "PASS" or a failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity psx_pll_tb is
end entity;

architecture tb of psx_pll_tb is
  constant T_START : time := 3 us;           -- first refclk edge
  constant RST_CYCLES : positive := 1024;
  signal refclk : std_logic := '0';
  signal run_ref : boolean := false;
  signal rst    : std_logic := '0';
  signal clk_1x, clk_2x, clk_3x, locked, clk_vid : std_logic;
  signal from_pll, to_pll : std_logic_vector(63 downto 0);
  signal cfg_wait, cfg_write : std_logic := '0';
  signal cfg_addr  : std_logic_vector(5 downto 0) := (others => '0');
  signal cfg_data  : std_logic_vector(31 downto 0) := (others => '0');
  signal vid_on    : boolean := false;           -- glitch check from the first lock of pll2
  signal t0     : time := 0 ns;              -- first common edge of the core clocks after lock
  type ok_t is array (0 to 2) of boolean;
  signal ok_grid : ok_t := (others => false);   -- clk_1x, clk_2x, clk_3x checked
  signal ok_vid  : boolean := false;
  signal ok_rst  : boolean := false;

  constant TOL : time := 10 ps;
  type periods_t is array (0 to 2) of time;
  constant PERIODS : periods_t := (29538.461538 ps, 14769.230769 ps, 9846.153846 ps);   -- clk_1x, 2x, 3x
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
    port map (refclk => refclk, rst => rst, outclk_0 => clk_1x, outclk_1 => clk_2x, outclk_2 => clk_3x,
              locked => locked);
  dut2 : entity work.pll2
    generic map (G_RST_CYCLES => RST_CYCLES)
    port map (refclk => refclk, rst => rst, outclk_0 => clk_vid, reconfig_to_pll => to_pll,
              reconfig_from_pll => from_pll);
  cfg : entity work.pll_cfg
    port map (mgmt_clk => refclk, mgmt_reset => '0', mgmt_waitrequest => cfg_wait, mgmt_read => '0',
              mgmt_write => cfg_write, mgmt_readdata => open, mgmt_address => cfg_addr,
              mgmt_writedata => cfg_data, reconfig_to_pll => to_pll, reconfig_from_pll => from_pll);

  -- pll_reset: MMCM reset from configuration until RST_CYCLES refclk edges after refclk started
  process
    alias rst1 is <<signal .psx_pll_tb.dut.mmcm_rst : std_logic>>;
    alias rst2 is <<signal .psx_pll_tb.dut2.mmcm_rst : std_logic>>;
    alias rst3 is <<signal .psx_pll_tb.dut2.pll_rst : std_logic>>;
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
    c <= clk_1x when i = 0 else clk_2x when i = 1 else clk_3x;
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
    -- grid origin: a clk_1x edge where clk_2x and clk_3x rise too (every clk_1x period at 1:2:3)
    loop
      wait until rising_edge(clk_1x);
      wait for TOL;
      exit when clk_2x = '1' and clk_2x'last_event <= 2 * TOL and clk_3x = '1' and clk_3x'last_event <= 2 * TOL;
    end loop;
    t0 <= now - TOL;
    wait;
  end process;

  -- clk_vid: rates in the order NTSC, NTSC (write to address 5), PAL, NTSC, PAL, NTSC (fast forward)
  process
    alias locked2 is <<signal .psx_pll_tb.dut2.lock_i : std_logic>>;
    constant P_NTSC : time := 18620.69 ps;  -- 1450 MHz / 27
    constant P_PAL  : time := 18795.18 ps;  -- 1037.5 MHz / 19.5
    constant K_PAL  : std_logic_vector(31 downto 0) := x"83365882";   -- 2201376898 of PSX.sv
    constant K_NTSC : std_logic_vector(31 downto 0) := x"9745BF27";   -- 2537930535
    constant K_FFW  : std_logic_vector(31 downto 0) := x"80000000";   -- 2147483648 (fast forward)

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

    -- one region change as PSX.sv writes it: addresses 0, 5, 7 (divider K), 2; K at address a7
    procedure region(k7 : std_logic_vector(31 downto 0); a7 : std_logic_vector(5 downto 0)) is
      type addr_t is array (0 to 3) of std_logic_vector(5 downto 0);
      constant ADDR : addr_t := ("000000", "000101", a7, "000010");
    begin
      for k in 0 to 3 loop
        wait until rising_edge(refclk);
        cfg_addr <= ADDR(k);
        cfg_data <= k7 when k = 2 else x"00000404" when k = 1 else (others => '0');
        cfg_write <= '1';
        wait until rising_edge(refclk);
        assert cfg_wait = '0' report "pll_cfg: waitrequest" severity failure;
        cfg_write <= '0';
      end loop;
    end procedure;
  begin
    wait until locked2 = '1';
    vid_on <= true;
    wait for 1 us;
    measure(P_NTSC, "start");
    region(K_PAL, "000101");
    measure(P_NTSC, "PAL divider to address 5");
    region(K_PAL, "000111");
    measure(P_PAL, "PAL");
    region(K_NTSC, "000111");
    measure(P_NTSC, "NTSC");
    region(K_PAL, "000111");
    measure(P_PAL, "PAL again");
    region(K_FFW, "000111");
    measure(P_NTSC, "fast forward");
    ok_vid <= true;
    wait;
  end process;

  -- glitch-free switch: no phase of clk_vid shorter than 9.2 ns once pll2 has locked
  process
    variable te : time := 0 ns;
  begin
    wait until vid_on;
    wait on clk_vid;
    te := now;
    loop
      wait on clk_vid until ok_vid for 1 ms;
      exit when ok_vid;
      assert now - te >= 9.2 ns
        report "clk_vid phase of " & time'image(now - te) & " (glitch)" severity failure;
      te := now;
    end loop;
    wait;
  end process;

  process
  begin
    wait until ok_grid = (0 to 2 => true) and ok_vid and ok_rst for 2 ms;
    assert ok_grid = (0 to 2 => true) and ok_vid and ok_rst report "timeout: grid " & boolean'image(ok_grid(0)) & boolean'image(ok_grid(1)) &
      boolean'image(ok_grid(2)) & ", clk_vid " & boolean'image(ok_vid) & ", reset " & boolean'image(ok_rst)
      severity failure;
    report "PASS";
    std.env.finish;                         -- a stopped refclk makes the MMCM model fail
    wait;
  end process;

end architecture tb;
