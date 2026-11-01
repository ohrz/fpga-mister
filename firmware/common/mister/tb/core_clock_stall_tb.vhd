-------------------------------------------------------------------------------
-- Title      : Testbench of core_clock_stall
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : core_clock_stall_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Random stall requests (short ones, and long ones beyond the bucket) against
--   a model written from the definition: after k master cycles the core has
--   earned 1 + floor(k * NUM / DEN) edges; it gets an edge exactly when stall
--   is low and it has an earned edge left; earned edges beyond G_BUCKET are
--   lost.  Derived clocks: CE exactly on every DIV-th granted edge (counted from
--   the start, reset included).  Ends with "PASS" or a failure.
--   core_clock_stall_tb: pacer 21/22 (MSX); core_clock_stall_1to1_tb: 1/1
--   (no pacing, menu core); core_clock_stall_alt_tb: 21/22 and 227/240 (SNES
--   NTSC/PAL), alt toggled at random: the count restarts at every switch, so
--   earned = earned at the switch + floor(cycles since * NUM / DEN) of the
--   ratio in effect.
--   VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity core_clock_stall_tb is
  generic (
    G_CYCLES : natural := 200000;
    G_SEED   : positive := 5;
    G_NUM    : positive := 21;
    G_DEN    : positive := 22;
    G_NUM_ALT : natural := 0;          -- 0: alt stays '0'
    G_DEN_ALT : natural := 0
  );
end entity;

architecture tb of core_clock_stall_tb is

  constant NUM    : positive := G_NUM;
  constant DEN    : positive := G_DEN;
  constant BUCKET : positive := 40;
  constant DIV1   : positive := 4;
  constant DIV2   : positive := 3;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal done  : boolean := false;
  signal stall : std_logic := '0';
  signal alt   : std_logic := '0';
  signal ce, ce_div1, ce_div2 : std_logic;
  signal lag   : std_logic_vector(15 downto 0);

