-------------------------------------------------------------------------------
-- Title      : Differential testbench of the PSX gpu_poly timing patch
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : gpu_poly_diff_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-31
-------------------------------------------------------------------------------
-- Description:
--   rtl/gpu_poly.vhd of PSX_MiSTer (cd17b5a) as gpu_poly_orig against the
--   copy with cores/psx/patches/0001-gpu-poly-*.patch as gpu_poly_new (the
--   Makefile renames both).  Each gets its own six dividers (rtl/divider.vhd,
--   as gpu.vhd); both get the same inputs, and the environment reacts to
--   the original's outputs: command words (polygon commands of random kind
--   shading/quad/texture/transparency/raw, random vertices, mostly small,
--   some large enough to be culled, some flat) as fifo_Valid pulses that
--   count as taken when the unit requests them (requestFifo, or the first
--   word while it is idle), VRAM line reads answered 1..8 cycles after
--   requestVRAMEnable, random pipeline_busy/stall, fifoOut_idle, ce pauses,
--   random drawing area/offset/filter settings, REPRODUCIBLEGPUTIMING
--   switched every 40 commands (with it WAITIMING ends each command when
--   drawTiming reaches targetTiming, so a different targetTiming shows as a
--   different done cycle).  The patch claims no change of any output in any
--   cycle: every output (pixels, VRAM requests, divider starts and operands,
--   done, CmdDone, requestFifo, palette/drawmode, error) of both units is
--   compared at every falling clock edge.
--   Ends with "PASS" (and the counts of commands, done and pixels) or a
--   failure at the first difference.  VHDL-2008 (ghdl --std=08, run with
--   --ieee-asserts=disable: the dividers start with undefined values).
--   Three things of the original have to be worked around, identically for
--   both units: the divider results are forced into the inout div records
--   (an inout port without a source drives 'U'), ce stays high while a
--   division runs (a done pulse during a pause is lost and the unit waits
--   for its 1 M cycle timeout), and drawn polygons keep x, y >= 20 (a
--   negative left edge stops GHDL in a natural comparison).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.pGPU.all;

entity gpu_poly_diff_tb is
end entity;

architecture tb of gpu_poly_diff_tb is

  constant T      : time := 14 ns;
  constant N_CMDS : natural := 600;

  type div_array is array (0 to 5) of div_type;
  type quot_array is array (0 to 5) of signed(44 downto 0);
  type rem_array is array (0 to 5) of signed(24 downto 0);

  signal clk, clk_idx, ce, reset : std_logic := '0';
  signal done_sim : boolean := false;
  signal repro : std_logic := '0';
  signal tex_filter, tex_strength : std_logic_vector(1 downto 0) := "00";
  signal tex_2doff, pix_mask, interlaced, line_lsb, dithering : std_logic := '0';
  signal off_x, off_y : signed(10 downto 0) := (others => '0');
  signal area_l, area_r : unsigned(9 downto 0) := (others => '0');
  signal area_t, area_b : unsigned(8 downto 0) := (others => '0');
  signal fifo_out_idle, pl_busy, pl_stall, proc_idle, fifo_valid : std_logic := '0';
  signal fifo_data : std_logic_vector(31 downto 0) := (others => '0');
  signal vram_idle, vram_done : std_logic := '1';

  -- outputs of both units, packed
  constant OW : natural := 1 + 12 + 1 + 1 + 1 + 1 + 1 + 1 + 10 + 9 + 5 * 8 + 1 + 4 * 8 + 1 + 1 + 1 + 1 + 10 + 9 + 11 +
                           1 + 10 + 9 + 1 + 10 + 6 * (1 + 45 + 25);
  subtype out_t is std_logic_vector(OW - 1 downto 0);
  signal o_orig, o_new : out_t;
  signal d_orig, d_new : div_array;
  signal req_fifo, done_o, cmddone_o, vram_en, pl_new : std_logic;

