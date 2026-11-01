-------------------------------------------------------------------------------
-- Title      : Testbench of the PSX savestates replacement (reset sequence only)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : psx_savestates_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-31
-------------------------------------------------------------------------------
-- Description:
--   cores/psx/savestates.vhd against the original rtl/savestates.vhd of
--   PSX_MiSTer (copied as savestates_orig by the Makefile), both driven with
--   the same random inputs, save = load = '0' (savestates off in the profile).
--   clk1x 20 ns, clk2x 10 ns phase-locked, clk2xIndex generated as in
--   rtl/psx_top.vhd.  The inputs change at the falling edge of clk2x:
--     ddr3_BUSY in random runs (half of the time '1', so a read request can
--     outlast its data), ddr3_DOUT_READY, sdram_done, SS_SPURAM_done, ram_done
--     and all data inputs per cycle; ddr3_DOUT(63:32) half of the time STATESIZE (a
--     valid header); system_paused, SS_idle, useSPUSDRAM, savestate_number,
--     savestate_address in random phases of 1..3000 cycles (so the
--     unstallwait re-reset of WAITPAUSE and the WAITIDLE retry happen);
--     loadExe as rare single pulses (EXE mode: main RAM is not cleared).
--   reset_in: G_FASTSIM '0' runs one full reset mode load (scratchpad, SPU
--   RAM, VRAM, main RAM, ~5 M clk2x cycles), then an EXE download and a reset
--   that is cut short by a second reset, then a full one in EXE mode;
--   G_FASTSIM '1' (psx_savestates_fast_tb: scratchpad only) a reset pulse at
--   random times (about every 20 000 cycles, often inside a sequence).
--   Every output of both entities is compared at every clk2x edge (+1 ns)
--   from the 10th cycle on.  Coverage counted and required at the end: reset
--   and ss_reset pulses, SS_wren of scratchpad and main RAM, SPU RAM requests,
--   DDR writes and reads, a valid header bit, completed sequences, re-resets
--   from unstallwait.  Ends with "PASS" or a failure.  VHDL-2008.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity psx_savestates_tb is
  generic (
    G_FASTSIM : std_logic := '0'
  );
end entity;

architecture tb of psx_savestates_tb is
  constant T2       : time := 10 ns;
  constant SSCOUNT  : integer := 17;
  constant SOFTMAP  : integer := 58720256;
  constant STATESIZE : integer := 1048574;

  signal clk1x, clk2x : std_logic := '0';
  signal clk2xIndex   : std_logic := '0';
  signal clk1xToggle, clk1xToggle2x : std_logic := '0';
  signal cyc          : natural := 0;
  signal done         : boolean := false;

  -- inputs
  signal reset_in, hps_busy, loadExe, incr, SS_idle, system_paused, useSPUSDRAM : std_logic := '0';
  signal sdram_done, ddr3_BUSY, ddr3_DOUT_READY, ram_done, SS_SPURAM_done : std_logic := '0';
  signal savestate_number  : integer range 0 to 3 := 0;
  signal savestate_address : integer := SOFTMAP;
  signal ddr3_DOUT         : std_logic_vector(63 downto 0) := (others => '0');
  signal ram_data          : std_logic_vector(31 downto 0) := (others => '0');
  signal SS_SPURAM_dataRead : std_logic_vector(15 downto 0) := (others => '0');
  type rd_t is array (0 to 13) of std_logic_vector(31 downto 0);
  signal rd : rd_t := (others => (others => '0'));

  -- outputs of both (index 0 original, 1 replacement)
  type sl2   is array (0 to 1) of std_logic;
  type v4    is array (0 to 1) of std_logic_vector(3 downto 0);
  type v8    is array (0 to 1) of std_logic_vector(7 downto 0);
  type v16   is array (0 to 1) of std_logic_vector(15 downto 0);
  type v19   is array (0 to 1) of std_logic_vector(18 downto 0);
  type u19   is array (0 to 1) of unsigned(18 downto 0);
  type v26   is array (0 to 1) of std_logic_vector(25 downto 0);
  type v32   is array (0 to 1) of std_logic_vector(31 downto 0);
  type v64   is array (0 to 1) of std_logic_vector(63 downto 0);
  type vss   is array (0 to 1) of std_logic_vector(SSCOUNT - 1 downto 0);
  signal reset_out, ss_reset, load_done, busy, ss_pause, ddr3_ss, loading, saving : sl2;
  signal ddr3_WE, ddr3_RD, spu_req, spu_rnw : sl2;
  signal valid : v4;
  signal ddr3_BURSTCNT, ddr3_BE : v8;
  signal spu_dw : v16;
  signal spu_adr : v19;
  signal ss_adr : u19;
  signal ddr3_ADDR : v26;
  signal ss_dw : v32;
  signal ddr3_DIN : v64;
  signal ss_wren, ss_rden : vss;

  -- coverage
  signal n_reset, n_ssreset, n_wren12, n_wren16, n_spu, n_we, n_rd, n_valid, n_seq, n_rereset : natural := 0;
