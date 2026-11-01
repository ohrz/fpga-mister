-------------------------------------------------------------------------------
-- Title      : Testbench of the altsyncram replacement
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : altsyncram_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Two configurations as sys/sd_card.sv uses them: 8/8 bit (WIDE = 0) and
--   16/8 bit mixed width (WIDE = 1), BIDIR_DUAL_PORT, two clocks, unregistered
--   outputs, all generics set as defparams in sd_card.sv.  A checker drives the
--   two clocks itself and uses one port per step (no collisions, which are
--   undefined): random reads and writes on both ports against a reference in
--   words of the narrow port.  Checks the read data one clock after the address,
--   new data on a write, little endian placement of the narrow words in the
--   wide word, and that q keeps its value while its clock does not run.
--   Two more configurations as SNES rtl/bram.vhd uses them, with the contents
--   from a .mem file (run directory: this directory): SINGLE_PORT 12 bit with
--   numwords 6 of 8 (port B generics left at their defaults) and a 16/8 bit
--   BIDIR_DUAL_PORT; both with clock enables (NORMAL).  Checks the initial
--   contents (missing words 0, narrow words little endian), that a port with
--   clocken low neither writes nor changes q, and that it works again after.
--   A fifth configuration as N64 rtl/dpram.vhd dpram_dif_be (RSP IMEM) uses
--   it: 64/32 bit mixed width with byte enables (8 and 4 bits, byte_size 8),
--   random byte enables on every write of both ports: only enabled bytes
--   change, the read of the written word shows them new and the others old;
--   a sixth one the other way round (16/64 bit, narrow port A), as the banked
--   byte-write RAM selects the bank of the narrow port by its low address bits,
--   and 32/32 bit with byte enables (one bank).
--   After every read a new address without a clock edge must leave q as it is.
--   Ends with "PASS" or a failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity altsyncram_check is
  generic (
    WA, AA, WB, AB : positive;
    STEPS          : natural;
    SEED           : positive;
    BE             : boolean := false             -- byte enables (one per 8 bits)
  );
  port (done : out boolean := false);
end entity;

architecture tb of altsyncram_check is
  function be_width(w : positive) return positive is
  begin
    if BE then return w / 8; else return 1; end if;
  end function;
  constant BWA : positive := be_width(WA);
  constant BWB : positive := be_width(WB);
  signal byteena_a : std_logic_vector(BWA - 1 downto 0) := (others => '1');
  signal byteena_b : std_logic_vector(BWB - 1 downto 0) := (others => '1');
  signal clock0, clock1 : std_logic := '0';
  signal address_a : std_logic_vector(AA - 1 downto 0) := (others => '0');
  signal address_b : std_logic_vector(AB - 1 downto 0) := (others => '0');
  signal data_a, q_a : std_logic_vector(WA - 1 downto 0);
  signal data_b, q_b : std_logic_vector(WB - 1 downto 0);
  signal wren_a, wren_b : std_logic := '0';
