-------------------------------------------------------------------------------
-- Title      : Derived core clock from the gated master clock, with mid clock
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : clk_pulse_div.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Building block of the replacement pll.vhd of a core profile (stage C,
--   doc/ARCHITECTURE.md §3.7, doc/PORTING.md §3.3): a core clock that is an
--   integer fraction 1/G_DIV of the fastest one, made of pulses of clk_in (the
--   gated master clock, BUFGCE core_buf of mister_zynq, or another clock of
--   this kind), and optionally its mid clock.
--     clk_out  every G_DIV-th pulse of clk_in (BUFGCE div_buf on clk_in)
--     clk_mid  with G_MID > 0: the pulse G_MID pulses after each clk_out pulse
--              (BUFGCE mid_buf on clk_in).  G_MID = G_DIV/2 is the pulse where
--              the derived clock falls on the DE10 (50 % duty cycle of the
--              Intel PLL): logic at the falling edge of the derived clock runs
--              at the rising edge of clk_mid (rules falling_edge_to of
--              prepare_sources.py), with the time of the DE10 between the
--              edges instead of the high time of clk_in.  G_DIV odd: the
--              DE10 edge lies between two pulses, G_MID = G_DIV/2 takes the
--              earlier one (half a master period less after clk_out).
--   A counter clocked by clk_in counts the pulses the core really got, so the
--   phase of both clocks to clk_in is the same after every stall.  The high
--   time of both is the high time of clk_in.
--   Clocks: one BUFGCE per output.  A BUFG drives another one only through an
--   adjacent BUFGCTRL site (Place 30-120): core_buf has two, so
--   one instance with clk_mid on core_buf uses both; a further derived clock
--   needs clk_in = clk_out of an instance (a chain, as in cores/snes/pll.vhd).
--   Timing (cores/<core>/core.xdc, source the BUFGCE driving clk_in):
--     create_generated_clock -edges {1 2 2*G_DIV+1}                 on div_buf/O
--     create_generated_clock -edges {2*G_MID+1 2*G_MID+2 2*(G_MID+G_DIV)+1}
--                                                                    on mid_buf/O
--   G_DIV = 1 passes clk_in through (no BUFGCE, no mid clock).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity clk_pulse_div is
  generic (
    G_DIV : positive := 2;              -- clk_out = clk_in / G_DIV
    G_MID : natural  := 0               -- clk_mid: G_MID pulses after clk_out (0: none)
  );
  port (
    clk_in  : in  std_logic;            -- gated master clock (or a derived clock of this kind)
    clk_out : out std_logic;            -- every G_DIV-th pulse of clk_in
    clk_mid : out std_logic             -- '0' with G_MID = 0
  );
end entity clk_pulse_div;

architecture rtl of clk_pulse_div is
  -- pulse p of clk_in sees cnt = p mod G_DIV (cnt counts the pulses before it)
  signal cnt    : natural range 0 to G_DIV - 1 := 0;
  signal ce_out : std_logic;
  signal ce_mid : std_logic;
begin

  assert G_MID < G_DIV and (G_MID = 0 or G_DIV > 1)
    report "clk_pulse_div: G_MID must be below G_DIV" severity failure;

  pass : if G_DIV = 1 generate
    clk_out <= clk_in;
    clk_mid <= '0';
  end generate;

  divide : if G_DIV > 1 generate
    process (clk_in)
    begin
      if rising_edge(clk_in) then
        if cnt = G_DIV - 1 then
          cnt <= 0;
        else
          cnt <= cnt + 1;
        end if;
      end if;
    end process;

    -- clk_out: pulses p = G_DIV-1 mod G_DIV, clk_mid: G_MID pulses later
    ce_out <= '1' when cnt = G_DIV - 1 else '0';
    ce_mid <= '1' when cnt = (G_DIV - 1 + G_MID) mod G_DIV else '0';  -- used with G_MID > 0

    div_buf : BUFGCE
      port map (I => clk_in, CE => ce_out, O => clk_out);

    with_mid : if G_MID > 0 generate
      mid_buf : BUFGCE
        port map (I => clk_in, CE => ce_mid, O => clk_mid);
    end generate;

    no_mid : if G_MID = 0 generate
      clk_mid <= '0';
    end generate;
  end generate;

end architecture rtl;
