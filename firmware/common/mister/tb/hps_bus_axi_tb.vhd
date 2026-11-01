-------------------------------------------------------------------------------
-- Title      : Testbench of hps_bus_axi
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : hps_bus_axi_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   The main process is Main_MiSTer (fpga_io.cpp, spi.cpp) as an AXI4-Lite
--   master with random valid/ready delays: fpga_spi (strobe, wait for ack,
--   strobe low, wait for ack low), fpga_spi_fast, fpga_spi_fast_block_write and
--   _read (no ack check), EnableFpga/EnableIO/EnableOsd(target) and their
--   disables, fpga_core_reset and fpga_core_id (reset protocol, core magic).
--   A model of hps_io on clk_sys logs every io_strobe with io_din and the chip
--   selects, answers with io_dout = resp(word, index) G_LAT cycles later and
--   raises io_wait (file I/O frame) or vs_wait (OSD frames) after a strobe for
--   a random time.  Checks:
--     - every word arrives exactly once, in order, under the right chip
--       selects (log against the list Main sent), also for the fast transfers;
--     - each response Main reads belongs to its own word;
--     - no strobe while io_wait/vs_wait is high (Main got no ack);
--     - core magic, GPI bit layout with buttons, reset request sequence, LED,
--       ID/STATUS/GPO readback, a GPI read that overtakes a GPO write;
--     - clk_sys stopped: write ends after the timeout, GPI reads FFFFFFFF at
--       once, a write while behind is dropped, the pending value arrives after
--       the clock resumes;
--     - AXI rules: BVALID/RVALID/RDATA held until ready, no response without
--       a request, OKAY responses.
--   clk_sys modes: 21.5 MHz, gated 22.5 MHz with random stalls (stage C),
--   150 MHz (faster than aclk), 5 MHz with stalls.
--   G_RAW = true: the DUT in its register-only mode with a model of the HPS
--   logic of sys_top.v (gp_outd/gp_outr, strobe/ack, chip selects, core magic)
--   between the DUT and the hps_io model, the same checks.
--   Ends with "PASS" or a failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity hps_bus_axi_tb is
  generic (
    G_RAW : boolean := false;           -- DUT register-only, sys_top.v model behind it
    G_LAT : natural := 7                -- io_dout latency of the hps_io model (hps_io.sv: 0; 7 is
                                        -- the most the GPI snapshot with G_RD_WAIT = 2 allows)
  );
end entity;