begin

  dut : entity work.altsyncram
    generic map (
      numwords_a => 2 ** AA, widthad_a => AA, width_a => WA,
      numwords_b => 2 ** AB, widthad_b => AB, width_b => WB,
      address_reg_b => "CLOCK1", clock_enable_input_a => "BYPASS", clock_enable_input_b => "BYPASS",
      clock_enable_output_a => "BYPASS", clock_enable_output_b => "BYPASS", indata_reg_b => "CLOCK1",
      intended_device_family => "Cyclone V", lpm_type => "altsyncram", operation_mode => "BIDIR_DUAL_PORT",
      outdata_aclr_a => "NONE", outdata_aclr_b => "NONE", outdata_reg_a => "UNREGISTERED",
      outdata_reg_b => "UNREGISTERED", power_up_uninitialized => "FALSE",
      read_during_write_mode_port_a => "NEW_DATA_NO_NBE_READ",
      read_during_write_mode_port_b => "NEW_DATA_NO_NBE_READ",
      width_byteena_a => BWA, width_byteena_b => BWB, byte_size => 8, wrcontrol_wraddress_reg_b => "CLOCK1")
    port map (
      clock0 => clock0, address_a => address_a, data_a => data_a, wren_a => wren_a, q_a => q_a,
      clock1 => clock1, address_b => address_b, data_b => data_b, wren_b => wren_b, q_b => q_b,
      aclr0 => '0', aclr1 => '0', addressstall_a => '0', addressstall_b => '0',
      byteena_a => byteena_a, byteena_b => byteena_b, clocken0 => '1', clocken1 => '1', clocken2 => '1', clocken3 => '1',
      eccstatus => open, rden_a => '1', rden_b => '1');

  process
    function narrow return positive is
    begin
      if BE then return 8; else return minimum(WA, WB); end if;
    end function;
    constant NW : positive := narrow;
    constant RA : positive := WA / NW;
    constant RB : positive := WB / NW;
    type ref_t is array (0 to 2 ** AA * RA - 1) of std_logic_vector(NW - 1 downto 0);
    variable ref : ref_t := (others => (others => '0'));
    variable s1, s2 : positive := SEED;
    variable r : real;
    variable addr, n_rd, n_wr : natural := 0;
    variable w : boolean;
    variable da : std_logic_vector(WA - 1 downto 0);
    variable db : std_logic_vector(WB - 1 downto 0);
    variable ea, last_a : std_logic_vector(WA - 1 downto 0) := (others => 'U');
    variable eb, last_b : std_logic_vector(WB - 1 downto 0) := (others => 'U');
    variable bea : std_logic_vector(BWA - 1 downto 0);
    variable beb : std_logic_vector(BWB - 1 downto 0);

    impure function rnd(n : natural) return natural is
    begin
      uniform(s1, s2, r);
      return natural(floor(r * real(n)));
    end function;
    impure function rnd_v(n : positive) return std_logic_vector is
      variable v : std_logic_vector(n - 1 downto 0);
    begin
      for i in v'range loop
        if rnd(2) = 1 then v(i) := '1'; else v(i) := '0'; end if;
      end loop;
      return v;
    end function;
  begin
    -- initialize: write the whole memory through port B
    for i in 0 to 2 ** AB - 1 loop
      db := rnd_v(WB);
      address_b <= std_logic_vector(to_unsigned(i, AB)); data_b <= db; wren_b <= '1';
      wait for 1 ns; clock1 <= '1'; wait for 1 ns; clock1 <= '0';
      for k in 0 to RB - 1 loop ref(i * RB + k) := db((k + 1) * NW - 1 downto k * NW); end loop;
    end loop;
    wren_b <= '0';

    for step in 1 to STEPS loop
      w := rnd(3) = 0;
      if rnd(2) = 0 then
        -- port A
        addr := rnd(2 ** AA);
        da := rnd_v(WA);
        bea := (others => '1');
        if BE then bea := rnd_v(BWA); end if;
        address_a <= std_logic_vector(to_unsigned(addr, AA)); data_a <= da; byteena_a <= bea;
        wren_a <= '1' when w else '0';
        wait for 1 ns; clock0 <= '1'; wait for 1 ns; clock0 <= '0';
        if w then
          for k in 0 to RA - 1 loop
            if not BE or bea(k) = '1' then ref(addr * RA + k) := da((k + 1) * NW - 1 downto k * NW); end if;
          end loop;
          n_wr := n_wr + 1;
        else
          n_rd := n_rd + 1;
        end if;
        for k in 0 to RA - 1 loop ea((k + 1) * NW - 1 downto k * NW) := ref(addr * RA + k); end loop;
        assert q_a = ea report "port A addr " & integer'image(addr) & ": q " & to_hstring(q_a) &
                               ", expected " & to_hstring(ea) severity failure;
        assert q_b = last_b or last_b(0) = 'U' report "q_b changed without clock1" severity failure;
        -- a new address without a clock edge must not change q (registered read)
        address_a <= std_logic_vector(to_unsigned(rnd(2 ** AA), AA));
        wait for 1 ns;
        assert q_a = ea report "port A: q follows the address without clock0" severity failure;
        last_a := q_a;
        wren_a <= '0';
      else
        -- port B
        addr := rnd(2 ** AB);
        db := rnd_v(WB);
        beb := (others => '1');
        if BE then beb := rnd_v(BWB); end if;
        address_b <= std_logic_vector(to_unsigned(addr, AB)); data_b <= db; byteena_b <= beb;
        wren_b <= '1' when w else '0';
        wait for 1 ns; clock1 <= '1'; wait for 1 ns; clock1 <= '0';
        if w then
          for k in 0 to RB - 1 loop
            if not BE or beb(k) = '1' then ref(addr * RB + k) := db((k + 1) * NW - 1 downto k * NW); end if;
          end loop;
          n_wr := n_wr + 1;
        else
          n_rd := n_rd + 1;
        end if;
        for k in 0 to RB - 1 loop eb((k + 1) * NW - 1 downto k * NW) := ref(addr * RB + k); end loop;
        assert q_b = eb report "port B addr " & integer'image(addr) & ": q " & to_hstring(q_b) &
                               ", expected " & to_hstring(eb) severity failure;
        assert q_a = last_a or last_a(0) = 'U' report "q_a changed without clock0" severity failure;
        address_b <= std_logic_vector(to_unsigned(rnd(2 ** AB), AB));
        wait for 1 ns;
        assert q_b = eb report "port B: q follows the address without clock1" severity failure;
        last_b := q_b;
        wren_b <= '0';
      end if;
    end loop;
    if BE then report "byte enables checked"; end if;
    report "checked " & integer'image(WA) & "/" & integer'image(WB) & " bit: " & integer'image(n_rd) & " reads, " &
           integer'image(n_wr) & " writes";
    done <= true;
    wait;
  end process;

