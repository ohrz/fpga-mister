-------------------------------------------------------------------------------
-- Title      : SNES core profile: replacement of the core PLL (Stage C clocks)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : pll.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/pll.v of SNES_MiSTer (altera_pll, 50 MHz -> clk_mem
--   85.909 MHz, CLK_VIDEO 42.955 MHz at -4365 ps, clk_sys 21.477 MHz) with the
--   same name and ports, so SNES.sv stays unchanged (doc/ARCHITECTURE.md §3.7,
--   the MSX pattern with one more divider).
--   The top level feeds the emu port CLK_50M (refclk here) with the gated core
--   master clock: the BUFGCE output driven by core_clock_stall (90 MHz with the
--   pacer at 21/22, a missing pulse while the core is stalled).
--     outclk_0  clk_mem   = refclk
--     outclk_1  CLK_VIDEO = every 2nd pulse of refclk (BUFGCE), phase 0: the
--               phase of the original only matters for the Cyclone V video
--               path, here ascal takes the picture over
--     outclk_2  clk_sys   = every 2nd pulse of CLK_VIDEO (BUFGCE on CLK_VIDEO),
--               so every 4th pulse of refclk; both keep their phase to clk_mem
--               after every stall (each counter is clocked by the input of
--               its BUFGCE).  A chain refclk -> CLK_VIDEO -> clk_sys, not two
--               BUFGCEs on refclk: refclk is itself a BUFGCE output, and the
--               placer cascades BUFGs only with an adjacent BUFGCTRL (Place
--               30-120); its other neighbour drives refclk.
--     outclk_3  clk_sys_mid = the other pulses of CLK_VIDEO (BUFGCE on refclk):
--               the 2nd refclk pulse of every clk_sys period, where clk_sys
--               falls on the DE10.  Logic at the falling edge of clk_sys runs
--               on its rising edge (patch 0002, rules.py): the pulses here are
--               one refclk high time long, a falling edge would leave 5.6 ns.
--               Not in the original PLL (rules.py connects the extra port).
--     locked    '1' (the clocks exist once the top level releases the core)
--     reconfig_from_pll  zeros (cores/snes/pll_cfg.vhd ignores it)
--   The high time of the divided clocks is the high time of refclk.
--   BUFG cascade: refclk (core_buf) -> CLK_VIDEO -> clk_sys and refclk ->
--   clk_sys_mid, four adjacent BUFGCTRL sites.
--   Timing: create_generated_clock -edges {1 2 5} on CLK_VIDEO (from refclk)
--   and clk_sys (from CLK_VIDEO), {5 6 13} on clk_sys_mid (from refclk)
--   (cores/snes/core.xdc).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity pll is
  port (
    refclk            : in  std_logic;                       -- gated core master clock
    rst               : in  std_logic;                       -- unused (the original ties it to 0)
    outclk_0          : out std_logic;                       -- clk_mem
    outclk_1          : out std_logic;                       -- CLK_VIDEO = clk_mem / 2
    outclk_2          : out std_logic;                       -- clk_sys = clk_mem / 4
    outclk_3          : out std_logic;                       -- clk_sys_mid: falling edge of clk_sys
    reconfig_to_pll   : in  std_logic_vector(63 downto 0);   -- unused (no reconfiguration)
    reconfig_from_pll : out std_logic_vector(63 downto 0);
    locked            : out std_logic
  );
end entity pll;

architecture rtl of pll is
  signal ce_video  : std_logic := '0';
  signal ce_sys    : std_logic := '0';
  signal ce_mid    : std_logic;
  signal clk_video : std_logic;
  signal clk_mid   : std_logic;
begin

  outclk_0          <= refclk;
  locked            <= '1';
  reconfig_from_pll <= (others => '0');

  -- every 2nd pulse of refclk reaches CLK_VIDEO, every 2nd pulse of CLK_VIDEO clk_sys
  process (refclk)
  begin
    if rising_edge(refclk) then
      ce_video <= not ce_video;
    end if;
  end process;

  process (clk_video)
  begin
    if rising_edge(clk_video) then
      ce_sys <= not ce_sys;
    end if;
  end process;

  video_buf : BUFGCE
    port map (I => refclk, CE => ce_video, O => clk_video);
  sys_buf : BUFGCE
    port map (I => clk_video, CE => ce_sys, O => outclk_2);
  outclk_1 <= clk_video;

  -- the refclk pulses CLK_VIDEO passes and clk_sys does not
  ce_mid <= ce_video and not ce_sys;
  mid_buf : BUFGCE
    port map (I => refclk, CE => ce_mid, O => clk_mid);
  outclk_3 <= clk_mid;                    -- same delta as outclk_1 in simulation

end architecture rtl;