architecture tb of hps_bus_axi_tb is

  constant C_TIMEOUT : positive := 3000;
  constant C_RD_WAIT : natural := 2 + 2 * boolean'pos(G_RAW);   -- sys_top delays gp_out by 2
  -- core magic: the DUT has core type A4, the sys_top model A8 (G_RAW must answer from sys_top)
  function magic(raw : boolean) return std_logic_vector is
  begin
    if raw then
      return x"5CA623A8";
    end if;
    return x"5CA623A4";
  end function;
  constant C_MAGIC   : std_logic_vector(31 downto 0) := magic(G_RAW);
  constant C_ACLK    : time := 10 ns;

  constant A_GPO : std_logic_vector(3 downto 0) := x"0";
  constant A_GPI : std_logic_vector(3 downto 0) := x"4";
  constant A_ID  : std_logic_vector(3 downto 0) := x"8";
  constant A_STA : std_logic_vector(3 downto 0) := x"C";

  constant STROBE  : std_logic_vector(31 downto 0) := x"00020000";
  constant FPGA_EN : std_logic_vector(31 downto 0) := x"00040000";
  constant OSD_EN  : std_logic_vector(31 downto 0) := x"00080000";
  constant IO_EN   : std_logic_vector(31 downto 0) := x"00100000";

  -- chip selects as logged: io_fpga & io_uio & io_osd_hdmi & io_osd_vga
  constant SEL_FPGA : std_logic_vector(3 downto 0) := "1000";
  constant SEL_IO   : std_logic_vector(3 downto 0) := "0100";
  constant SEL_OSD  : std_logic_vector(3 downto 0) := "0011";
  constant SEL_HDMI : std_logic_vector(3 downto 0) := "0010";
  constant SEL_VGA  : std_logic_vector(3 downto 0) := "0001";

  function resp(w : std_logic_vector(15 downto 0); idx : natural) return std_logic_vector is
  begin
    return w xor std_logic_vector(to_unsigned((idx * 40503 + 7) mod 65536, 16));
  end function;

  signal aclk          : std_logic := '0';
  signal aresetn       : std_logic := '0';
  signal s_axi_awaddr  : std_logic_vector(3 downto 0) := (others => '0');
  signal s_axi_awvalid : std_logic := '0';
  signal s_axi_awready : std_logic;
  signal s_axi_wdata   : std_logic_vector(31 downto 0) := (others => '0');
  signal s_axi_wstrb   : std_logic_vector(3 downto 0) := (others => '0');
  signal s_axi_wvalid  : std_logic := '0';
  signal s_axi_wready  : std_logic;
  signal s_axi_bresp   : std_logic_vector(1 downto 0);
  signal s_axi_bvalid  : std_logic;
  signal s_axi_bready  : std_logic := '0';
  signal s_axi_araddr  : std_logic_vector(3 downto 0) := (others => '0');
  signal s_axi_arvalid : std_logic := '0';
  signal s_axi_arready : std_logic;
  signal s_axi_rdata   : std_logic_vector(31 downto 0);
  signal s_axi_rresp   : std_logic_vector(1 downto 0);
  signal s_axi_rvalid  : std_logic;
  signal s_axi_rready  : std_logic := '0';

  signal reset_in  : std_logic := '0';
  signal reset_req : std_logic;
  signal quiesce   : std_logic;
  signal hp_idle   : std_logic := '0';
  signal led_disk  : std_logic;

  signal clk_sys     : std_logic := '0';
  signal io_din      : std_logic_vector(15 downto 0);
  signal io_strobe   : std_logic;
  signal io_fpga     : std_logic;
  signal io_uio      : std_logic;
  signal io_osd_hdmi : std_logic;
  signal io_osd_vga  : std_logic;
  signal io_dout     : std_logic_vector(15 downto 0) := (others => '0');
  signal io_wide     : std_logic := '1';
  signal io_wait     : std_logic := '0';
  signal vs_wait     : std_logic := '0';
  signal btn_osd     : std_logic := '0';
  signal btn_user    : std_logic := '0';
  signal io_dig      : std_logic := '0';
  signal hdmi_int    : std_logic := '0';
  -- DUT outputs (G_RAW: unused) and the register-only interface
  signal d_io_din      : std_logic_vector(15 downto 0);
  signal d_io_strobe, d_io_fpga, d_io_uio, d_io_osd_hdmi, d_io_osd_vga : std_logic;
  signal gp_out_sys    : std_logic_vector(31 downto 0);
  signal gp_in_sys     : std_logic_vector(31 downto 0) := (others => '0');

  -- clk_sys control
  signal sys_period : time := 46.5 ns;
  signal sys_stall  : natural := 0;          -- percent of missing pulses
  signal sys_run    : boolean := true;
  signal done       : boolean := false;

  -- strobe log of the hps_io model: chip selects & io_din
  type log_t is array (0 to 16383) of std_logic_vector(19 downto 0);
  signal rx_log : log_t;
  signal rx_cnt : natural := 0;