end architecture tb;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity altsyncram_init_check is
  port (done : out boolean := false);
end entity;

architecture tb of altsyncram_init_check is
  signal clk, ce_s, ce_a, ce_b, we_s, we_a, we_b : std_logic := '0';
  signal addr_s : std_logic_vector(2 downto 0) := (others => '0');
  signal d_s, q_s : std_logic_vector(11 downto 0);
  signal addr_a : std_logic_vector(1 downto 0) := (others => '0');
  signal d_a, q_a : std_logic_vector(15 downto 0);
  signal addr_b : std_logic_vector(2 downto 0) := (others => '0');
  signal d_b, q_b : std_logic_vector(7 downto 0);

  type w12_t is array (0 to 7) of std_logic_vector(11 downto 0);
  constant INIT_S : w12_t := (x"ABC", x"001", x"002", x"800", x"7FF", x"F0F", x"000", x"000");
  type w8_t is array (0 to 7) of std_logic_vector(7 downto 0);
  constant INIT_B : w8_t := (x"34", x"12", x"78", x"56", x"BC", x"9A", x"F0", x"DE");
begin

  single : entity work.altsyncram
    generic map (
      operation_mode => "SINGLE_PORT", width_a => 12, widthad_a => 3, numwords_a => 6,
      clock_enable_input_a => "NORMAL", clock_enable_output_a => "BYPASS", outdata_reg_a => "UNREGISTERED",
      init_file => "altsyncram_tb_single.mem", lpm_hint => "ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=ROM")
    port map (clock0 => clk, clocken0 => ce_s, address_a => addr_s, data_a => d_s, wren_a => we_s, q_a => q_s);

  dual : entity work.altsyncram
    generic map (
      operation_mode => "BIDIR_DUAL_PORT", width_a => 16, widthad_a => 2, numwords_a => 4,
      width_b => 8, widthad_b => 3, numwords_b => 8,
      clock_enable_input_a => "NORMAL", clock_enable_input_b => "NORMAL",
      outdata_reg_a => "UNREGISTERED", outdata_reg_b => "UNREGISTERED", init_file => "altsyncram_tb_dual.mem")
    port map (clock0 => clk, clocken0 => ce_a, address_a => addr_a, data_a => d_a, wren_a => we_a, q_a => q_a,
              clock1 => clk, clocken1 => ce_b, address_b => addr_b, data_b => d_b, wren_b => we_b, q_b => q_b);

  process
    procedure tick is
    begin
      wait for 1 ns; clk <= '1'; wait for 1 ns; clk <= '0';
    end procedure;
    variable held : std_logic_vector(11 downto 0);
  begin
    -- initial contents, read with the clock enables high
    ce_s <= '1'; ce_a <= '1'; ce_b <= '1';
    for i in 0 to 7 loop
      addr_s <= std_logic_vector(to_unsigned(i, 3)); addr_b <= std_logic_vector(to_unsigned(i, 3));
      tick;
      assert q_s = INIT_S(i) report "single init word " & integer'image(i) & ": " & to_hstring(q_s) &
                                    ", expected " & to_hstring(INIT_S(i)) severity failure;
      assert q_b = INIT_B(i) report "dual init byte " & integer'image(i) & ": " & to_hstring(q_b) &
                                    ", expected " & to_hstring(INIT_B(i)) severity failure;
    end loop;
    addr_a <= "11"; tick;
    assert q_a = x"DEF0" report "dual init word 3: " & to_hstring(q_a) severity failure;

    -- clock enable low: no write, q keeps its value
    addr_s <= "101"; tick; held := q_s;
    ce_s <= '0'; addr_s <= "001"; d_s <= x"555"; we_s <= '1'; tick;
    assert q_s = held report "single: q changed with clocken0 low" severity failure;
    ce_s <= '1'; we_s <= '0'; tick;
    assert q_s = x"001" report "single: written with clocken0 low: " & to_hstring(q_s) severity failure;
    we_s <= '1'; tick; we_s <= '0'; tick;
    assert q_s = x"555" report "single: no write with clocken0 high" severity failure;

    ce_b <= '0'; addr_b <= "000"; d_b <= x"AA"; we_b <= '1'; tick;
    assert q_b = INIT_B(7) report "dual: q_b changed with clocken1 low" severity failure;
    ce_b <= '1'; we_b <= '0'; tick;
    assert q_b = x"34" report "dual: written with clocken1 low: " & to_hstring(q_b) severity failure;
    ce_a <= '0'; addr_a <= "00"; d_a <= x"0000"; we_a <= '1'; tick;
    assert q_a = x"DEF0" report "dual: q_a changed with clocken0 low" severity failure;
    ce_a <= '1'; we_a <= '0'; tick;
    assert q_a = x"1234" report "dual: port A written with clocken0 low: " & to_hstring(q_a) severity failure;
    we_b <= '1'; d_b <= x"AA"; tick; we_b <= '0';
    tick;
    assert q_a = x"12AA" report "dual: byte from port B not in the port A word: " & to_hstring(q_a) severity failure;

    report "checked init file, numwords, clock enables";
    done <= true;
    wait;
  end process;

