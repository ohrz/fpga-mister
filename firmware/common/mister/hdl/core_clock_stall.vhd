-------------------------------------------------------------------------------
-- Title      : Core clock stall and pacer (clock enables for BUFGCE)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : core_clock_stall.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Decides for every rising edge of the free running master clock clk whether
--   the core gets it (doc/ARCHITECTURE.md §3, stage C).  The outputs are the
--   CE inputs of BUFGCE buffers on clk (glitch free, a withheld edge is a
--   missing pulse); the core runs on the buffered clocks.
--
--   Master clock: the core clock with the highest frequency (MSX: clk_mem),
--   generated a few percent faster than nominal.  The pacer keeps the core at
--   its nominal rate on average: the core earns G_NUM/G_DEN edges per master
--   cycle (nominal / actual frequency, e.g. 85.909 / 90.000 = 21/22 with an
--   MMCM divider of 10.5 instead of 11) and spends one per granted edge.
--   After a stall the saved edges (at most G_BUCKET) are caught up at the
--   faster rate, so the core loses no time over periods longer than a stall.
--   G_NUM = G_DEN: no pacing, the core only loses the stalled edges.
--
--   Derived core clocks (MSX: clk_sys = clk_mem / 4, both phase 0): BUFGCE on
--   the same master clock, ce_divN = every G_DIVN-th granted edge.  The core
--   sees the same edge sequence of all its clocks as with the original PLL,
--   whatever the stalls; the high time of a derived clock is the high time of
--   the master clock (only rising edges may be used on derived clocks).
--   Timing: create_generated_clock -edges {1 2 2*N+1} on the derived BUFGCE.
--
--   ce = not stall and an edge is earned.  stall is the OR of the stall
--   outputs of the sdram_emu instances (combinational, so ce is too).
--   During rst: ce = not stall (the core's own synchronous resets need edges).
--
--   Second ratio G_NUM_ALT / G_DEN_ALT (0: the same as G_NUM / G_DEN) while
--   alt = '1': a core that switches its clock at run time (SNES PAL/NTSC, the
--   PLL reconfiguration of the DE10-Nano).  alt is registered here; a switch
--   clears acc (at most one fractional edge lost), tokens are kept.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity core_clock_stall is
  generic (
    G_NUM    : positive := 1;          -- nominal edges per master cycle = G_NUM / G_DEN (<= 1)
    G_DEN    : positive := 1;
    G_BUCKET : positive := 1024;       -- at most this many saved edges are caught up
    G_DIV1   : natural := 0;           -- derived clock 1: every G_DIV1-th granted edge (0: unused)
    G_DIV2   : natural := 0;           -- derived clock 2
    G_NUM_ALT : natural := 0;          -- ratio while alt = '1' (0: G_NUM / G_DEN)
    G_DEN_ALT : natural := 0
  );
  port (
    clk     : in  std_logic;           -- free running master clock
    rst     : in  std_logic;           -- synchronous, active high
    stall   : in  std_logic;           -- withhold the coming edge
    alt     : in  std_logic := '0';    -- '1': pace at G_NUM_ALT / G_DEN_ALT
    ce      : out std_logic;           -- CE of the master BUFGCE, ce of sdram_emu
    ce_div1 : out std_logic;           -- CE of the BUFGCE of derived clock 1
    ce_div2 : out std_logic;
    lag     : out std_logic_vector(15 downto 0)  -- saved edges (debug, saturated)
  );
end entity core_clock_stall;

architecture rtl of core_clock_stall is

  function cnt_max(d : natural) return natural is
  begin
    if d = 0 then return 0; else return d - 1; end if;
  end function;

  function pick(a, b : natural) return natural is
  begin
    if a = 0 then return b; else return a; end if;
  end function;

  function max(a, b : natural) return natural is
  begin
    if a > b then return a; else return b; end if;
  end function;

  constant C_NUM_ALT : positive := pick(G_NUM_ALT, G_NUM);
  constant C_DEN_ALT : positive := pick(G_DEN_ALT, G_DEN);
  constant C_ACC_MAX : positive := max(G_DEN, C_DEN_ALT);

  -- 0 to G_DEN - 1 in operation; the extra value keeps the else branch below in range
  -- for synthesis when G_NUM = G_DEN (never taken, but Vivado folds it to a constant).
  signal acc    : natural range 0 to C_ACC_MAX;
  signal alt_r  : std_logic := '0';
  signal num    : natural range 0 to max(G_NUM, C_NUM_ALT);
  signal den    : natural range 1 to C_ACC_MAX;
  signal tokens : natural range 0 to G_BUCKET;
  signal cnt1   : natural range 0 to cnt_max(G_DIV1) := 0;
  signal cnt2   : natural range 0 to cnt_max(G_DIV2) := 0;
  signal ce_i   : std_logic;
  signal earn     : natural range 0 to 1;
  signal tok_keep : natural range 0 to G_BUCKET;
  signal tok_take : natural range 0 to G_BUCKET;

begin

  assert G_NUM <= G_DEN report "core_clock_stall: G_NUM > G_DEN" severity failure;
  assert C_NUM_ALT <= C_DEN_ALT report "core_clock_stall: G_NUM_ALT > G_DEN_ALT" severity failure;

  num <= C_NUM_ALT when alt_r = '1' else G_NUM;
  den <= C_DEN_ALT when alt_r = '1' else G_DEN;

  ce_i    <= '1' when stall = '0' and tokens /= 0 else '0';
  ce      <= ce_i;
  ce_div1 <= '1' when ce_i = '1' and G_DIV1 /= 0 and cnt1 = 0 else '0';
  ce_div2 <= '1' when ce_i = '1' and G_DIV2 /= 0 and cnt2 = 0 else '0';
  lag     <= std_logic_vector(to_unsigned(tokens, 16)) when tokens < 2 ** 16 else (others => '1');

  -- next token count without and with a granted edge, from registers only:
  -- ce (late, through the back end and the emulator) just selects
  earn     <= 1 when acc + num >= den else 0;
  tok_keep <= G_BUCKET when tokens + earn > G_BUCKET else tokens + earn;
  tok_take <= tokens + earn - 1 when tokens + earn >= 1 else 0;   -- only used with tokens >= 1

  process (clk)
  begin
    if rising_edge(clk) then
      alt_r <= alt;
      if alt /= alt_r then
        acc <= 0;                                   -- new ratio: start its count afresh
      elsif earn = 1 then
        acc <= acc + num - den;
      else
        acc <= acc + num;
      end if;
      if ce_i = '1' then
        tokens <= tok_take;                         -- <= G_BUCKET: tokens <= G_BUCKET
      else
        tokens <= tok_keep;
      end if;

      if ce_i = '1' then
        if cnt1 = cnt_max(G_DIV1) then cnt1 <= 0; else cnt1 <= cnt1 + 1; end if;
        if cnt2 = cnt_max(G_DIV2) then cnt2 <= 0; else cnt2 <= cnt2 + 1; end if;
      end if;

      if rst = '1' then
        acc    <= 0;
        tokens <= 1;                                -- cnt1/cnt2 keep counting: the derived
                                                    -- clocks keep their rate during rst
      end if;
    end if;
  end process;

end architecture rtl;
