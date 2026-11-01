-------------------------------------------------------------------------------
-- Title      : Testbench of sdram_emu with the BRAM back end (stage B)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : sdram_emu_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   A random SDRAM controller ("core") drives ACTIVE, READ, WRITE, PRECHARGE,
--   BURST TERMINATE, REFRESH and MODE REGISTER SET: burst lengths 1/2/4/8,
--   sequential and interleaved, CAS latency 2 and 3, write burst mode, DQM byte
--   masks, bursts interrupted by new commands.  An independent reference model
--   gives every read beat its expected word; it is checked at the edge a core
--   with G_RD_ADJ = 0 samples (CL + 1 edges after the cycle of the beat, e.g.
--   the MSX core).  Ends with "PASS" or a failure; err_late/err_mode must stay 0.
--   VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity sdram_emu_tb is
  generic (
    G_CYCLES : natural := 200000;
    G_SEED   : positive := 11
  );
end entity;

architecture tb of sdram_emu_tb is

  constant BANK_BITS : natural := 2;
  constant ROW_BITS  : natural := 4;
  constant COL_BITS  : natural := 5;
  constant ADDR_BITS : natural := BANK_BITS + ROW_BITS + COL_BITS;

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal done : boolean := false;

  signal cs_n, ras_n, cas_n, we_n : std_logic := '1';
  signal ba    : std_logic_vector(BANK_BITS - 1 downto 0) := (others => '0');
  signal a     : std_logic_vector(12 downto 0) := (others => '0');
  signal dqm   : std_logic_vector(1 downto 0) := "00";
  signal dq_i  : std_logic_vector(15 downto 0) := (others => '0');
  signal dq_o  : std_logic_vector(15 downto 0);
  signal dq_oe : std_logic;

  signal be_req, be_we, be_ready, be_rvalid : std_logic;
  signal be_addr  : std_logic_vector(ADDR_BITS - 1 downto 0);
  signal be_wdata, be_rdata : std_logic_vector(15 downto 0);
  signal be_wstrb : std_logic_vector(1 downto 0);
  signal stall, err_late, err_mode : std_logic;

begin

  clk <= not clk after 5 ns when not done;

  dut : entity work.sdram_emu
    generic map (G_BANK_BITS => BANK_BITS, G_ROW_BITS => ROW_BITS, G_COL_BITS => COL_BITS, G_RD_ADJ => 0)
    port map (
      clk => clk, rst => rst, ce => '1',
      sd_cs_n => cs_n, sd_ras_n => ras_n, sd_cas_n => cas_n, sd_we_n => we_n, sd_ba => ba, sd_a => a,
      sd_dqm => dqm, sd_dq_i => dq_i, sd_dq_o => dq_o, sd_dq_oe => dq_oe,
      be_req => be_req, be_we => be_we, be_addr => be_addr, be_wdata => be_wdata, be_wstrb => be_wstrb,
      be_ready => be_ready, be_rvalid => be_rvalid, be_rdata => be_rdata,
      stall => stall, err_late => err_late, err_mode => err_mode);

  mem : entity work.sdram_bram
    generic map (G_ADDR_BITS => ADDR_BITS)
    port map (clk => clk, req => be_req, we => be_we, addr => be_addr, wdata => be_wdata, wstrb => be_wstrb,
              ready => be_ready, rvalid => be_rvalid, rdata => be_rdata);

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
    rst <= '1';
    for i in 1 to 4 loop wait until rising_edge(clk); end loop;
    rst <= '0';

    while n < G_CYCLES loop
      wait until rising_edge(clk);
      n := n + 1;
      -- this edge ends cycle n - 1: the core samples a due read beat
      if exp_v((n - 1) mod 64) = '1' then
        assert dq_o = exp_d((n - 1) mod 64)
          report "cycle " & integer'image(n - 1) & ": read " & to_hstring(dq_o) & " expected " &
                 to_hstring(exp_d((n - 1) mod 64)) severity failure;
        exp_v((n - 1) mod 64) := '0';
        checked := checked + 1;
      end if;
      assert err_late = '0' and err_mode = '0' report "emulator error flag" severity failure;

      -- the command of cycle n
      cmd("0111"); ba <= (others => '0'); a <= (others => '0'); dqm <= "00"; dq_i <= (others => 'X');
      new_rw := false; term := false;
      kind := rnd(100);
      if kind < 40 then
        null;                                                   -- NOP
      elsif kind < 70 then
        bank := rnd(2 ** BANK_BITS);
        if row_ok(bank) = '0' then
          row_of(bank) := rnd(2 ** ROW_BITS); row_ok(bank) := '1';
          cmd("0011"); ba <= std_logic_vector(to_unsigned(bank, BANK_BITS));
          a <= std_logic_vector(to_unsigned(row_of(bank), 13));
        else
          col := rnd(2 ** COL_BITS);
          rw_we := rnd(2) = 0;
          if rw_we then cmd("0100"); else cmd("0101"); end if;
          ba <= std_logic_vector(to_unsigned(bank, BANK_BITS));
          a  <= std_logic_vector(to_unsigned(col, 13)) or "0010000000000";   -- A10 (auto precharge) is ignored
          new_rw := true;
          b_on := true; b_we := rw_we; b_bank := bank; b_row := row_of(bank); b_col := col; b_cnt := 0;
          if rw_we and single_wr then b_len := 1; else b_len := bl; end if;
        end if;
      elsif kind < 80 then
        bank := rnd(2 ** BANK_BITS);                            -- ACTIVE (a new row, open burst keeps its row)
        row_of(bank) := rnd(2 ** ROW_BITS); row_ok(bank) := '1';
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

    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    assert err_late = '0' and err_mode = '0' report "emulator error flag" severity failure;
    report "PASS: " & integer'image(n) & " cycles, " & integer'image(checked) & " read beats checked, " &
           integer'image(writes) & " write beats, " & integer'image(mrs_cnt) & " mode changes";
    done <= true;
    wait;
  end process;

  timeout : process
  begin
    wait for 50 ms;
    assert done report "timeout" severity failure;
    wait;
  end process;

end architecture tb;
