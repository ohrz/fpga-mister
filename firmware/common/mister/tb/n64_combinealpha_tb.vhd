-------------------------------------------------------------------------------
-- Title      : Testbench of the RDP alpha combiner replacement (N64)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : n64_combinealpha_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Equivalence of cores/n64/RDP_CombineAlpha.vhd and the original
--   rtl/RDP_CombineAlpha.vhd of N64_MiSTer (the Makefile copies it from the
--   checkout as RDP_CombineAlpha_orig).  Both get the same random inputs every
--   clk1x cycle: trigger, mode2, step2, the combiner modes of both cycles, the
--   other-mode bits the entity reads (cvgTimesAlpha, alphaCvgSelect, key),
--   prim/env alpha, prim level fraction, pipe colour, texel alphas, lod_frac,
--   coverage values and dither.  Checks, N_CYCLES cycles:
--     before every rising edge (inputs settled): the combinational outputs
--     cvg_overflow and combine_alpha_save are equal
--     after every rising edge: every output is equal (error_combineAlpha,
--     combine_alpha, combine_alpha2, combine_CVGCount as well)
--   and that the stimulus reached both values of cvg_overflow and of
--   error_combineAlpha, saturated and unsaturated combine_alpha (0, 255 and
--   values between), so a constant output cannot pass.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.pRDP.all;

entity n64_combinealpha_tb is
end entity n64_combinealpha_tb;

architecture sim of n64_combinealpha_tb is
  constant N_CYCLES : natural := 200000;
  constant T_CLK    : time    := 10 ns;

  signal clk1x               : std_logic := '0';
  signal trigger, mode2      : std_logic := '0';
  signal step2               : std_logic := '0';
  signal otherModes          : tsettings_otherModes;
  signal combineMode         : tsettings_combineMode;
  signal primcolor           : tsettings_primcolor;
  signal envcolor            : tsettings_envcolor;
  signal pipeInColor         : tcolor4_u9 := (others => (others => '0'));
  signal tex_alpha           : unsigned(7 downto 0) := (others => '0');
  signal tex2_alpha          : unsigned(7 downto 0) := (others => '0');
  signal lod_frac            : unsigned(8 downto 0) := (others => '0');
  signal cvgCount            : unsigned(3 downto 0) := (others => '0');
  signal cvgFB               : unsigned(2 downto 0) := (others => '0');
  signal ditherAlpha         : unsigned(2 downto 0) := (others => '0');

  type outs_t is record
    err       : std_logic;
    overflow  : std_logic;
    alpha     : unsigned(7 downto 0);
    alpha2    : unsigned(7 downto 0);
    save      : signed(9 downto 0);
    cvg       : unsigned(3 downto 0);
  end record;
  signal o_ref, o_dut : outs_t;