end architecture tb;

library ieee;
use ieee.std_logic_1164.all;

entity altsyncram_tb is
end entity;

architecture tb of altsyncram_tb is
  signal done_n, done_w, done_i, done_be, done_be2, done_be3 : boolean;
begin
  narrow : entity work.altsyncram_check
    generic map (WA => 8, AA => 11, WB => 8, AB => 11, STEPS => 20000, SEED => 3)
    port map (done => done_n);
  wide : entity work.altsyncram_check
    generic map (WA => 16, AA => 10, WB => 8, AB => 11, STEPS => 20000, SEED => 4)
    port map (done => done_w);
  be : entity work.altsyncram_check
    generic map (WA => 64, AA => 9, WB => 32, AB => 10, STEPS => 20000, SEED => 5, BE => true)
    port map (done => done_be);
  be_narrow_a : entity work.altsyncram_check
    generic map (WA => 16, AA => 10, WB => 64, AB => 8, STEPS => 20000, SEED => 6, BE => true)
    port map (done => done_be2);
  be_equal : entity work.altsyncram_check
    generic map (WA => 32, AA => 8, WB => 32, AB => 8, STEPS => 20000, SEED => 7, BE => true)
    port map (done => done_be3);
  init : entity work.altsyncram_init_check
    port map (done => done_i);

  process
  begin
    wait until done_n and done_w and done_i and done_be and done_be2 and done_be3 for 10 ms;
    assert done_n and done_w and done_i and done_be and done_be2 and done_be3 report "timeout" severity failure;
    report "PASS: all configurations";
    wait;
  end process;
end architecture tb;