begin

  dut : entity work.hps_bus_axi
    generic map (G_CORE_TYPE => x"A4", G_RD_WAIT => C_RD_WAIT, G_TIMEOUT => C_TIMEOUT, G_RAW => G_RAW)
    port map (
      aclk => aclk, aresetn => aresetn,
      s_axi_awaddr => s_axi_awaddr, s_axi_awprot => "000", s_axi_awvalid => s_axi_awvalid,
      s_axi_awready => s_axi_awready, s_axi_wdata => s_axi_wdata, s_axi_wstrb => s_axi_wstrb,
      s_axi_wvalid => s_axi_wvalid, s_axi_wready => s_axi_wready, s_axi_bresp => s_axi_bresp,
      s_axi_bvalid => s_axi_bvalid, s_axi_bready => s_axi_bready, s_axi_araddr => s_axi_araddr,
      s_axi_arprot => "000", s_axi_arvalid => s_axi_arvalid, s_axi_arready => s_axi_arready,
      s_axi_rdata => s_axi_rdata, s_axi_rresp => s_axi_rresp, s_axi_rvalid => s_axi_rvalid,
      s_axi_rready => s_axi_rready,
      reset_in => reset_in, reset_req => reset_req, quiesce => quiesce, idle => hp_idle, led_disk => led_disk,
      clk_sys => clk_sys, io_din => d_io_din, io_strobe => d_io_strobe, io_fpga => d_io_fpga, io_uio => d_io_uio,
      io_osd_hdmi => d_io_osd_hdmi, io_osd_vga => d_io_osd_vga, io_dout => io_dout, io_wide => io_wide,
      io_wait => io_wait, vs_wait => vs_wait, btn_osd => btn_osd, btn_user => btn_user, io_dig => io_dig,
      hdmi_int => hdmi_int, gp_out_sys => gp_out_sys, gp_in_sys => gp_in_sys);

  g_dut_io : if not G_RAW generate
    io_din <= d_io_din; io_strobe <= d_io_strobe; io_fpga <= d_io_fpga; io_uio <= d_io_uio;
    io_osd_hdmi <= d_io_osd_hdmi; io_osd_vga <= d_io_osd_vga;
  end generate;

  -- sys_top.v:234-283 (gp_out of the Cyclone V block = gp_out_sys; buttons without the debouncer)
  g_systop : if G_RAW generate
    signal gp_outd, gp_outr : std_logic_vector(31 downto 0) := (others => '0');
    signal rack, io_ack : std_logic := '0';
    signal sys_strobe : std_logic;
  begin
    process (clk_sys)
    begin
      if rising_edge(clk_sys) then
        gp_outd <= gp_out_sys;
        gp_outr <= gp_outd;
        if (io_wait or vs_wait) = '0' or sys_strobe = '1' then
          rack   <= gp_outr(17);
          io_ack <= rack;
        end if;
      end if;
    end process;
    sys_strobe  <= not rack and gp_outr(17);
    io_strobe   <= sys_strobe;
    io_din      <= gp_outr(15 downto 0);
    io_fpga     <= not gp_outr(19) and gp_outr(18);
    io_uio      <= not gp_outr(19) and gp_outr(20);
    io_osd_hdmi <= gp_outr(19) and not gp_outr(18);
    io_osd_vga  <= gp_outr(19) and not gp_outr(20);
    gp_in_sys   <= x"5CA623A8" when gp_out_sys(31) = '0' else
                   '0' & btn_user & btn_osd & io_dig & "0000000" & hdmi_int & "01" & io_ack & io_wide & io_dout;
  end generate;

  aclk <= not aclk after C_ACLK / 2 when not done;

  -- clk_sys: free running or gated (missing pulses, sometimes a long stall), or stopped
  sys_gen : process
    variable s1, s2 : positive := 17;
    variable r : real;
  begin
    if done then
      wait;
    end if;
    if not sys_run then
      wait until sys_run or done;
    end if;
    uniform(s1, s2, r);
    if r * 100.0 < real(sys_stall) then
      uniform(s1, s2, r);
      if r < 0.05 then
        wait for sys_period * 40;
      else
        wait for sys_period;
      end if;
    else
      clk_sys <= '1';
      wait for sys_period / 2;
      clk_sys <= '0';
      wait for sys_period / 2;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- hps_io model
  ------------------------------------------------------------------------------
  hps_io : process (clk_sys)
    variable s1, s2 : positive := 23;
    variable r : real;
    variable wcnt, vcnt, lat : natural := 0;
    variable pend : std_logic_vector(15 downto 0);
  begin
    if rising_edge(clk_sys) then
      if lat > 0 then
        lat := lat - 1;
        if lat = 0 then
          io_dout <= pend;
        end if;
      end if;
      if wcnt > 0 then
        wcnt := wcnt - 1;
        if wcnt = 0 then
          io_wait <= '0';
        end if;
      end if;
      if vcnt > 0 then
        vcnt := vcnt - 1;
        if vcnt = 0 then
          vs_wait <= '0';
        end if;
      end if;

      if io_strobe = '1' then
        assert io_wait = '0' and vs_wait = '0'
          report "strobe while io_wait/vs_wait: Main got an ack it must not get" severity failure;
        rx_log(rx_cnt) <= io_fpga & io_uio & io_osd_hdmi & io_osd_vga & io_din;
        rx_cnt <= rx_cnt + 1;
        pend := resp(io_din, rx_cnt);
        if G_LAT = 0 then
          io_dout <= pend;
        else
          lat := G_LAT;
        end if;
        uniform(s1, s2, r);
        if io_fpga = '1' and r < 0.5 then
          io_wait <= '1';
          wcnt := 1 + natural(floor(r * 80.0));
        elsif io_osd_hdmi = '1' and r < 0.5 then
          vs_wait <= '1';
          vcnt := 1 + natural(floor(r * 80.0));
        end if;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- AXI rule checker
  ------------------------------------------------------------------------------
  axi_check : process (aclk)
    variable hold_b, hold_r : boolean := false;
    variable rd_prev : std_logic_vector(31 downto 0);
    variable n_w, n_b, n_ar, n_r : natural := 0;
  begin
    if rising_edge(aclk) then
      if hold_b then
        assert s_axi_bvalid = '1' report "BVALID dropped without BREADY" severity failure;
      end if;
      if hold_r then
        assert s_axi_rvalid = '1' and s_axi_rdata = rd_prev report "RVALID/RDATA changed without RREADY"
          severity failure;
      end if;
      hold_b := s_axi_bvalid = '1' and s_axi_bready = '0';
      hold_r := s_axi_rvalid = '1' and s_axi_rready = '0';
      rd_prev := s_axi_rdata;
      assert (s_axi_awvalid and s_axi_awready) = (s_axi_wvalid and s_axi_wready)
        report "AW and W taken in different cycles (both are taken together)" severity failure;
      if s_axi_awvalid = '1' and s_axi_awready = '1' then n_w := n_w + 1; end if;
      if s_axi_arvalid = '1' and s_axi_arready = '1' then n_ar := n_ar + 1; end if;
      assert s_axi_bvalid = '0' or n_b < n_w report "BVALID without a write" severity failure;
      assert s_axi_rvalid = '0' or n_r < n_ar report "RVALID without a read" severity failure;
      if s_axi_bvalid = '1' and s_axi_bready = '1' then n_b := n_b + 1; end if;
      if s_axi_rvalid = '1' and s_axi_rready = '1' then n_r := n_r + 1; end if;
      assert s_axi_bvalid = '0' or s_axi_bresp = "00" report "BRESP not OKAY" severity failure;
      assert s_axi_rvalid = '0' or s_axi_rresp = "00" report "RRESP not OKAY" severity failure;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Main_MiSTer
  ------------------------------------------------------------------------------
  main : process
    variable s1, s2 : positive := 5;
    variable r : real;
    variable gpo : std_logic_vector(31 downto 0) := (others => '0');   -- gpo_copy of Main
    type exp_t is array (0 to 16383) of std_logic_vector(19 downto 0);
    variable exp_log : exp_t;
    variable exp_cnt, chk_from : natural := 0;
    variable g, e : std_logic_vector(31 downto 0);
    variable w : std_logic_vector(15 downto 0);
    variable t0 : time;
    variable n_spi, n_fast, n_frames : natural := 0;
    variable b : std_logic_vector(3 downto 0);

    impure function rnd(n : natural) return natural is
    begin
      uniform(s1, s2, r);
      return natural(floor(r * real(n)));
    end function;

    impure function rnd16 return std_logic_vector is
    begin
      return std_logic_vector(to_unsigned(rnd(65536), 16));
    end function;

    -- valid/ready delay: mostly 0 (back-to-back CPU accesses, the tightest case), sometimes 1..3
    impure function dly return natural is
    begin
      if rnd(3) /= 0 then
        return 0;
      end if;
      return 1 + rnd(3);
    end function;

    procedure tick(n : positive := 1) is
    begin
      for i in 1 to n loop
        wait until rising_edge(aclk);
      end loop;
    end procedure;

    procedure axi_wr(a : std_logic_vector(3 downto 0); v : std_logic_vector(31 downto 0)) is
      variable d1, d2, d3, i : natural;
      variable aw_ok, w_ok : boolean := false;
    begin
      d1 := dly; d2 := dly; d3 := dly;
      s_axi_awaddr <= a; s_axi_wdata <= v; s_axi_wstrb <= "1111";
      i := 0;
      while not (aw_ok and w_ok) loop
        if not aw_ok and i >= d1 then s_axi_awvalid <= '1'; end if;
        if not w_ok and i >= d2 then s_axi_wvalid <= '1'; end if;
        tick;
        if s_axi_awvalid = '1' and s_axi_awready = '1' then aw_ok := true; s_axi_awvalid <= '0'; end if;
        if s_axi_wvalid = '1' and s_axi_wready = '1' then w_ok := true; s_axi_wvalid <= '0'; end if;
        i := i + 1;
        assert i < 100000 report "AW/W handshake timeout" severity failure;
      end loop;
      i := 0;
      loop
        if i >= d3 then s_axi_bready <= '1'; end if;
        tick;
        exit when s_axi_bvalid = '1' and s_axi_bready = '1';
        i := i + 1;
        assert i < 100000 report "B handshake timeout" severity failure;
      end loop;
      s_axi_bready <= '0';
    end procedure;

    procedure axi_rd(a : std_logic_vector(3 downto 0); variable v : out std_logic_vector(31 downto 0)) is
      variable d1, d2, i : natural;
    begin
      d1 := dly; d2 := dly;
      s_axi_araddr <= a;
      i := 0;
      loop
        if i >= d1 then s_axi_arvalid <= '1'; end if;
        tick;
        exit when s_axi_arvalid = '1' and s_axi_arready = '1';
        i := i + 1;
        assert i < 100000 report "AR handshake timeout" severity failure;
      end loop;
      s_axi_arvalid <= '0';
      i := 0;
      loop
        if i >= d2 then s_axi_rready <= '1'; end if;
        tick;
        exit when s_axi_rvalid = '1' and s_axi_rready = '1';
        i := i + 1;
        assert i < 100000 report "R handshake timeout" severity failure;
      end loop;
      v := s_axi_rdata;
      s_axi_rready <= '0';
    end procedure;

    -- AW and AR in the same cycle, W two cycles later: the read must see the write
    procedure axi_wr_rd(v : std_logic_vector(31 downto 0); variable rv : out std_logic_vector(31 downto 0)) is
      variable aw_ok, w_ok, b_ok, r_ok : boolean := false;
      variable i : natural := 0;
    begin
      s_axi_awaddr <= A_GPO; s_axi_wdata <= v; s_axi_wstrb <= "1111"; s_axi_araddr <= A_GPI;
      s_axi_awvalid <= '1'; s_axi_arvalid <= '1'; s_axi_bready <= '1'; s_axi_rready <= '1';
      while not (b_ok and r_ok) loop
        if i = 2 then s_axi_wvalid <= '1'; end if;
        tick;
        if s_axi_awvalid = '1' and s_axi_awready = '1' then aw_ok := true; s_axi_awvalid <= '0'; end if;
        if s_axi_wvalid = '1' and s_axi_wready = '1' then w_ok := true; s_axi_wvalid <= '0'; end if;
        if s_axi_arvalid = '1' and s_axi_arready = '1' then s_axi_arvalid <= '0'; end if;
        if s_axi_bvalid = '1' and s_axi_bready = '1' then b_ok := true; s_axi_bready <= '0'; end if;
        if s_axi_rvalid = '1' and s_axi_rready = '1' then r_ok := true; rv := s_axi_rdata; s_axi_rready <= '0'; end if;
        i := i + 1;
        assert i < 100000 report "write+read timeout" severity failure;
      end loop;
    end procedure;

    procedure gpo_write(v : std_logic_vector(31 downto 0)) is
    begin
      gpo := v;
      axi_wr(A_GPO, v);
    end procedure;

    procedure expect(sel : std_logic_vector(3 downto 0); wd : std_logic_vector(15 downto 0)) is
    begin
      exp_log(exp_cnt) := sel & wd;
      exp_cnt := exp_cnt + 1;
    end procedure;

    procedure check_log is
    begin
      assert rx_cnt = exp_cnt
        report "strobes " & integer'image(rx_cnt) & ", expected " & integer'image(exp_cnt) severity failure;
      for k in chk_from to exp_cnt - 1 loop
        assert rx_log(k) = exp_log(k)
          report "word " & integer'image(k) & ": got " & to_hstring(rx_log(k)) & ", expected " &
                 to_hstring(exp_log(k)) severity failure;
      end loop;
      chk_from := exp_cnt;
    end procedure;

    -- fpga_spi_en
    procedure spi_en(mask : std_logic_vector(31 downto 0); en : boolean) is
    begin
      if en then
        gpo_write(gpo or x"80000000" or mask);
      else
        gpo_write((gpo or x"80000000") and not mask);
      end if;
    end procedure;

    procedure fpga_spi(wd : std_logic_vector(15 downto 0); sel : std_logic_vector(3 downto 0)) is
      variable n : natural := 0;
    begin
      gpo_write((gpo and not x"0002FFFF") or (x"0000" & wd));
      axi_wr(A_GPO, gpo or STROBE);
      loop
        axi_rd(A_GPI, g);
        assert g(31) = '0' report "GPI(31) = 1 in fpga_spi" severity failure;
        exit when g(17) = '1';
        n := n + 1;
        assert n < 10000 report "no ack" severity failure;
      end loop;
      axi_wr(A_GPO, gpo);
      loop
        axi_rd(A_GPI, g);
        assert g(31) = '0' report "GPI(31) = 1 in fpga_spi" severity failure;
        exit when g(17) = '0';
        n := n + 1;
        assert n < 10000 report "ack stays high" severity failure;
      end loop;
      assert g(15 downto 0) = resp(wd, exp_cnt)
        report "fpga_spi response " & to_hstring(g(15 downto 0)) & ", expected " & to_hstring(resp(wd, exp_cnt))
        severity failure;
      expect(sel, wd);
      n_spi := n_spi + 1;
    end procedure;

    procedure fpga_spi_fast(wd : std_logic_vector(15 downto 0); sel : std_logic_vector(3 downto 0)) is
    begin
      gpo_write((gpo and not x"0002FFFF") or (x"0000" & wd));
      axi_wr(A_GPO, gpo or STROBE);
      axi_wr(A_GPO, gpo);
      axi_rd(A_GPI, g);
      assert g(15 downto 0) = resp(wd, exp_cnt) report "fpga_spi_fast response" severity failure;
      expect(sel, wd);
      n_fast := n_fast + 1;
    end procedure;

    procedure fast_block_write(n : positive; sel : std_logic_vector(3 downto 0)) is
      variable gpo_h : std_logic_vector(31 downto 0);
    begin
      gpo_h := gpo and not x"0002FFFF";
      for k in 1 to n loop
        gpo := gpo_h or (x"0000" & rnd16);
        axi_wr(A_GPO, gpo);
        axi_wr(A_GPO, gpo or STROBE);
        expect(sel, gpo(15 downto 0));
      end loop;
      gpo_write(gpo);
      n_fast := n_fast + n;
    end procedure;

    procedure fast_block_read(n : positive; sel : std_logic_vector(3 downto 0)) is
    begin
      gpo := gpo and not x"0002FFFF";
      for k in 1 to n loop
        axi_wr(A_GPO, gpo or STROBE);
        axi_wr(A_GPO, gpo);
        axi_rd(A_GPI, g);
        assert g(15 downto 0) = resp(x"0000", exp_cnt)
          report "block read word " & integer'image(k) & ": " & to_hstring(g(15 downto 0)) & ", expected " &
                 to_hstring(resp(x"0000", exp_cnt)) severity failure;
        expect(sel, x"0000");
      end loop;
      n_fast := n_fast + n;
    end procedure;

    -- one frame: enable, words, disable
    procedure frame(kind : natural) is
      variable mask : std_logic_vector(31 downto 0);
      variable sel : std_logic_vector(3 downto 0);
      variable n : natural;
    begin
      case kind is
        when 0 => mask := FPGA_EN; sel := SEL_FPGA;                    -- EnableFpga (file I/O)
        when 1 => mask := IO_EN; sel := SEL_IO;                        -- EnableIO (user_io)
        when 2 => mask := OSD_EN; sel := SEL_OSD;                      -- EnableOsd, both targets
        when 3 => mask := OSD_EN or IO_EN; sel := SEL_HDMI;            -- EnableOsd, OSD_HDMI
        when others => mask := OSD_EN or FPGA_EN; sel := SEL_VGA;      -- EnableOsd, OSD_VGA
      end case;
      spi_en(mask, true);
      n := 1 + rnd(6);
      for k in 1 to n loop
        if kind = 1 and rnd(3) = 0 then
          fpga_spi_fast(rnd16, sel);
        else
          fpga_spi(rnd16, sel);
        end if;
      end loop;
      if kind = 1 and rnd(4) = 0 then
        if rnd(2) = 0 then
          fast_block_write(1 + rnd(40), sel);
        else
          fast_block_read(1 + rnd(40), sel);
        end if;
      end if;
      if kind >= 2 then
        spi_en(OSD_EN or IO_EN or FPGA_EN, false);                     -- DisableOsd
      else
        spi_en(mask, false);
      end if;
      check_log;
      n_frames := n_frames + 1;
    end procedure;

    procedure sys_mode(period : time; stall : natural) is
    begin
      sys_period <= period;
      sys_stall  <= stall;
      wait for 2 us;
    end procedure;

  begin
    aresetn <= '0';
    tick(20);
    aresetn <= '1';
    tick(5);

    -- registers without side effects
    axi_rd(A_ID, g);
    assert g = x"5A4D5354" report "ID " & to_hstring(g) severity failure;
    axi_rd(A_STA, g);
    assert g = x"00000000" report "STATUS after reset " & to_hstring(g) severity failure;
    assert reset_req = '0' report "reset request after aresetn" severity failure;
    assert quiesce = '0' report "quiesce after aresetn" severity failure;

    -- CTRL (write to STATUS): quiesce request, idle back in STATUS bit 2, GPO untouched
    axi_wr(A_STA, x"00000001");
    assert quiesce = '1' report "CTRL bit 0 did not set quiesce" severity failure;
    axi_rd(A_STA, g);
    assert g = x"00000008" report "STATUS with quiesce, not idle " & to_hstring(g) severity failure;
    hp_idle <= '1';
    tick(3);
    axi_rd(A_STA, g);
    assert g = x"0000000C" report "STATUS with quiesce and idle " & to_hstring(g) severity failure;
    axi_rd(A_GPO, g);
    assert g = x"00000000" report "CTRL write changed GPO " & to_hstring(g) severity failure;
    axi_wr(A_STA, x"00000000");
    hp_idle <= '0';
    tick(3);
    assert quiesce = '0' report "CTRL bit 0 = 0 did not clear quiesce" severity failure;
    axi_rd(A_STA, g);
    assert g = x"00000000" report "STATUS after quiesce " & to_hstring(g) severity failure;

    -- core load by the old Main: fpga_core_reset(1)
    gpo_write((gpo and x"3FFFFFFF") or x"40000000");
    tick(5);
    assert reset_req = '1' report "fpga_core_reset(1) did not request the reset" severity failure;
    -- 01 -> 10 directly does not release it
    gpo_write((gpo and x"3FFFFFFF") or x"80000000");
    tick(5);
    assert reset_req = '1' report "reset released by 01 -> 10" severity failure;
    -- new Main: fpga_io_init writes 0, fpga_core_id reads the magic and sets bit 31
    gpo_write(x"00000000");
    tick(5);
    assert reset_req = '1' report "reset released by 00" severity failure;
    gpo_write(gpo and x"7FFFFFFF");
    axi_rd(A_GPI, g);
    assert g = C_MAGIC report "core magic " & to_hstring(g) severity failure;
    gpo_write(gpo or x"80000000");
    tick(5);
    assert reset_req = '0' report "00 -> 10 did not release the reset" severity failure;
    -- reset_in (reset button) sets it as well
    reset_in <= '1'; tick; reset_in <= '0'; tick(3);
    assert reset_req = '1' report "reset_in ignored" severity failure;
    gpo_write(x"00000000"); tick(3);
    gpo_write(x"80000000"); tick(3);
    assert reset_req = '0' report "reset after reset_in not released" severity failure;

    -- LED and GPO readback
    gpo_write(gpo or x"20000000"); tick(2);
    assert led_disk = '1' report "LED on" severity failure;
    axi_rd(A_GPO, g);
    assert g = gpo report "GPO readback " & to_hstring(g) severity failure;
    gpo_write(gpo and not x"20000000"); tick(2);
    assert led_disk = '0' report "LED off" severity failure;

    -- GPI layout with the asynchronous inputs
    for k in 0 to 15 loop
      b := std_logic_vector(to_unsigned(k, 4));
      btn_osd <= b(0); btn_user <= b(1); io_dig <= b(2); hdmi_int <= b(3);
      wait for 300 ns;
      axi_rd(A_GPI, g);
      e := '0' & b(1) & b(0) & b(2) & "0000000" & b(3) & "01" & '0' & '1' & x"0000";
      assert g(31 downto 16) = e(31 downto 16)
        report "GPI " & to_hstring(g) & ", expected " & to_hstring(e(31 downto 16)) & "xxxx" severity failure;
    end loop;
    btn_osd <= '0'; btn_user <= '0'; io_dig <= '0'; hdmi_int <= '0';

    -- transfers at every clk_sys mode
    for m in 0 to 3 loop
      case m is
        when 0 => sys_mode(46.5 ns, 0);        -- MSX clk_sys 21.5 MHz
        when 1 => sys_mode(44.4 ns, 30);       -- gated stage C clk_sys with stalls
        when 2 => sys_mode(6.6 ns, 0);         -- faster than aclk
        when others => sys_mode(200 ns, 10);   -- slow, with stalls
      end case;
      for f in 1 to 40 loop
        frame(rnd(5));
      end loop;
      -- SD sector: user_io frame with block transfers of 256 words
      spi_en(IO_EN, true);
      fpga_spi(x"0017", SEL_IO);
      fast_block_write(256, SEL_IO);
      fast_block_read(256, SEL_IO);
      spi_en(IO_EN, false);
      check_log;
      -- a GPI read that overtakes a GPO write must see the write
      axi_wr_rd(gpo and x"7FFFFFFF", g);
      gpo := gpo and x"7FFFFFFF";
      assert g = C_MAGIC report "read before the write: " & to_hstring(g) severity failure;
      axi_wr_rd(gpo or x"80000000", g);
      gpo := gpo or x"80000000";
      assert g(31) = '0' and g(19 downto 18) = "01" report "read before the write (2): " & to_hstring(g)
        severity failure;
      report "mode " & integer'image(m) & " checked: " & integer'image(exp_cnt) & " words so far";
    end loop;

    -- clk_sys stopped
    sys_mode(46.5 ns, 0);
    sys_run <= false;
    wait for 1 us;
    t0 := now;
    gpo_write((gpo and not x"0002FFFF") or x"00001234");
    assert now - t0 >= C_TIMEOUT * C_ACLK report "write ended before the timeout" severity failure;
    axi_rd(A_STA, g);
    assert g(1 downto 0) = "11" report "STATUS while stopped " & to_hstring(g) severity failure;
    t0 := now;
    axi_rd(A_GPI, g);
    assert g = x"FFFFFFFF" report "GPI while stopped " & to_hstring(g) severity failure;
    assert now - t0 < 20 * C_ACLK report "GPI read while behind waited" severity failure;
    t0 := now;
    axi_wr(A_GPO, (gpo and not x"0002FFFF") or x"00005678");     -- dropped
    assert now - t0 < 20 * C_ACLK report "GPO write while behind waited" severity failure;
    sys_run <= true;
    wait for 2 us;
    axi_rd(A_STA, g);
    assert g(1 downto 0) = "01" report "STATUS after resume " & to_hstring(g) severity failure;
    assert io_din = x"1234" report "after resume io_din " & to_hstring(io_din) severity failure;
    axi_wr(A_GPO, gpo);                                            -- Main writes its copy again
    spi_en(FPGA_EN, true);
    fpga_spi(x"00A5", SEL_FPGA);
    spi_en(FPGA_EN, false);
    check_log;

    report "PASS: " & integer'image(n_frames) & " frames, " & integer'image(n_spi) & " fpga_spi, " &
           integer'image(n_fast) & " fast words, " & integer'image(exp_cnt) & " strobes";
    done <= true;
    wait;
  end process;

end architecture tb;

-- the register-only mode (G_RAW) with the sys_top.v model, as its own bench for the Makefile
entity hps_bus_axi_raw_tb is
end entity;

architecture tb of hps_bus_axi_raw_tb is
begin
  raw : entity work.hps_bus_axi_tb generic map (G_RAW => true);
end architecture tb;