begin

  clk <= not clk after T / 2 when not done_sim;

  watchdog : process
  begin
    wait for 200 ms;
    assert done_sim report "timeout" severity failure;
    wait;
  end process;

  ------------------------------------------------------------------------------
  -- the two units
  ------------------------------------------------------------------------------
  orig_b : block
    signal error, drawModeNew, p_new, p_tex, p_tr, p_raw, p_dith, p_filter, reqFifo, done, CmdDone : std_logic;
    signal reqEn, palNew, lineEna : std_logic;
    signal drawModeRec : unsigned(11 downto 0);
    signal p_x, vx, palX, lineAddr : unsigned(9 downto 0);
    signal p_y, vy, palY : unsigned(8 downto 0);
    signal p_cr, p_cg, p_cb, p_u, p_v, p_u11, p_v11, p_uAcc, p_vAcc : unsigned(7 downto 0);
    signal vsize : unsigned(10 downto 0);
    signal dv_done : std_logic_vector(0 to 5);
    signal dv_quot : quot_array;
    signal dv_rem  : rem_array;
  begin
    u : entity work.gpu_poly_orig
      port map (
        clk2x => clk, clk2xIndex => clk_idx, ce => ce, reset => reset, REPRODUCIBLEGPUTIMING => repro,
        textureFilter => tex_filter, textureFilterStrength => tex_strength, textureFilter2DOff => tex_2doff,
        error => error, DrawPixelsMask => pix_mask, interlacedDrawing => interlaced, activeLineLSB => line_lsb,
        drawingOffsetX => off_x, drawingOffsetY => off_y, drawingAreaLeft => area_l, drawingAreaRight => area_r,
        drawingAreaTop => area_t, drawingAreaBottom => area_b, drawModeRec => drawModeRec,
        drawModeNew => drawModeNew, drawmode_dithering => dithering,
        div1 => d_orig(0), div2 => d_orig(1), div3 => d_orig(2), div4 => d_orig(3), div5 => d_orig(4),
        div6 => d_orig(5),
        fifoOut_idle => fifo_out_idle, pipeline_busy => pl_busy, pipeline_stall => pl_stall,
        pipeline_new => p_new, pipeline_texture => p_tex, pipeline_transparent => p_tr,
        pipeline_rawTexture => p_raw, pipeline_dithering => p_dith, pipeline_x => p_x, pipeline_y => p_y,
        pipeline_cr => p_cr, pipeline_cg => p_cg, pipeline_cb => p_cb, pipeline_u => p_u, pipeline_v => p_v,
        pipeline_filter => p_filter, pipeline_u11 => p_u11, pipeline_v11 => p_v11, pipeline_uAcc => p_uAcc,
        pipeline_vAcc => p_vAcc, proc_idle => proc_idle, fifo_Valid => fifo_valid, fifo_data => fifo_data,
        requestFifo => reqFifo, done => done, CmdDone => CmdDone, requestVRAMEnable => reqEn,
        requestVRAMXPos => vx, requestVRAMYPos => vy, requestVRAMSize => vsize, requestVRAMIdle => vram_idle,
        requestVRAMDone => vram_done, textPalNew => palNew, textPalX => palX, textPalY => palY,
        vramLineEna => lineEna, vramLineAddr => lineAddr);
    gdiv : for i in 0 to 5 generate
      idiv : entity work.divider
        port map (clk => clk, start => d_orig(i).start, done => dv_done(i), busy => open,
                  dividend => d_orig(i).dividend, divisor => d_orig(i).divisor, quotient => dv_quot(i),
                  remainder => dv_rem(i));
    end generate;
    -- gpu_poly declares div1..6 as inout records and never drives done/quotient/remainder: the port then
    -- drives the default 'U' onto them (LRM: driving value of a port without source), and the resolved value
    -- stays 'U' whatever the divider drives. gpu.vhd has the same wiring; force the divider results in.
    div_force : process (dv_done, dv_quot, dv_rem)
    begin
      for i in 0 to 5 loop
        d_orig(i).done      <= force dv_done(i);
        d_orig(i).quotient  <= force dv_quot(i);
        d_orig(i).remainder <= force dv_rem(i);
      end loop;
    end process;
    o_orig <= error & std_logic_vector(drawModeRec) & drawModeNew & p_new & p_tex & p_tr & p_raw & p_dith &
              std_logic_vector(p_x) & std_logic_vector(p_y) & std_logic_vector(p_cr) & std_logic_vector(p_cg) &
              std_logic_vector(p_cb) & std_logic_vector(p_u) & std_logic_vector(p_v) & p_filter &
              std_logic_vector(p_u11) & std_logic_vector(p_v11) & std_logic_vector(p_uAcc) &
              std_logic_vector(p_vAcc) & reqFifo & done & CmdDone & reqEn & std_logic_vector(vx) &
              std_logic_vector(vy) & std_logic_vector(vsize) & palNew & std_logic_vector(palX) &
              std_logic_vector(palY) & lineEna & std_logic_vector(lineAddr) &
              d_orig(0).start & std_logic_vector(d_orig(0).dividend) & std_logic_vector(d_orig(0).divisor) &
              d_orig(1).start & std_logic_vector(d_orig(1).dividend) & std_logic_vector(d_orig(1).divisor) &
              d_orig(2).start & std_logic_vector(d_orig(2).dividend) & std_logic_vector(d_orig(2).divisor) &
              d_orig(3).start & std_logic_vector(d_orig(3).dividend) & std_logic_vector(d_orig(3).divisor) &
              d_orig(4).start & std_logic_vector(d_orig(4).dividend) & std_logic_vector(d_orig(4).divisor) &
              d_orig(5).start & std_logic_vector(d_orig(5).dividend) & std_logic_vector(d_orig(5).divisor);
    req_fifo  <= reqFifo;
    done_o    <= done;
    cmddone_o <= CmdDone;
    vram_en   <= reqEn;
    pl_new    <= p_new;
  end block;

  new_b : block
    signal error, drawModeNew, p_new, p_tex, p_tr, p_raw, p_dith, p_filter, reqFifo, done, CmdDone : std_logic;
    signal reqEn, palNew, lineEna : std_logic;
    signal drawModeRec : unsigned(11 downto 0);
    signal p_x, vx, palX, lineAddr : unsigned(9 downto 0);
    signal p_y, vy, palY : unsigned(8 downto 0);
    signal p_cr, p_cg, p_cb, p_u, p_v, p_u11, p_v11, p_uAcc, p_vAcc : unsigned(7 downto 0);
    signal vsize : unsigned(10 downto 0);
    signal dv_done : std_logic_vector(0 to 5);
    signal dv_quot : quot_array;
    signal dv_rem  : rem_array;
  begin
    u : entity work.gpu_poly_new
      port map (
        clk2x => clk, clk2xIndex => clk_idx, ce => ce, reset => reset, REPRODUCIBLEGPUTIMING => repro,
        textureFilter => tex_filter, textureFilterStrength => tex_strength, textureFilter2DOff => tex_2doff,
        error => error, DrawPixelsMask => pix_mask, interlacedDrawing => interlaced, activeLineLSB => line_lsb,
        drawingOffsetX => off_x, drawingOffsetY => off_y, drawingAreaLeft => area_l, drawingAreaRight => area_r,
        drawingAreaTop => area_t, drawingAreaBottom => area_b, drawModeRec => drawModeRec,
        drawModeNew => drawModeNew, drawmode_dithering => dithering,
        div1 => d_new(0), div2 => d_new(1), div3 => d_new(2), div4 => d_new(3), div5 => d_new(4),
        div6 => d_new(5),
        fifoOut_idle => fifo_out_idle, pipeline_busy => pl_busy, pipeline_stall => pl_stall,
        pipeline_new => p_new, pipeline_texture => p_tex, pipeline_transparent => p_tr,
        pipeline_rawTexture => p_raw, pipeline_dithering => p_dith, pipeline_x => p_x, pipeline_y => p_y,
        pipeline_cr => p_cr, pipeline_cg => p_cg, pipeline_cb => p_cb, pipeline_u => p_u, pipeline_v => p_v,
        pipeline_filter => p_filter, pipeline_u11 => p_u11, pipeline_v11 => p_v11, pipeline_uAcc => p_uAcc,
        pipeline_vAcc => p_vAcc, proc_idle => proc_idle, fifo_Valid => fifo_valid, fifo_data => fifo_data,
        requestFifo => reqFifo, done => done, CmdDone => CmdDone, requestVRAMEnable => reqEn,
        requestVRAMXPos => vx, requestVRAMYPos => vy, requestVRAMSize => vsize, requestVRAMIdle => vram_idle,
        requestVRAMDone => vram_done, textPalNew => palNew, textPalX => palX, textPalY => palY,
        vramLineEna => lineEna, vramLineAddr => lineAddr);
    gdiv : for i in 0 to 5 generate
      idiv : entity work.divider
        port map (clk => clk, start => d_new(i).start, done => dv_done(i), busy => open,
                  dividend => d_new(i).dividend, divisor => d_new(i).divisor, quotient => dv_quot(i),
                  remainder => dv_rem(i));
    end generate;
    -- gpu_poly declares div1..6 as inout records and never drives done/quotient/remainder: the port then
    -- drives the default 'U' onto them (LRM: driving value of a port without source), and the resolved value
    -- stays 'U' whatever the divider drives. gpu.vhd has the same wiring; force the divider results in.
    div_force : process (dv_done, dv_quot, dv_rem)
    begin
      for i in 0 to 5 loop
        d_new(i).done      <= force dv_done(i);
        d_new(i).quotient  <= force dv_quot(i);
        d_new(i).remainder <= force dv_rem(i);
      end loop;
    end process;
    o_new <= error & std_logic_vector(drawModeRec) & drawModeNew & p_new & p_tex & p_tr & p_raw & p_dith &
             std_logic_vector(p_x) & std_logic_vector(p_y) & std_logic_vector(p_cr) & std_logic_vector(p_cg) &
             std_logic_vector(p_cb) & std_logic_vector(p_u) & std_logic_vector(p_v) & p_filter &
             std_logic_vector(p_u11) & std_logic_vector(p_v11) & std_logic_vector(p_uAcc) &
             std_logic_vector(p_vAcc) & reqFifo & done & CmdDone & reqEn & std_logic_vector(vx) &
             std_logic_vector(vy) & std_logic_vector(vsize) & palNew & std_logic_vector(palX) &
             std_logic_vector(palY) & lineEna & std_logic_vector(lineAddr) &
             d_new(0).start & std_logic_vector(d_new(0).dividend) & std_logic_vector(d_new(0).divisor) &
             d_new(1).start & std_logic_vector(d_new(1).dividend) & std_logic_vector(d_new(1).divisor) &
             d_new(2).start & std_logic_vector(d_new(2).dividend) & std_logic_vector(d_new(2).divisor) &
             d_new(3).start & std_logic_vector(d_new(3).dividend) & std_logic_vector(d_new(3).divisor) &
             d_new(4).start & std_logic_vector(d_new(4).dividend) & std_logic_vector(d_new(4).divisor) &
             d_new(5).start & std_logic_vector(d_new(5).dividend) & std_logic_vector(d_new(5).divisor);
  end block;

  ------------------------------------------------------------------------------
  -- every output in every cycle
  ------------------------------------------------------------------------------
  cmp : process
    variable first : natural;
  begin
    wait until falling_edge(clk);
    if o_orig /= o_new then
      first := 0;
      for i in OW - 1 downto 0 loop
        if o_orig(i) /= o_new(i) then
          first := i;
          exit;
        end if;
      end loop;
      report "outputs differ, highest differing bit " & integer'image(first) & " of " & integer'image(OW)
        severity failure;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- environment and command stream
  ------------------------------------------------------------------------------
  env : process
    variable s1, s2 : positive := 2024;
    variable r : real;
    type words_t is array (0 to 15) of std_logic_vector(31 downto 0);
    variable w : words_t;
    variable nw, wi, cmds, dones, pixels, culled_try, t_idle : natural := 0;
    variable idle : boolean := true;
    variable done_p : std_logic := '0';
    variable vdelay : integer := -1;
    variable div_hold : natural := 0;
    variable shading, quad, texture, nv : natural;
    variable x, y, x0, y0, bx, by, span, span_x, span_y, big : integer;
    variable taken : boolean;

    impure function rnd(n : natural) return natural is
    begin
      uniform(s1, s2, r);
      return integer(floor(r * real(n)));
    end function;

    function sl(b : natural) return std_logic is
    begin
      if b /= 0 then return '1'; else return '0'; end if;
    end function;

  begin
    reset <= '1';
    for i in 1 to 4 loop wait until rising_edge(clk); end loop;
    reset <= '0';
    loop
      wait until rising_edge(clk);
      -- what the units saw at this edge
      taken := false;
      if fifo_valid = '1' and ce = '1' and wi < nw and (req_fifo = '1' or (idle and proc_idle = '1')) then
        taken := true;
        if idle then
          idle := false;
        end if;
        wi := wi + 1;
      end if;
      if done_o = '1' and done_p = '0' then
        assert not idle report "done while idle" severity failure;
        assert wi = nw report "done before all words were taken" severity failure;
        idle := true;
        dones := dones + 1;
      end if;
      done_p := done_o;
      if pl_new = '1' then
        pixels := pixels + 1;
      end if;
      -- VRAM line read: done 1..8 cycles after the request (also while ce is low)
      vram_done <= '0';
      if vdelay = 0 then
        vram_done <= '1';
        vdelay := -1;
      elsif vdelay > 0 then
        vdelay := vdelay - 1;
      end if;
      if vram_en = '1' and ce = '1' then
        vdelay := rnd(8);
      end if;
      if vdelay >= 0 then
        vram_idle <= '0';                                   -- a line read in progress
      else
        vram_idle <= sl(boolean'pos(rnd(10) /= 0));
      end if;

      clk_idx <= not clk_idx;
      -- ce low (pause) only while no division runs: the dividers run without ce and pulse done for one
      -- cycle; gpu_poly takes it only with ce high and would wait for its 1 M cycle timeout (the core
      -- has the same gap, pauses rarely meet a division there)
      for i in 0 to 5 loop
        if d_orig(i).start = '1' then
          div_hold := 64;                                   -- 45-bit quotient, one bit per cycle
        end if;
      end loop;
      if div_hold > 0 then
        div_hold := div_hold - 1;
        ce <= '1';
      else
        ce <= sl(rnd(20));
      end if;
      pl_busy <= sl(boolean'pos(rnd(5) = 0));
      pl_stall <= sl(boolean'pos(rnd(8) = 0));
      fifo_out_idle <= sl(boolean'pos(rnd(6) /= 0));

      -- next command when the unit is idle and all words of the last one are taken
      if idle and wi = nw then
        if cmds = N_CMDS then
          exit;
        end if;
        if cmds mod 40 = 0 then
          repro <= sl(boolean'pos((cmds / 40) mod 2 = 1));
          report "commands " & integer'image(cmds) & ", pixels " & integer'image(pixels);
        end if;
        -- settings
        tex_filter <= std_logic_vector(to_unsigned(rnd(4), 2));
        tex_strength <= std_logic_vector(to_unsigned(rnd(4), 2));
        tex_2doff <= sl(rnd(2)); pix_mask <= sl(rnd(2)); interlaced <= sl(boolean'pos(rnd(4) = 0));
        line_lsb <= sl(rnd(2)); dithering <= sl(rnd(2));
        off_x <= to_signed(rnd(64) - 16, 11);
        off_y <= to_signed(rnd(64) - 16, 11);
        area_l <= to_unsigned(rnd(64), 10);
        area_r <= to_unsigned(200 + rnd(400), 10);
        area_t <= to_unsigned(rnd(32), 9);
        area_b <= to_unsigned(150 + rnd(300), 9);
        if rnd(30) = 0 then
          area_l <= to_unsigned(500, 10);                    -- empty drawing area
        end if;
        -- command
        shading := rnd(2); quad := rnd(2); texture := rnd(2);
        w(0) := "001" & sl(shading) & sl(quad) & sl(texture) & sl(rnd(2)) & sl(rnd(2)) &
                std_logic_vector(to_unsigned(rnd(16#1000000#), 24));
        nv := 3 + quad;
        nw := 1;
        bx := 40 + rnd(500);
        by := 30 + rnd(400);
        span := 4 + rnd(60);
        span_x := span;
        span_y := span;
        -- large (culled) polygons on one axis only: with REPRODUCIBLEGPUTIMING the unit still waits
        -- (y span + 1) * x span * 4 cycles, 1200 x 1200 would be ~6 M cycles per polygon
        big := 0;
        if rnd(25) = 0 then
          big := 1 + rnd(2);
          if big = 1 then
            span_x := 1030 + rnd(60);                       -- x distance >= 0x400
          else
            span_y := 515 + rnd(40);                        -- y distance >= 0x200
          end if;
          culled_try := culled_try + 1;
        end if;
        for v in 0 to nv - 1 loop
          if v > 0 and shading = 1 then
            w(nw) := x"00" & std_logic_vector(to_unsigned(rnd(16#1000000#), 24));
            nw := nw + 1;
          end if;
          -- drawn polygons stay at x, y >= 20 (with the offset >= 4): gpu_poly compares
          -- to_integer(xStart) > drawingAreaRight, a natural in numeric_std, and GHDL stops on a negative
          -- left edge (synthesis wraps); culled polygons never get there and may reach below 0
          x := maximum(20, minimum(1000, bx + rnd(span_x) - span_x / 2));
          y := maximum(20, minimum(1000, by + rnd(span_y) - span_y / 2));
          if big = 1 then
            if v = 0 then
              x0 := 1000 - span_x - rnd(20);                -- vertices 0 and 1 span the full x distance
            end if;
            x := x0 + rnd(span_x);
            if v < 2 then
              x := x0 + v * span_x;
            end if;
          elsif big = 2 then
            if v = 0 then
              y0 := 20 + rnd(20);
            end if;
            y := y0 + rnd(span_y);
            if v < 2 then
              y := y0 + v * span_y;
            end if;
          end if;
          if rnd(12) = 0 and v > 0 then
            y := by;                                        -- flat edges
          end if;
          w(nw) := "00000" & std_logic_vector(to_signed(y, 11)) & "00000" & std_logic_vector(to_signed(x, 11));
          nw := nw + 1;
          if texture = 1 then
            w(nw) := std_logic_vector(to_unsigned(rnd(65536), 16)) & std_logic_vector(to_unsigned(rnd(65536), 16));
            nw := nw + 1;
          end if;
        end loop;
        wi := 0;
        cmds := cmds + 1;
      end if;

      -- the next word, as a fifo_Valid pulse (the units take it only when they want it)
      proc_idle <= '0';
      fifo_valid <= '0';
      fifo_data <= (others => '0');
      if wi < nw and rnd(3) /= 0 then
        fifo_valid <= '1';
        fifo_data <= w(wi);
        if idle then
          proc_idle <= '1';
        end if;
      end if;
    end loop;
    -- the last command finishes
    t_idle := 0;
    while not idle loop
      wait until rising_edge(clk);
      ce <= '1';
      if done_o = '1' and done_p = '0' then
        idle := true;
        dones := dones + 1;
      end if;
      done_p := done_o;
      t_idle := t_idle + 1;
      assert t_idle < 200000 report "last command does not finish" severity failure;
    end loop;
    for i in 1 to 20 loop wait until rising_edge(clk); end loop;
    report "commands " & integer'image(cmds) & ", done " & integer'image(dones) & ", pixels " &
           integer'image(pixels) & ", large (culled) " & integer'image(culled_try);
    assert dones = cmds report "commands without done" severity failure;
    assert pixels > 20000 report "too few pixels drawn" severity failure;
    report "PASS";
    done_sim <= true;
    wait;
  end process;

end architecture tb;
