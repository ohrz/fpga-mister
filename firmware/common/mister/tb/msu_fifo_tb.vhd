-------------------------------------------------------------------------------
-- Title      : Testbench of the SNES MSU-1 FIFO replacement
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : msu_fifo_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   cores/snes/msu_fifo.vhd with a small depth (DEPTH 3: 8 words) so full and
--   empty occur often, one clock on both sides as in msu_audio.v.  Random
--   wrreq/rdreq (also when full or empty: ignored) and occasional aclr against
--   a reference queue.  Checks after every clock: q is the oldest word while
--   not empty (show-ahead, also right after a write into an empty FIFO and
--   after a read of the head), rdempty, wrfull and wrusedw/rdusedw.
--   Ends with "PASS" or a failure.  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity msu_fifo_tb is
end entity;

architecture tb of msu_fifo_tb is
  constant W : positive := 12;
  constant D : positive := 3;
  signal clk, aclr, wrreq, rdreq, wrfull, rdempty : std_logic := '0';
  signal data, q : std_logic_vector(W - 1 downto 0) := (others => '0');
  signal wrusedw, rdusedw : std_logic_vector(D - 1 downto 0);
begin

  dut : entity work.msu_fifo
    generic map (WIDTH => W, DEPTH => D)
    port map (aclr => aclr, wrclk => clk, wrreq => wrreq, data => data, wrfull => wrfull, wrusedw => wrusedw,
              rdclk => clk, rdreq => rdreq, q => q, rdempty => rdempty, rdusedw => rdusedw);

  process
    type queue_t is array (0 to 2 ** D - 1) of std_logic_vector(W - 1 downto 0);
    variable queue : queue_t;
    variable head, n : natural := 0;
    variable s1, s2 : positive := 5;
    variable r : real;
    variable n_wr, n_rd, n_full, n_empty, n_clr : natural := 0;
    variable do_wr, do_rd, push, pop : boolean;
    variable d_v : std_logic_vector(W - 1 downto 0);

    impure function rnd(k : natural) return natural is
    begin
      uniform(s1, s2, r);
      return natural(floor(r * real(k)));
    end function;
  begin
    for step in 1 to 50000 loop
      if rnd(500) = 0 then
        aclr <= '1'; wait for 1 ns; aclr <= '0';
        n := 0; head := 0; n_clr := n_clr + 1;
      end if;
      -- phases with more writes and with more reads, so full and empty both occur
      if (step / 200) mod 2 = 0 then
        do_wr := rnd(4) /= 0; do_rd := rnd(4) = 0;
      else
        do_wr := rnd(4) = 0; do_rd := rnd(4) /= 0;
      end if;
      d_v := std_logic_vector(to_unsigned(rnd(2 ** W), W));
      wrreq <= '1' when do_wr else '0'; rdreq <= '1' when do_rd else '0'; data <= d_v;
      wait for 1 ns; clk <= '1'; wait for 1 ns; clk <= '0';
      -- reference: wrreq when full and rdreq when empty (before the edge) are ignored
      push := do_wr and n < 2 ** D;
      pop  := do_rd and n > 0;
      if n = 2 ** D and do_wr then n_full := n_full + 1; end if;
      if n = 0 and do_rd then n_empty := n_empty + 1; end if;
      if push then queue((head + n) mod 2 ** D) := d_v; n_wr := n_wr + 1; end if;
      if pop then head := (head + 1) mod 2 ** D; n_rd := n_rd + 1; end if;
      if push and not pop then n := n + 1; elsif pop and not push then n := n - 1; end if;
      wait for 1 ns;
      assert (rdempty = '1') = (n = 0) report "rdempty " & std_logic'image(rdempty) & " with " & integer'image(n) &
                                              " words" severity failure;
      assert (wrfull = '1') = (n = 2 ** D) report "wrfull " & std_logic'image(wrfull) & " with " &
                                                  integer'image(n) & " words" severity failure;
      assert to_integer(unsigned(wrusedw)) = n mod 2 ** D and rdusedw = wrusedw
        report "usedw " & integer'image(to_integer(unsigned(wrusedw))) & " with " & integer'image(n) & " words"
        severity failure;
      if n > 0 then
        assert q = queue(head) report "step " & integer'image(step) & ": q " & to_hstring(q) & ", expected " &
                                      to_hstring(queue(head)) severity failure;
      end if;
    end loop;
    report "checked " & integer'image(n_wr) & " writes, " & integer'image(n_rd) & " reads, " &
           integer'image(n_full) & " writes when full, " & integer'image(n_empty) & " reads when empty, " &
           integer'image(n_clr) & " aclr";
    assert n_full > 100 and n_empty > 100 and n_clr > 10 report "too few corner cases" severity failure;
    report "PASS";
    wait;
  end process;

end architecture tb;