begin

  ref : entity work.RDP_CombineAlpha_orig
    port map (
      clk1x => clk1x, trigger => trigger, mode2 => mode2, step2 => step2,
      error_combineAlpha => o_ref.err,
      settings_otherModes => otherModes, settings_combineMode => combineMode,
      settings_primcolor => primcolor, settings_envcolor => envcolor,
      pipeInColor => pipeInColor, tex_alpha => tex_alpha, tex2_alpha => tex2_alpha,
      lod_frac => lod_frac, cvgCount => cvgCount, cvgFB => cvgFB, ditherAlpha => ditherAlpha,
      cvg_overflow => o_ref.overflow, combine_alpha => o_ref.alpha, combine_alpha2 => o_ref.alpha2,
      combine_alpha_save => o_ref.save, combine_CVGCount => o_ref.cvg);

  dut : entity work.RDP_CombineAlpha
    port map (
      clk1x => clk1x, trigger => trigger, mode2 => mode2, step2 => step2,
      error_combineAlpha => o_dut.err,
      settings_otherModes => otherModes, settings_combineMode => combineMode,
      settings_primcolor => primcolor, settings_envcolor => envcolor,
      pipeInColor => pipeInColor, tex_alpha => tex_alpha, tex2_alpha => tex2_alpha,
      lod_frac => lod_frac, cvgCount => cvgCount, cvgFB => cvgFB, ditherAlpha => ditherAlpha,
      cvg_overflow => o_dut.overflow, combine_alpha => o_dut.alpha, combine_alpha2 => o_dut.alpha2,
      combine_alpha_save => o_dut.save, combine_CVGCount => o_dut.cvg);

  process
    variable s1, s2 : positive := 42;
    variable seen_ovf : std_logic_vector(1 downto 0) := "00";
    variable seen_err : std_logic_vector(1 downto 0) := "00";
    variable n_sat0, n_sat255, n_mid : natural := 0;
    variable om : tsettings_otherModes;
    variable cm : tsettings_combineMode;
    variable pc : tsettings_primcolor;
    variable ec : tsettings_envcolor;

    impure function rnd(bits : positive) return unsigned is
      variable r : real;
    begin
      uniform(s1, s2, r);
      return to_unsigned(integer(floor(r * real(2 ** bits))) mod 2 ** bits, bits);
    end function;

    impure function rbit return std_logic is
    begin
      return rnd(1)(0);
    end function;

    procedure check(what : string) is
    begin
      assert o_ref.overflow = o_dut.overflow and o_ref.save = o_dut.save
        report what & ": cvg_overflow " & std_logic'image(o_dut.overflow) & " expected " &
               std_logic'image(o_ref.overflow) & ", combine_alpha_save " & integer'image(to_integer(o_dut.save)) &
               " expected " & integer'image(to_integer(o_ref.save)) severity failure;
    end procedure;
  begin
    for i in 0 to N_CYCLES - 1 loop
      -- new inputs after the rising edge
      trigger <= rbit; mode2 <= rbit; step2 <= rbit;
      om := otherModes;
      om.cvgTimesAlpha := rbit; om.alphaCvgSelect := rbit;
      om.key := '1' when rnd(3) = 0 else '0';               -- key alpha mode rare (error output)
      otherModes <= om;
      cm := combineMode;
      cm.combine_sub_a_A_0 := rnd(3); cm.combine_sub_a_A_1 := rnd(3);
      cm.combine_sub_b_A_0 := rnd(3); cm.combine_sub_b_A_1 := rnd(3);
      cm.combine_mul_A_0   := rnd(3); cm.combine_mul_A_1   := rnd(3);
      cm.combine_add_A_0   := rnd(3); cm.combine_add_A_1   := rnd(3);
      combineMode <= cm;
      pc := primcolor; pc.prim_A := rnd(8); pc.prim_levelFrac := rnd(8); primcolor <= pc;
      ec := envcolor; ec.env_A := rnd(8); envcolor <= ec;
      pipeInColor(3) <= rnd(9);
      tex_alpha <= rnd(8); tex2_alpha <= rnd(8); lod_frac <= rnd(9);
      cvgCount <= rnd(4); cvgFB <= rnd(3); ditherAlpha <= rnd(3);

      wait for T_CLK / 2;
      clk1x <= '0';
      wait for T_CLK / 2 - 1 ns;
      check("before edge " & integer'image(i));
      clk1x <= '1';
      wait for 1 ns;
      check("after edge " & integer'image(i));
      assert o_ref = o_dut
        report "after edge " & integer'image(i) & ": registered outputs differ: combine_alpha " &
               integer'image(to_integer(o_dut.alpha)) & "/" & integer'image(to_integer(o_ref.alpha)) &
               ", combine_alpha2 " & integer'image(to_integer(o_dut.alpha2)) & "/" & integer'image(to_integer(o_ref.alpha2)) &
               ", CVGCount " & integer'image(to_integer(o_dut.cvg)) & "/" & integer'image(to_integer(o_ref.cvg)) &
               ", error " & std_logic'image(o_dut.err) & "/" & std_logic'image(o_ref.err) &
               " (dut/original)" severity failure;

      if o_ref.overflow = '1' then seen_ovf(1) := '1'; else seen_ovf(0) := '1'; end if;
      if o_ref.err = '1' then seen_err(1) := '1'; else seen_err(0) := '1'; end if;
      if o_ref.alpha = 0 then n_sat0 := n_sat0 + 1;
      elsif o_ref.alpha = 255 then n_sat255 := n_sat255 + 1;
      else n_mid := n_mid + 1; end if;
    end loop;

    report "cycles " & integer'image(N_CYCLES) & ", combine_alpha 0/255/between " & integer'image(n_sat0) & "/" &
           integer'image(n_sat255) & "/" & integer'image(n_mid);
    assert seen_ovf = "11" and seen_err = "11" and n_sat0 > 100 and n_sat255 > 100 and n_mid > 1000
      report "stimulus too weak: cvg_overflow " & to_string(seen_ovf) & ", error " & to_string(seen_err)
      severity failure;
    report "PASS";
    wait;
  end process;

end architecture sim;