begin

  clk <= not clk after 5 ns when not done;

  dut : entity work.core_clock_stall
    generic map (G_NUM => NUM, G_DEN => DEN, G_BUCKET => BUCKET, G_DIV1 => DIV1, G_DIV2 => DIV2,
                 G_NUM_ALT => G_NUM_ALT, G_DEN_ALT => G_DEN_ALT)
    port map (clk => clk, rst => rst, stall => stall, alt => alt, ce => ce, ce_div1 => ce_div1,
              ce_div2 => ce_div2, lag => lag);

  process
    variable s1, s2 : positive := G_SEED;
    variable r : real;
    variable k, granted, g_all, lost, stalled, long_stalls : natural := 0;
    variable avail : integer;
    variable exp_ce : std_logic;
    variable burst : natural := 0;
    variable p_short, r_s : natural := 0;
    -- ratio in effect and the count since the last switch
    variable m_num : natural := NUM;
    variable m_den : natural := DEN;
    variable base_e, base_k, switches, next_sw : natural := 0;
    variable m_alt : boolean := false;

    impure function rnd(n : natural) return natural is
    begin
      uniform(s1, s2, r);
      return natural(floor(r * real(n)));
    end function;

    function b2s(b : boolean) return std_logic is
    begin
      if b then return '1'; else return '0'; end if;
    end function;

    impure function earned(c : natural) return natural is
    begin
      return base_e + ((c - base_k) * m_num) / m_den;   -- < 2**31 for G_CYCLES used here
    end function;
  begin
    -- reset: ce follows not stall, the derived clocks keep their phase
    rst <= '1';
    for i in 1 to 7 loop
      wait until falling_edge(clk);
      assert ce = '1' report "no edge during reset" severity failure;
      assert ce_div1 = b2s(g_all mod DIV1 = 0) report "derived clock 1 phase in reset" severity failure;
      wait until rising_edge(clk);
      g_all := g_all + 1;
    end loop;
    rst <= '0';
    next_sw := 3000;

    while k < G_CYCLES loop
      -- ratio switch (the DUT registers alt at the coming edge)
      if G_NUM_ALT /= 0 and k = next_sw then
        alt <= not alt;
        next_sw := k + 1000 + rnd(20000);
      end if;
      -- stall of this cycle
      if burst > 0 then
        stall <= '1'; burst := burst - 1;
      else
        -- every 5000 cycles a new rate of short stalls: 0.5 %, 2 % (the pacer keeps up) or 15 %
        if k mod 5000 = 0 then
          case rnd(3) is when 0 => p_short := 5; when 1 => p_short := 20; when others => p_short := 150; end case;
        end if;
        r_s := rnd(1000);
        if r_s = 0 and rnd(4) = 0 then
          burst := BUCKET + rnd(3 * BUCKET); stall <= '1'; long_stalls := long_stalls + 1;
        elsif r_s < p_short then
          stall <= '1'; burst := rnd(4);
        else
          stall <= '0';
        end if;
      end if;
      wait until falling_edge(clk);                -- outputs settled

      avail := 1 + earned(k) - granted - lost;
      if stall = '0' and avail > 0 then exp_ce := '1'; else exp_ce := '0'; end if;
      assert ce = exp_ce
        report "cycle " & integer'image(k) & ": ce " & std_logic'image(ce) & ", expected " &
               std_logic'image(exp_ce) & " (earned edges left " & integer'image(avail) & ")" severity failure;
      assert ce_div1 = b2s(ce = '1' and g_all mod DIV1 = 0)
        report "cycle " & integer'image(k) & ": derived clock 1 wrong" severity failure;
      assert ce_div2 = b2s(ce = '1' and g_all mod DIV2 = 0)
        report "cycle " & integer'image(k) & ": derived clock 2 wrong" severity failure;
      assert to_integer(unsigned(lag)) = avail
        report "cycle " & integer'image(k) & ": lag " & integer'image(to_integer(unsigned(lag))) &
               ", expected " & integer'image(avail) severity failure;

      wait until rising_edge(clk);
      if ce = '1' then
        granted := granted + 1; g_all := g_all + 1;
      else
        stalled := stalled + 1;
      end if;
      k := k + 1;
      if (alt = '1') /= m_alt then
        base_e := earned(k);                        -- this edge still earned at the old ratio
        base_k := k;
        switches := switches + 1;
        m_alt := alt = '1';
        if alt = '1' then m_num := G_NUM_ALT; m_den := G_DEN_ALT; else m_num := NUM; m_den := DEN; end if;
      end if;
      avail := 1 + earned(k) - granted - lost;
      if avail > BUCKET then lost := lost + avail - BUCKET; end if;
    end loop;

    assert long_stalls > 10 and lost > 0 report "stimulus too weak" severity failure;
    assert G_NUM_ALT = 0 or switches > 10 report "too few ratio switches" severity failure;
    report "PASS: " & integer'image(k) & " master cycles, " & integer'image(granted) & " core edges (" &
           integer'image(earned(k) + 1) & " earned, " & integer'image(lost) & " lost in " &
           integer'image(long_stalls) & " long stalls), " & integer'image(stalled) & " withheld, " &
           integer'image(switches) & " ratio switches";
    done <= true;
    wait;
  end process;

end architecture tb;

library ieee;
use ieee.std_logic_1164.all;

entity core_clock_stall_1to1_tb is
end entity;

architecture tb of core_clock_stall_1to1_tb is
begin
  one : entity work.core_clock_stall_tb generic map (G_NUM => 1, G_DEN => 1);
end architecture tb;

library ieee;
use ieee.std_logic_1164.all;

entity core_clock_stall_alt_tb is
end entity;

architecture tb of core_clock_stall_alt_tb is
begin
  two : entity work.core_clock_stall_tb generic map (G_NUM => 21, G_DEN => 22, G_NUM_ALT => 227, G_DEN_ALT => 240);
end architecture tb;