begin

  clk2x <= not clk2x after T2 / 2 when not done;

  process (clk2x)
  begin
    if rising_edge(clk2x) then
      cyc <= cyc + 1;
      clk1x <= not clk1x;                          -- clk1x: every other clk2x edge, same edges
    end if;
  end process;

  -- clk2xIndex as rtl/psx_top.vhd
  process (clk1x)
  begin
    if rising_edge(clk1x) then
      clk1xToggle <= not clk1xToggle;
    end if;
  end process;
  process (clk2x)
  begin
    if rising_edge(clk2x) then
      clk1xToggle2x <= clk1xToggle;
      clk2xIndex    <= '0';
      if clk1xToggle2x = clk1xToggle then
        clk2xIndex <= '1';
      end if;
    end if;
  end process;

  duts : for i in 0 to 1 generate
    orig : if i = 0 generate
      dut : entity work.savestates_orig
        generic map (FASTSIM => G_FASTSIM, Softmap_SaveState_ADDR => SOFTMAP)
        port map (
          clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, ce => '1', reset_in => reset_in,
          reset_out => reset_out(i), ss_reset => ss_reset(i), hps_busy => hps_busy, loadExe => loadExe,
          load_done => load_done(i), validSStates => valid(i), savestate_number => savestate_number,
          increaseSSHeaderCount => incr, save => '0', load => '0', savestate_address => savestate_address,
          savestate_busy => busy(i), SS_idle => SS_idle, system_paused => system_paused,
          savestate_pause => ss_pause(i), ddr3_savestate => ddr3_ss(i), useSPUSDRAM => useSPUSDRAM,
          SS_DataWrite => ss_dw(i), SS_Adr => ss_adr(i), SS_wren => ss_wren(i), SS_rden => ss_rden(i),
          SS_DataRead_CPU => rd(0), SS_DataRead_GPU => rd(1), SS_DataRead_GPUTiming => rd(2),
          SS_DataRead_DMA => rd(3), SS_DataRead_GTE => rd(4), SS_DataRead_JOYPAD => rd(5),
          SS_DataRead_MDEC => rd(6), SS_DataRead_MEMORY => rd(7), SS_DataRead_TIMER => rd(8),
          SS_DataRead_SOUND => rd(9), SS_DataRead_IRQ => rd(10), SS_DataRead_SIO => rd(11),
          SS_DataRead_SCP => rd(12), SS_DataRead_CD => rd(13), sdram_done => sdram_done,
          loading_savestate => loading(i), saving_savestate => saving(i), ddr3_BUSY => ddr3_BUSY,
          ddr3_DOUT => ddr3_DOUT, ddr3_DOUT_READY => ddr3_DOUT_READY, ddr3_BURSTCNT => ddr3_BURSTCNT(i),
          ddr3_ADDR => ddr3_ADDR(i), ddr3_DIN => ddr3_DIN(i), ddr3_BE => ddr3_BE(i), ddr3_WE => ddr3_WE(i),
          ddr3_RD => ddr3_RD(i), ram_done => ram_done, ram_data => ram_data,
          SS_SPURAM_dataWrite => spu_dw(i), SS_SPURAM_Adr => spu_adr(i), SS_SPURAM_request => spu_req(i),
          SS_SPURAM_rnw => spu_rnw(i), SS_SPURAM_dataRead => SS_SPURAM_dataRead,
          SS_SPURAM_done => SS_SPURAM_done);
    end generate;
    repl : if i = 1 generate
      dut : entity work.savestates
        generic map (FASTSIM => G_FASTSIM, Softmap_SaveState_ADDR => SOFTMAP)
        port map (
          clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, ce => '1', reset_in => reset_in,
          reset_out => reset_out(i), ss_reset => ss_reset(i), hps_busy => hps_busy, loadExe => loadExe,
          load_done => load_done(i), validSStates => valid(i), savestate_number => savestate_number,
          increaseSSHeaderCount => incr, save => '0', load => '0', savestate_address => savestate_address,
          savestate_busy => busy(i), SS_idle => SS_idle, system_paused => system_paused,
          savestate_pause => ss_pause(i), ddr3_savestate => ddr3_ss(i), useSPUSDRAM => useSPUSDRAM,
          SS_DataWrite => ss_dw(i), SS_Adr => ss_adr(i), SS_wren => ss_wren(i), SS_rden => ss_rden(i),
          SS_DataRead_CPU => rd(0), SS_DataRead_GPU => rd(1), SS_DataRead_GPUTiming => rd(2),
          SS_DataRead_DMA => rd(3), SS_DataRead_GTE => rd(4), SS_DataRead_JOYPAD => rd(5),
          SS_DataRead_MDEC => rd(6), SS_DataRead_MEMORY => rd(7), SS_DataRead_TIMER => rd(8),
          SS_DataRead_SOUND => rd(9), SS_DataRead_IRQ => rd(10), SS_DataRead_SIO => rd(11),
          SS_DataRead_SCP => rd(12), SS_DataRead_CD => rd(13), sdram_done => sdram_done,
          loading_savestate => loading(i), saving_savestate => saving(i), ddr3_BUSY => ddr3_BUSY,
          ddr3_DOUT => ddr3_DOUT, ddr3_DOUT_READY => ddr3_DOUT_READY, ddr3_BURSTCNT => ddr3_BURSTCNT(i),
          ddr3_ADDR => ddr3_ADDR(i), ddr3_DIN => ddr3_DIN(i), ddr3_BE => ddr3_BE(i), ddr3_WE => ddr3_WE(i),
          ddr3_RD => ddr3_RD(i), ram_done => ram_done, ram_data => ram_data,
          SS_SPURAM_dataWrite => spu_dw(i), SS_SPURAM_Adr => spu_adr(i), SS_SPURAM_request => spu_req(i),
          SS_SPURAM_rnw => spu_rnw(i), SS_SPURAM_dataRead => SS_SPURAM_dataRead,
          SS_SPURAM_done => SS_SPURAM_done);
    end generate;
  end generate;

  -- random inputs at the falling edge of clk2x
  stim : process
    variable s1, s2 : positive := 7;
    variable phase_p, phase_i, phase_u, phase_a : integer := 0;
    variable busy_v : std_logic := '0';
    impure function rnd return real is
      variable r : real;
    begin
      uniform(s1, s2, r);
      return r;
    end function;
    impure function bit_p(p : real) return std_logic is
    begin
      if rnd < p then return '1'; else return '0'; end if;
    end function;
    impure function slv(n : positive) return std_logic_vector is   -- n a multiple of 16
      variable v : std_logic_vector(n - 1 downto 0);
    begin
      for k in 0 to n / 16 - 1 loop
        v(16 * k + 15 downto 16 * k) := std_logic_vector(to_unsigned(integer(trunc(rnd * 65535.99)), 16));
      end loop;
      return v;
    end function;
  begin
    wait until falling_edge(clk2x);
    loop
      if rnd < 0.25 then busy_v := not busy_v; end if;   -- runs of 4 cycles on average
      ddr3_BUSY       <= busy_v;
      ddr3_DOUT_READY <= bit_p(0.3);
      sdram_done      <= bit_p(0.5);
      SS_SPURAM_done  <= bit_p(0.3);
      ram_done        <= bit_p(0.5);
      hps_busy        <= bit_p(0.5);
      incr            <= bit_p(0.5);
      ddr3_DOUT(31 downto 0) <= slv(32);
      if rnd < 0.5 then
        ddr3_DOUT(63 downto 32) <= std_logic_vector(to_unsigned(STATESIZE, 32));
      else
        ddr3_DOUT(63 downto 32) <= slv(32);
      end if;
      ram_data           <= slv(32);
      SS_SPURAM_dataRead <= slv(16);
      rd(integer(trunc(rnd * 13.99))) <= slv(32);
      loadExe <= bit_p(0.00001);
      -- slow inputs: a new value at the end of a random phase
      if phase_p = 0 then
        system_paused <= bit_p(0.6);
        phase_p := integer(trunc(rnd * 3000.0)) + 1;
      end if;
      if phase_i = 0 then
        SS_idle <= bit_p(0.7);
        phase_i := integer(trunc(rnd * 3000.0)) + 1;
      end if;
      if phase_u = 0 then
        useSPUSDRAM <= bit_p(0.3);
        phase_u := integer(trunc(rnd * 300000.0)) + 1;
      end if;
      if phase_a = 0 then
        savestate_number  <= integer(trunc(rnd * 3.99));
        savestate_address <= SOFTMAP + integer(trunc(rnd * 4.0)) * 16#100000#;
        phase_a := integer(trunc(rnd * 50000.0)) + 1;
      end if;
      phase_p := phase_p - 1;
      phase_i := phase_i - 1;
      phase_u := phase_u - 1;
      phase_a := phase_a - 1;
      exit when done;
      wait until falling_edge(clk2x);
    end loop;
    wait;
  end process;

  -- reset_in sequence
  rst : process
    variable s1, s2 : positive := 11;
    variable r : real;
    procedure pulse(n : positive) is
    begin
      wait until falling_edge(clk2x);
      reset_in <= '1';
      for k in 1 to n loop
        wait until falling_edge(clk2x);
      end loop;
      reset_in <= '0';
    end procedure;
    procedure wait_idle is
    begin
      wait until busy(0) = '1' for 1 ms;
      wait until busy(0) = '0' for 200 ms;
      assert busy(0) = '0' report "reset sequence did not end" severity failure;
    end procedure;
  begin
    for k in 1 to 20 loop
      wait until falling_edge(clk2x);
    end loop;
    if G_FASTSIM = '0' then
      pulse(50);
      wait_idle;                                     -- full load (exeMode depends on loadExe pulses)
      wait until falling_edge(clk2x);
      loadExe <= '1' after 1 ns;                     -- force EXE mode (stim overwrites it next cycle)
      pulse(5);
      wait for 300 us;                               -- cut short by the next reset
      pulse(5);
      wait_idle;
    else
      for k in 1 to 100 loop
        uniform(s1, s2, r);
        wait for T2 * integer(trunc(r * 40000.0));
        pulse(integer(trunc(r * 30.0)) + 1);
      end loop;
      wait_idle;
    end if;
    for k in 1 to 100 loop
      wait until falling_edge(clk2x);
    end loop;
    done <= true;
    wait;
  end process;

  -- compare every output after each clk2x edge
  cmp : process
    variable busy_1 : std_logic := '0';
    procedure chk(ok : boolean; what : string) is
    begin
      assert ok report what & " differs at cycle " & integer'image(cyc) severity failure;
    end procedure;
  begin
    wait until rising_edge(clk2x);
    wait for 1 ns;
    if cyc >= 10 then
      chk(reset_out(0) = reset_out(1), "reset_out");
      chk(ss_reset(0) = ss_reset(1), "ss_reset");
      chk(load_done(0) = load_done(1), "load_done");
      chk(valid(0) = valid(1), "validSStates");
      chk(busy(0) = busy(1), "savestate_busy");
      chk(ss_pause(0) = ss_pause(1), "savestate_pause");
      chk(ddr3_ss(0) = ddr3_ss(1), "ddr3_savestate");
      chk(loading(0) = loading(1), "loading_savestate");
      chk(saving(0) = saving(1), "saving_savestate");
      chk(ddr3_WE(0) = ddr3_WE(1), "ddr3_WE");
      chk(ddr3_RD(0) = ddr3_RD(1), "ddr3_RD");
      chk(spu_req(0) = spu_req(1), "SS_SPURAM_request");
      chk(spu_rnw(0) = spu_rnw(1), "SS_SPURAM_rnw");
      chk(ddr3_BURSTCNT(0) = ddr3_BURSTCNT(1), "ddr3_BURSTCNT");
      chk(ddr3_BE(0) = ddr3_BE(1), "ddr3_BE");
      chk(spu_dw(0) = spu_dw(1), "SS_SPURAM_dataWrite");
      chk(spu_adr(0) = spu_adr(1), "SS_SPURAM_Adr");
      chk(ss_adr(0) = ss_adr(1), "SS_Adr");
      chk(ddr3_ADDR(0) = ddr3_ADDR(1), "ddr3_ADDR");
      chk(ss_dw(0) = ss_dw(1), "SS_DataWrite");
      chk(ddr3_DIN(0) = ddr3_DIN(1), "ddr3_DIN");
      chk(ss_wren(0) = ss_wren(1), "SS_wren");
      chk(ss_rden(0) = ss_rden(1), "SS_rden");
    end if;
    -- coverage (original's outputs; equal anyway)
    if reset_out(0) = '1' then n_reset <= n_reset + 1; end if;
    if ss_reset(0) = '1' then n_ssreset <= n_ssreset + 1; end if;
    -- re-reset of WAITPAUSE (unstallwait ran out): ss_reset with the pause on, before the load
    if ss_reset(0) = '1' and ss_pause(0) = '1' and ddr3_ss(0) = '0' then n_rereset <= n_rereset + 1; end if;
    if ss_wren(0)(12) = '1' then n_wren12 <= n_wren12 + 1; end if;
    if ss_wren(0)(16) = '1' then n_wren16 <= n_wren16 + 1; end if;
    if spu_req(0) = '1' then n_spu <= n_spu + 1; end if;
    if ddr3_WE(0) = '1' then n_we <= n_we + 1; end if;
    if ddr3_RD(0) = '1' then n_rd <= n_rd + 1; end if;
    if valid(0) /= "0000" then n_valid <= n_valid + 1; end if;
    if busy_1 = '1' and busy(0) = '0' then n_seq <= n_seq + 1; end if;
    busy_1 := busy(0);
    if done then
      wait;
    end if;
  end process;

  fin : process
  begin
    wait until done;
    report "coverage: reset_out " & integer'image(n_reset) & ", ss_reset " & integer'image(n_ssreset) &
           ", wren12 " & integer'image(n_wren12) & ", wren16 " & integer'image(n_wren16) &
           ", spu " & integer'image(n_spu) & ", ddr3 WE " & integer'image(n_we) & ", RD " & integer'image(n_rd) &
           ", valid " & integer'image(n_valid) & ", sequences " & integer'image(n_seq) &
           ", re-resets " & integer'image(n_rereset);
    assert n_reset >= 3 and n_ssreset >= 2 and n_wren12 > 0 and n_rd >= 4 and n_valid > 0 and n_seq >= 2 and
           n_rereset > 0
      report "coverage too low" severity failure;
    if G_FASTSIM = '0' then
      assert n_wren16 > 0 and n_spu > 0 and n_we > 0 report "coverage too low (full load)" severity failure;
    end if;
    report "PASS";
    std.env.finish;
    wait;
  end process;

end architecture tb;

library ieee;
use ieee.std_logic_1164.all;

entity psx_savestates_fast_tb is
end entity;

architecture tb of psx_savestates_fast_tb is
begin
  b : entity work.psx_savestates_tb generic map (G_FASTSIM => '1');
end architecture tb;
