-------------------------------------------------------------------------------
-- Title      : Testbench of the SNES pll_cfg replacement (PAL/NTSC pacer select)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : snes_pll_cfg_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-31
-------------------------------------------------------------------------------
-- Description:
--   Drives cores/snes/pll_cfg.vhd with the write sequence of SNES.sv (address
--   0, 7 = K, 2 = start, every 2nd cycle) and checks reconfig_to_pll(0):
--   follows PAL only after the start write, never before; a sequence with an
--   unknown K keeps the selection; a start write without a K write before
--   keeps it; reset clears it; waitrequest stays '0'.  Ends with "PASS".
--   VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity snes_pll_cfg_tb is
end entity;

architecture tb of snes_pll_cfg_tb is
  constant K_NTSC : std_logic_vector(31 downto 0) := x"9745BF27";   -- 2537930535
  constant K_PAL  : std_logic_vector(31 downto 0) := x"83365882";   -- 2201376898

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '0';
  signal done  : boolean := false;
  signal wr    : std_logic := '0';
  signal addr  : std_logic_vector(5 downto 0) := (others => '0');
  signal data  : std_logic_vector(31 downto 0) := (others => '0');
  signal wait_r : std_logic;
  signal to_pll : std_logic_vector(63 downto 0);
  signal alt    : std_logic;
begin
  clk <= not clk after 5 ns when not done;
  alt <= to_pll(0);

  dut : entity work.pll_cfg
    port map (mgmt_clk => clk, mgmt_reset => rst, mgmt_waitrequest => wait_r, mgmt_read => '0',
              mgmt_write => wr, mgmt_readdata => open, mgmt_address => addr, mgmt_writedata => data,
              reconfig_to_pll => to_pll, reconfig_from_pll => (others => '0'));

  process
    procedure write(a : natural; d : std_logic_vector(31 downto 0)) is
    begin
      wait until rising_edge(clk);
      wr <= '1'; addr <= (others => '0'); data <= d;
      case a is
        when 0 => addr <= "000000";
        when 2 => addr <= "000010";
        when 7 => addr <= "000111";
        when others => addr <= "111111";
      end case;
      wait until rising_edge(clk);
      wr <= '0';
    end procedure;

    -- the sequence of SNES.sv; checks that alt does not change before the start write
    procedure region(k : std_logic_vector(31 downto 0); expect : std_logic) is
      variable before : std_logic;
    begin
      before := alt;
      write(0, x"00000000");
      wait until falling_edge(clk);
      assert alt = before report "alt changed at the mode write" severity failure;
      write(7, k);
      wait until falling_edge(clk);
      assert alt = before report "alt changed at the K write" severity failure;
      write(2, x"00000000");
      wait until falling_edge(clk);
      assert alt = expect report "alt " & std_logic'image(alt) & " after start, expected " &
        std_logic'image(expect) severity failure;
      assert wait_r = '0' and to_pll(63 downto 1) = (63 downto 1 => '0') report "other outputs" severity failure;
    end procedure;
  begin
    wait until falling_edge(clk);
    assert alt = '0' report "not NTSC after power-up" severity failure;
    region(K_PAL, '1');
    region(K_PAL, '1');
    region(K_NTSC, '0');
    region(K_PAL, '1');
    region(x"12345678", '1');                     -- unknown K: keep PAL
    region(K_NTSC, '0');
    region(x"83365883", '0');                     -- one bit off PAL: keep NTSC
    region(K_PAL, '1');
    write(2, x"00000000");                        -- start again without a K: keep
    wait until falling_edge(clk);
    assert alt = '1' report "a lone start write changed alt" severity failure;
    write(5, K_NTSC);                             -- K value at another address: ignored
    write(2, x"00000000");
    wait until falling_edge(clk);
    assert alt = '1' report "K at another address taken" severity failure;
    rst <= '1';
    wait until rising_edge(clk);
    rst <= '0';
    wait until falling_edge(clk);
    assert alt = '0' report "reset does not clear alt" severity failure;
    write(2, x"00000000");
    wait until falling_edge(clk);
    assert alt = '0' report "reset does not clear the pending K" severity failure;
    report "PASS";
    done <= true;
    wait;
  end process;
end architecture tb;
