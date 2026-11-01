-------------------------------------------------------------------------------
-- Title      : Constants of mister_zynq_tb and its sys_top_zynq stub
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : mister_zynq_tb_pkg.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Clock periods (all different, so a clock on the wrong port shows up), the
--   generics of the MSX core profile (cores/msx/core.tcl) and the test data.
--   VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package mister_zynq_tb_pkg is

  constant T_100    : time := 10 ns;
  constant T_50     : time := 20 ns;
  constant T_MASTER : time := 11 ns;
  constant T_HDMI   : time := 13 ns;
  constant T_AUDIO  : time := 40 ns;
  constant T_DDRAM  : time := 7 ns;
  constant T_COREMEM : time := 9 ns;              -- clock of the stub's COREMEM port (free running)
  constant T_VIDEO  : time := 20542 ps;           -- CLK_VIDEO of the stub's core (direct video)

  -- MSX core profile
  constant P_B0_MASK  : natural := 16#1F8#;
  constant P_B0_MATCH : natural := 16#1C0#;
  constant P_B0_SEL   : natural := 16#3FFE07#;
  constant P_B0_BITS  : natural := 16;
  constant P_BASE     : std_logic_vector(31 downto 0) := x"38000000";
  constant P_COL_HIGH : natural := 1;            -- cache/DDR word = bank & col & row

  -- SDRAM test: row 5 of bank 0, a column in the BRAM region (col(8:3) = 111000)
  -- and one in the DDR region; full write W1, write W2 with DQMH (lower byte),
  -- full write W3 to the next column
  constant SD_CL  : natural := 3;
  constant SD_ROW : natural := 5;
  type nat_array is array (natural range <>) of natural;
  constant SD_COLS : nat_array(0 to 1) := (16#1C1#, 16#011#);
  constant SD_W1  : std_logic_vector(15 downto 0) := x"A55A";
  constant SD_W2  : std_logic_vector(15 downto 0) := x"0FF0";
  constant SD_W3  : std_logic_vector(15 downto 0) := x"1234";

  -- ascal frame buffer burst
  constant VB_ADDR : std_logic_vector(28 downto 0) := std_logic_vector(to_unsigned(16#0400123#, 29));
  type word_array is array (natural range <>) of std_logic_vector(63 downto 0);
  constant VB_DATA : word_array(0 to 1) := (x"0123456789ABCDEF", x"FEDCBA9876543210");


  -- DDRAM_* of the core (G_DDRAM): a burst of DD_N beats from DD_ADDR (byte 0x3000_0FC0: AXI
  -- splits it at the 4 KB boundary after 8 beats and after 16), physical address on HP2
  constant DD_ADDR : std_logic_vector(28 downto 0) := std_logic_vector(to_unsigned(16#060001F8#, 29));
  constant DD_N    : natural := 20;
  function dd_data(i : natural) return std_logic_vector;

  -- COREMEM (G_COREMEM): a write burst of 2 beats at word CM_ADDR (byte G_SDRAM_BASE + 0xFF8:
  -- AXI splits it at the 4 KB boundary), then the read of both
  constant CM_ADDR : std_logic_vector(28 downto 0) := std_logic_vector(to_unsigned(16#1FF#, 29));
  constant CM_DATA : word_array(0 to 1) := (x"C0C0C0C0A5A5A5A5", x"0123456789ABCDEF");

  -- handshake between the testbench and the stub (one driver each)
  -- DDRAM_CLK source (testbench): the stub, the bridge in mister_zynq (through the ram1 clock
  -- port) and the memory model see it one delta cycle later, so they sample alike
  signal dd_clk_src : std_logic := '0';
  signal dd_mode    : std_logic := '0';             -- testbench: 1 = mister_zynq with G_DDRAM = 1
  signal dd_reading : std_logic := '0';             -- stub: its DDRAM read burst is open
  signal dd_done    : std_logic := '0';             -- stub: DDRAM sequence finished and checked
  signal free_mode  : std_logic := '0';             -- testbench: 1 = mister_zynq with G_FREE_CLK = 1
  signal cm_clk_src : std_logic := '0';             -- COREMEM clock source (testbench), as dd_clk_src
  signal cm_mode    : std_logic := '0';             -- testbench: 1 = mister_zynq with G_COREMEM = 1
  signal cm_reading : std_logic := '0';             -- stub: its COREMEM read is open
  signal cm_done    : std_logic := '0';             -- stub: COREMEM sequence finished and checked
  signal vd_clk_src : std_logic := '0';             -- CLK_VIDEO source (testbench), direct video
  signal vd_mode    : std_logic := '0';             -- testbench: 1 = mister_zynq with G_DIRECT_VIDEO = 1

end package mister_zynq_tb_pkg;

package body mister_zynq_tb_pkg is
  function dd_data(i : natural) return std_logic_vector is
  begin
    return std_logic_vector(x"DD000000" + to_unsigned(i * 16#10101#, 32)) &
           std_logic_vector(x"5A000000" + to_unsigned(i, 32));
  end function;
end package body mister_zynq_tb_pkg;
