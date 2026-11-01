-------------------------------------------------------------------------------
-- Title      : Pixel and serial clock of the HDMI transmitter from the core's video clock
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : video_pll.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Direct video (sys_top without ascal, MISTER_DEBUG_NOHDMI; mister_zynq
--   G_DIRECT_VIDEO): sys_top registers HDMI_TX_* on the core's video clock
--   (CLK_VIDEO, made by the core's PLL replacement).  The HDMI transmitter
--   (hdmi_out, rgb2dvi) needs that clock and five times it for its 10:1
--   serialiser.  PLLE2_BASE on clk_in:
--     VCO      = clk_in * G_MULT (800-1600 MHz, -1 speed grade)
--     clk_pix  = VCO / G_MULT    (clk_in, aligned to it: feedback over a BUFG)
--     clk_ser  = VCO / (G_MULT / 5)
--   G_MULT must be a multiple of 5 (N64: clk_in 48.68 MHz, G_MULT 20, VCO
--   973.6 MHz).  clk_pix and clk_ser are derived clocks of clk_in, so the
--   paths from sys_top to the transmitter are timed as synchronous.
--   Reset: clk_in only starts when the core's PLL has locked and may stop or
--   jump (core reload).  pll_reset on the free-running clk_free holds the
--   PLL in reset for G_RST_CYCLES, then waits up to 4 * G_RST_CYCLES for
--   lock (else resets again) and resets again when locked falls.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

entity video_pll is
  generic (
    G_CLKIN_PS   : positive := 20542;          -- period of clk_in in ps (timing model of the PLL)
    G_MULT       : positive := 20;             -- VCO = clk_in * G_MULT, a multiple of 5
    G_RST_CYCLES : positive := 65536           -- clk_free cycles of reset (1.3 ms at 50 MHz)
  );
  port (
    clk_free : in  std_logic;                  -- free-running (reset sequencer)
    clk_in   : in  std_logic;                  -- video clock of the core (global buffer)
    clk_pix  : out std_logic;                  -- = clk_in
    clk_ser  : out std_logic;                  -- 5 * clk_in
    locked   : out std_logic                   -- asynchronous
  );
end entity video_pll;

architecture rtl of video_pll is

  signal rst     : std_logic;
  signal lock_a  : std_logic;
  signal fb_out, fb_in, pix, ser : std_logic;

begin

  assert G_MULT mod 5 = 0 report "video_pll: G_MULT must be a multiple of 5" severity failure;

  pll : PLLE2_BASE
    generic map (
      BANDWIDTH      => "OPTIMIZED",
      CLKIN1_PERIOD  => real(G_CLKIN_PS) / 1000.0,
      DIVCLK_DIVIDE  => 1,
      CLKFBOUT_MULT  => G_MULT,
      CLKOUT0_DIVIDE => G_MULT,
      CLKOUT1_DIVIDE => G_MULT / 5)
    port map (
      CLKIN1   => clk_in,
      CLKFBIN  => fb_in,
      CLKFBOUT => fb_out,
      CLKOUT0  => pix,
      CLKOUT1  => ser,
      LOCKED   => lock_a,
      PWRDWN   => '0',
      RST      => rst);

  buf_fb  : BUFG port map (I => fb_out, O => fb_in);
  buf_pix : BUFG port map (I => pix, O => clk_pix);
  buf_ser : BUFG port map (I => ser, O => clk_ser);

  locked <= lock_a;

  seq : entity work.pll_reset
    generic map (G_RST_CYCLES => G_RST_CYCLES)
    port map (clk => clk_free, locked => lock_a, rst => rst);

end architecture rtl;
