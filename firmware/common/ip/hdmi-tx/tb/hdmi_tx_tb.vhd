-------------------------------------------------------------------------------
-- Title      : Testbench of hdmi_tx (+ i2s_rx): decodes the symbol stream
-- Project    : fpga-mister (hdmi-tx)
-------------------------------------------------------------------------------
-- File       : hdmi_tx_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-29
-------------------------------------------------------------------------------
-- Description:
--   A small video mode (HA x VA, real blanking lengths for one island) with
--   random pixels, hsync polarity from the generic P_HPOL, and an I2S source
--   that behaves like MiSTer's sys/i2s.v (16 bit, 32 bclk per frame,
--   1.536 MHz) with counting / pseudo-random samples.  The checker decodes
--   the 10-bit symbols of the three channels on its own (DVI decoding,
--   inverse TERC4 table, BCH by polynomial division) and checks:
--   - video: every active pixel at latency LAT, hsync/vsync in every control,
--     preamble and data island character; the running disparity of a video
--     run stays within +-10;
--   - exactly 8 video preamble characters (CTL0..3 = 1000) and 2 guard band
--     characters before each active line, nothing else;
--   - data islands: preamble 8 (1010), leading and trailing guard 2, whole
--     packets of 32 characters, D3 of channel 0 = 0 only on the first
--     character, header and subpacket ECC, at least 4 plain control
--     characters before every preamble;
--   - packets: ACR (N 6144, CTS = pixel clocks of 48 samples +-2), Audio
--     Sample (every sample of the source in order, none twice or missing,
--     parity, B every 192 frames, channel status bits 2, 25, 33), AVI and
--     Audio InfoFrame (checksum,
--     VIC 4, full range, 2 channels); counts of every type at the end.
--   Ends with "PASS" or a failure.  VHDL-2008.
--   Variants: hdmi_tx_neg_tb (active-low hsync), hdmi_tx_fast_tb (8 times the
--   audio rate: several samples per packet, samples arriving with the packet
--   load), hdmi_tx_short_tb (blanking too short: no island at all).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity hdmi_tx_tb is
  generic (
    P_HPOL : std_logic := '1';         -- hsync active level
    P_MS   : natural   := 6;           -- simulated milliseconds
    P_AF   : positive  := 1;           -- audio rate factor (8: 384 kHz, 2 samples per packet)
    P_HBP  : natural   := 140          -- horizontal back porch (20: no room for an island)
  );
end entity;

architecture tb of hdmi_tx_tb is

  constant T_PIX  : time := 13468 ps;  -- 74.25 MHz
  constant T_BCLK : time := 651042 ps / P_AF;  -- 1.536 MHz * P_AF
  -- CTS = pixel clocks of 48 samples (N = 6144)
  constant CTS_EXP : real := 48.0 * 32.0 * real(T_BCLK / 1 ps) / real(T_PIX / 1 ps);
  constant HA : natural := 200;  constant HFP : natural := 20; constant HSW : natural := 40; constant HBP : natural := P_HBP;
  constant VA : natural := 20;   constant VFP : natural := 3;  constant VSW : natural := 5;  constant VBP : natural := 10;
  constant HT : natural := HA + HFP + HSW + HBP;
  constant VT : natural := VA + VFP + VSW + VBP;
  constant LAT : natural := 12;        -- input clock -> symbol output

  signal clk  : std_logic := '0';
  signal done : boolean := false;
  signal rst  : std_logic := '1';

  signal vid_data : std_logic_vector(23 downto 0) := (others => '0');
  signal vid_de, vid_hs, vid_vs : std_logic := '0';
  signal bclk, lrclk, sdata : std_logic := '0';
  signal s_valid : std_logic;
  signal s_left, s_right : std_logic_vector(15 downto 0);
  signal sym0, sym1, sym2 : std_logic_vector(9 downto 0);
  signal drops : std_logic_vector(15 downto 0);

  -- input history for the checker
  type hist_t is array (0 to 63) of std_logic_vector(26 downto 0);
  signal hist : hist_t := (others => (others => '0'));
  signal cyc  : natural := 0;

  -- samples sent by the I2S source
  type smp_t is array (0 to 4095) of std_logic_vector(31 downto 0);
  signal exp_s : smp_t;
  signal exp_n : natural := 0;

  subtype sym_t is std_logic_vector(9 downto 0);

  -- decoders, written independently of hdmi_pkg
  procedure ctrl_dec(s : sym_t; ok : out boolean; c : out std_logic_vector(1 downto 0)) is
  begin
    ok := true;
    if    s = "1101010100" then c := "00";
    elsif s = "0010101011" then c := "01";
    elsif s = "0101010100" then c := "10";
    elsif s = "1010101011" then c := "11";
    else  ok := false; c := "XX";
    end if;
  end procedure;

  type t4_t is array (0 to 15) of sym_t;
  constant T4 : t4_t := ("1010011100", "1001100011", "1011100100", "1011100010", "0101110001", "0100011110",
                         "0110001110", "0100111100", "1011001100", "0100111001", "0110011100", "1011000110",
                         "1010001110", "1001110001", "0101100011", "1011000011");

  procedure t4_dec(s : sym_t; ok : out boolean; d : out std_logic_vector(3 downto 0)) is
  begin
    ok := false; d := "XXXX";
    for i in 0 to 15 loop
      if T4(i) = s then
        ok := true; d := std_logic_vector(to_unsigned(i, 4));
      end if;
    end loop;
  end procedure;

  function tmds_dec(s : sym_t) return std_logic_vector is
    variable d : std_logic_vector(7 downto 0);
    variable o : std_logic_vector(7 downto 0);
  begin
    if s(9) = '1' then d := not s(7 downto 0); else d := s(7 downto 0); end if;
    o(0) := d(0);
    for i in 1 to 7 loop
      if s(8) = '1' then o(i) := d(i) xor d(i - 1); else o(i) := d(i) xnor d(i - 1); end if;
    end loop;
    return o;
  end function;

  function disp(s : sym_t) return integer is
    variable n : integer := 0;
  begin
    for i in s'range loop
      if s(i) = '1' then n := n + 1; else n := n - 1; end if;
    end loop;
    return n;
  end function;

  -- BCH remainder by polynomial division (first sent bit = highest power), G = x^8+x^7+x^6+1;
  -- returns the 8 parity bits in send order
  function bch(bits : std_logic_vector; n : natural) return std_logic_vector is
    variable r : std_logic_vector(n + 7 downto 0) := (others => '0');
    variable e : std_logic_vector(7 downto 0);
  begin
    for j in 0 to n - 1 loop
      r(n + 7 - j) := bits(bits'low + j);
    end loop;
    for i in n + 7 downto 8 loop
      if r(i) = '1' then
        r(i downto i - 8) := r(i downto i - 8) xor "111000001";
      end if;
    end loop;
    for k in 0 to 7 loop
      e(k) := r(7 - k);
    end loop;
    return e;
  end function;

  function byte_of(v : std_logic_vector; j : natural) return natural is
  begin
    return to_integer(unsigned(v(v'low + 8 * j + 7 downto v'low + 8 * j)));
  end function;

begin

  clk <= not clk after T_PIX / 2 when not done;

  dut_rx : entity work.i2s_rx
    port map (clk => clk, bclk => bclk, lrclk => lrclk, sdata => sdata,
              left => s_left, right => s_right, valid => s_valid);

  dut : entity work.hdmi_tx
    port map (clk => clk, rst => rst, vid_data => vid_data, vid_de => vid_de, vid_hs => vid_hs, vid_vs => vid_vs,
              s_valid => s_valid, s_left => s_left, s_right => s_right,
              sym0 => sym0, sym1 => sym1, sym2 => sym2, drops => drops);

  -- video source
  video : process (clk)
    variable x, y : natural := 0;
    variable s1, s2 : positive := 7;
    variable r : real;
    variable de, hs, vs : std_logic;
    variable d : std_logic_vector(23 downto 0);
  begin
    if rising_edge(clk) then
      if x = HT - 1 then
        x := 0;
        if y = VT - 1 then y := 0; else y := y + 1; end if;
      else
        x := x + 1;
      end if;
      de := '1' when x < HA and y < VA else '0';
      hs := P_HPOL when x >= HA + HFP and x < HA + HFP + HSW else not P_HPOL;
      vs := '1' when y >= VA + VFP and y < VA + VFP + VSW else '0';
      d := (others => '0');
      if de = '1' then
        uniform(s1, s2, r);
        d := std_logic_vector(to_unsigned(integer(trunc(r * 16777215.0)), 24));
      end if;
      vid_de <= de; vid_hs <= hs; vid_vs <= vs; vid_data <= d;
      hist(cyc mod 64) <= vs & hs & de & d;
      cyc <= cyc + 1;
    end if;
  end process;

  -- I2S source as sys/i2s.v: lrclk and data change one audio clock (bclk / 16, 40 ns) before
  -- the falling bclk edge, lrclk one bit before the MSB (with the LSB of the
  -- previous word), 0 = left
  i2s : process
    variable l, r, prev_r : std_logic_vector(15 downto 0) := (others => '0');
    variable s1, s2 : positive := 11;
    variable rr : real;
    variable f : natural := 0;
    procedure slot(lr, b : std_logic) is
    begin
      lrclk <= lr; sdata <= b;
      wait for T_BCLK / 16;
      bclk <= '0';
      wait for T_BCLK / 2;
      bclk <= '1';
      wait for T_BCLK / 2 - T_BCLK / 16;
    end procedure;
  begin
    wait for 1.37 us;
    loop
      uniform(s1, s2, rr);
      l := std_logic_vector(to_unsigned(f mod 65536, 16));
      r := std_logic_vector(to_unsigned(integer(trunc(rr * 65535.0)), 16));
      if f < exp_s'length then
        exp_s(f) <= l & r;
      end if;
      slot('0', prev_r(0));
      for i in 15 downto 1 loop slot('0', l(i)); end loop;
      slot('1', l(0));
      for i in 15 downto 1 loop slot('1', r(i)); end loop;
      prev_r := r;
      f := f + 1;
      exp_n <= f - 1;                  -- frame f - 1 is complete with the next lrclk edge
      exit when done;
    end loop;
    wait;
  end process;

  stim : process
  begin
    rst <= '1';
    wait for 20 * T_PIX;
    wait until rising_edge(clk);
    rst <= '0';
    wait for P_MS * 1 ms;
    done <= true;
    wait;
  end process;

  -- checker
  check : process
    variable c, cv : std_logic_vector(1 downto 0);
    variable ok, ok1, ok2 : boolean;
    variable n0, n1, n2 : std_logic_vector(3 downto 0);
    variable h : std_logic_vector(26 downto 0);
    variable de_l, hs_l, vs_l : std_logic;
    -- state
    type st_t is (S_CTRL, S_VPRE, S_VGB, S_VID, S_DPRE, S_DGB1, S_DATA, S_DGB2);
    variable st : st_t := S_CTRL;
    variable run, plain : natural := 0;
    variable dsum : integer_vector(0 to 2);
    variable k, npk : natural := 0;
    variable hdr : std_logic_vector(31 downto 0);
    type sp_t is array (0 to 3) of std_logic_vector(63 downto 0);
    variable sp : sp_t;
    variable first_char : boolean;
    variable started, synced : boolean := false;
    variable rx_n, n_acr, n_asp, n_avi, n_aif, n_null, n_isl, n_lines : natural := 0;
    variable cts : natural;
    variable frame192 : natural := 0;
    variable b_seen : boolean := false;
    variable sum : natural;
    variable lsmp, rsmp : std_logic_vector(15 downto 0);
    variable cbit, pbit : std_logic;

    procedure fail(msg : string) is
    begin
      report msg & " (cycle " & integer'image(cyc) & ")" severity failure;
    end procedure;

    procedure check_sync(ch0dec : std_logic_vector(1 downto 0)) is
    begin
      if ch0dec /= std_logic_vector'(vs_l & hs_l) then
        fail("sync (vs, hs) = " & to_string(ch0dec) & ", expected " & to_string(std_logic_vector'(vs_l & hs_l)));
      end if;
    end procedure;

    procedure packet_done is
      variable t : natural;
    begin
      if bch(hdr(23 downto 0), 24) /= hdr(31 downto 24) then fail("header ECC"); end if;
      for i in 0 to 3 loop
        if bch(sp(i)(55 downto 0), 56) /= sp(i)(63 downto 56) then fail("subpacket " & integer'image(i) & " ECC"); end if;
      end loop;
      t := byte_of(hdr, 0);
      case t is
        when 16#00# => n_null := n_null + 1;
        when 16#01# =>
          n_acr := n_acr + 1;
          for i in 0 to 3 loop
            if sp(i)(55 downto 0) /= sp(0)(55 downto 0) then fail("ACR subpackets differ"); end if;
          end loop;
          if byte_of(sp(0), 4) * 65536 + byte_of(sp(0), 5) * 256 + byte_of(sp(0), 6) /= 6144 then fail("ACR N"); end if;
          cts := byte_of(sp(0), 1) * 65536 + byte_of(sp(0), 2) * 256 + byte_of(sp(0), 3);
          if abs(real(cts) - CTS_EXP) > 2.0 then fail("ACR CTS " & integer'image(cts)); end if;
        when 16#02# =>
          n_asp := n_asp + 1;
          if hdr(12) = '1' then fail("audio layout 1"); end if;
          for i in 0 to 3 loop
            if hdr(8 + i) = '1' then
              lsmp := sp(i)(23 downto 8); rsmp := sp(i)(47 downto 32);
              if sp(i)(7 downto 0) /= x"00" or sp(i)(31 downto 24) /= x"00" then fail("audio low bits"); end if;
              if rx_n > exp_n then fail("audio sample before it was sent"); end if;
              if lsmp & rsmp /= exp_s(rx_n) then
                fail("audio sample " & integer'image(rx_n) & " = " & to_hstring(lsmp & rsmp) & ", expected " & to_hstring(exp_s(rx_n)));
              end if;
              -- B flag, channel status, parity
              if (hdr(20 + i) = '1') /= (frame192 = 0) and b_seen then fail("B flag at frame " & integer'image(frame192)); end if;
              if hdr(20 + i) = '1' then b_seen := true; frame192 := 0; end if;
              cbit := '1' when frame192 = 2 or frame192 = 25 or frame192 = 33 else '0';
              if b_seen and (sp(i)(50) /= cbit or sp(i)(54) /= cbit) then fail("channel status bit " & integer'image(frame192)); end if;
              if sp(i)(48) /= '0' or sp(i)(49) /= '0' or sp(i)(52) /= '0' or sp(i)(53) /= '0' then fail("V/U"); end if;
              pbit := xor sp(i)(51 downto 48) xor (xor sp(i)(23 downto 0));
              if pbit /= '0' then fail("left parity"); end if;
              pbit := xor sp(i)(55 downto 52) xor (xor sp(i)(47 downto 24));
              if pbit /= '0' then fail("right parity"); end if;
              rx_n := rx_n + 1;
              frame192 := (frame192 + 1) mod 192;
            elsif sp(i)(55 downto 0) /= (55 downto 0 => '0') then
              fail("subpacket without sample not zero");
            end if;
          end loop;
          -- samples fill the subpackets from 0
          if hdr(11 downto 8) /= "0001" and hdr(11 downto 8) /= "0011" and hdr(11 downto 8) /= "0111" and hdr(11 downto 8) /= "1111" then
            fail("sample present " & to_string(hdr(11 downto 8)));
          end if;
        when 16#82# | 16#84# =>
          sum := byte_of(hdr, 0) + byte_of(hdr, 1) + byte_of(hdr, 2);
          for i in 0 to 3 loop
            for j in 0 to 6 loop sum := sum + byte_of(sp(i), j); end loop;
          end loop;
          if sum mod 256 /= 0 then fail("InfoFrame checksum " & integer'image(t)); end if;
          if t = 16#82# then
            n_avi := n_avi + 1;
            if byte_of(hdr, 1) /= 2 or byte_of(hdr, 2) /= 13 then fail("AVI version/length"); end if;
            if byte_of(sp(0), 4) /= 4 then fail("AVI VIC"); end if;
            if sp(0)(8 * 3 + 3 downto 8 * 3 + 2) /= "10" then fail("AVI Q (full range)"); end if;
            if sp(0)(8 + 6 downto 8 + 5) /= "00" then fail("AVI RGB"); end if;
          else
            n_aif := n_aif + 1;
            if byte_of(hdr, 1) /= 1 or byte_of(hdr, 2) /= 10 then fail("audio IF version/length"); end if;
            if sp(0)(8 + 2 downto 8) /= "001" then fail("audio IF channel count"); end if;
          end if;
        when others => fail("packet type " & integer'image(t));
      end case;
    end procedure;

  begin
    wait until rst = '0';
    loop
      wait until rising_edge(clk) or done;
      exit when done;
      if cyc > 2 * LAT + 64 then
        started := true;
      end if;
      next when not started;
      -- outputs of the previous edge belong to the input of cycle cyc - 1 - LAT
      h := hist((cyc - 1 - LAT) mod 64);
      vs_l := h(26); hs_l := h(25); de_l := h(24);
      -- start in a plain control period
      if not synced then
        if de_l = '0' and sym1 = "1101010100" and sym2 = "1101010100" then
          synced := true; st := S_CTRL; plain := 4;   -- earlier characters unseen
        end if;
        next;
      end if;

      if de_l = '1' then
        if st = S_VGB and run = 2 then
          null;
        elsif st /= S_VID then
          fail("video without preamble and guard band (state " & st_t'image(st) & ", run " & integer'image(run) & ")");
        end if;
        if st /= S_VID then
          st := S_VID; dsum := (0, 0, 0); n_lines := n_lines + 1;
        end if;
        if tmds_dec(sym0) /= h(15 downto 8) or tmds_dec(sym1) /= h(7 downto 0) or tmds_dec(sym2) /= h(23 downto 16) then
          fail("pixel " & to_hstring(h(23 downto 0)));
        end if;
        dsum(0) := dsum(0) + disp(sym0); dsum(1) := dsum(1) + disp(sym1); dsum(2) := dsum(2) + disp(sym2);
        for i in 0 to 2 loop
          if abs(dsum(i)) > 10 then fail("disparity of channel " & integer'image(i)); end if;
        end loop;
        plain := 0;
      else
        ctrl_dec(sym1, ok1, c);
        ctrl_dec(sym2, ok2, cv);
        if ok1 and ok2 then
          -- control period character
          ctrl_dec(sym0, ok, n0(1 downto 0));
          if not ok then fail("channel 0 not a control token"); end if;
          check_sync(n0(1 downto 0));
          if st = S_DGB2 and run /= 2 then fail("trailing guard band " & integer'image(run)); end if;
          if st = S_VGB or st = S_DGB1 or st = S_DATA then fail("control inside " & st_t'image(st)); end if;
          if c = "01" and cv = "00" then
            if st /= S_VPRE then
              if plain < 4 then fail("control period before video preamble " & integer'image(plain)); end if;
              st := S_VPRE; run := 0;
            end if;
            run := run + 1;
          elsif c = "01" and cv = "01" then
            if st /= S_DPRE then
              if plain < 4 then fail("control period before island preamble " & integer'image(plain)); end if;
              st := S_DPRE; run := 0;
            end if;
            run := run + 1;
          elsif c = "00" and cv = "00" then
            if st = S_VPRE or st = S_DPRE then fail("preamble without guard band"); end if;
            if st /= S_CTRL then st := S_CTRL; plain := 0; end if;
            plain := plain + 1;
          else
            fail("CTL " & to_string(cv & c));
          end if;
          if (st = S_VPRE or st = S_DPRE) and run > 8 then fail("preamble longer than 8"); end if;
        elsif sym0 = "1011001100" and sym1 = "0100110011" and sym2 = "1011001100" and (st = S_VPRE or st = S_VGB) then
          -- video guard band
          if st = S_VPRE then
            if run /= 8 then fail("video preamble " & integer'image(run)); end if;
            st := S_VGB; run := 0;
          end if;
          run := run + 1;
          if run > 2 then fail("video guard band longer than 2"); end if;
        elsif sym1 = "0100110011" and sym2 = "0100110011" then
          -- data island guard band
          t4_dec(sym0, ok, n0);
          if not ok or n0(3 downto 2) /= "11" then fail("island guard band channel 0"); end if;
          check_sync(n0(1 downto 0));
          if st = S_DPRE then
            if run /= 8 then fail("island preamble " & integer'image(run)); end if;
            st := S_DGB1; run := 0; npk := 0; k := 0; first_char := true; n_isl := n_isl + 1;
          elsif st = S_DATA then
            if k /= 0 then fail("partial packet " & integer'image(k)); end if;
            if npk = 0 then fail("island without packets"); end if;
            st := S_DGB2; run := 0;
          elsif st /= S_DGB1 and st /= S_DGB2 then
            fail("guard band in " & st_t'image(st));
          end if;
          run := run + 1;
          if run > 2 then fail("island guard band longer than 2"); end if;
        else
          -- packet character
          if st = S_DGB1 then
            if run /= 2 then fail("leading guard band " & integer'image(run)); end if;
            st := S_DATA;
          end if;
          if st /= S_DATA then fail("TERC4 outside an island (state " & st_t'image(st) & ")"); end if;
          t4_dec(sym0, ok, n0);
          if not ok then fail("channel 0 not TERC4"); end if;
          t4_dec(sym1, ok1, n1);
          t4_dec(sym2, ok2, n2);
          if not ok1 or not ok2 then fail("channel 1/2 not TERC4"); end if;
          check_sync(n0(1 downto 0));
          if (n0(3) = '0') /= first_char then fail("D3 of channel 0"); end if;
          first_char := false;
          hdr(k) := n0(2);
          for i in 0 to 3 loop
            sp(i)(2 * k) := n1(i);
            sp(i)(2 * k + 1) := n2(i);
          end loop;
          if k = 31 then
            packet_done; k := 0; npk := npk + 1;
          else
            k := k + 1;
          end if;
        end if;
      end if;
    end loop;

    report "islands " & integer'image(n_isl) & ", lines " & integer'image(n_lines) & ", packets: ACR " & integer'image(n_acr) &
           ", audio " & integer'image(n_asp) & " (" & integer'image(rx_n) & " of " & integer'image(exp_n) & " samples), AVI " &
           integer'image(n_avi) & ", audio IF " & integer'image(n_aif) & ", null " & integer'image(n_null) &
           ", drops " & integer'image(to_integer(unsigned(drops)));
    if HT - HA - HFP < 92 then
      -- island start (2) + island (76) + control period (4) + video preamble and guard (10)
      assert n_isl = 0 report "island without room" severity failure;
    else
      assert n_acr >= P_AF * P_MS - 2 report "too few ACR packets" severity failure;
      assert n_avi >= 8 and n_aif >= 8 report "too few InfoFrames" severity failure;
      assert rx_n + 8 >= exp_n and rx_n > 40 * P_AF * P_MS report "audio samples missing" severity failure;
      assert b_seen report "no B flag" severity failure;
      assert unsigned(drops) = 0 report "samples dropped" severity failure;
    end if;
    report "PASS";
    wait;
  end process;

end architecture tb;

-------------------------------------------------------------------------------
-- hdmi_tx_neg_tb: the same with active-low hsync (CEA modes below 720p)
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity hdmi_tx_neg_tb is
end entity;

architecture tb of hdmi_tx_neg_tb is
begin
  neg : entity work.hdmi_tx_tb generic map (P_HPOL => '0', P_MS => 3);
end architecture tb;

-------------------------------------------------------------------------------
-- hdmi_tx_fast_tb: 8 times the audio rate, two samples per Audio Sample Packet
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity hdmi_tx_fast_tb is
end entity;

architecture tb of hdmi_tx_fast_tb is
begin
  fast : entity work.hdmi_tx_tb generic map (P_AF => 8, P_MS => 3);
end architecture tb;

-------------------------------------------------------------------------------
-- hdmi_tx_short_tb: horizontal blanking too short for a data island (DVI-like)
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity hdmi_tx_short_tb is
end entity;

architecture tb of hdmi_tx_short_tb is
begin
  short : entity work.hdmi_tx_tb generic map (P_HBP => 20, P_MS => 1);
end architecture tb;
