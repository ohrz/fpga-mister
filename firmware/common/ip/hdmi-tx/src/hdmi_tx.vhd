-------------------------------------------------------------------------------
-- Title      : HDMI transmitter, symbol level (video + data islands)
-- Project    : fpga-mister (hdmi-tx)
-------------------------------------------------------------------------------
-- File       : hdmi_tx.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-29
-------------------------------------------------------------------------------
-- Description:
--   Turns a video stream (de, hs, vs, 24-bit pixel in the RBG order of
--   rgb2dvi: red 23:16, blue 15:8, green 7:0) and 48 kHz stereo samples into
--   the three 10-bit TMDS symbols per pixel clock of HDMI 1.4 (channel 0
--   blue, 1 green, 2 red; serialisation in hdmi_out).  README.md.
--
--   Video is delayed by C_LA clocks; the undelayed de is the look-ahead for
--   the video preamble (8 clocks, CTL0..3 = 1000) and the video guard band
--   (2 clocks) right before every active line.  Disparity restarts outside
--   video (tmds_enc).
--
--   One data island per line (G_HDMI): C_DI_START clocks after the active
--   edge of hsync (polarity measured: the shorter level is active), when the
--   line has had at least 4 control clocks since de fell and the active
--   video of the previous lines starts late enough for the island, a control
--   period of 4 and the video preamble (no island before the first active
--   line; a line that starts earlier than the previous ones cuts the island).  Island = preamble 8 (CTL0..3 =
--   1010), leading guard 2, two packets of 32 clocks, trailing guard 2:
--     packet 1: Audio Clock Regeneration when a new CTS is due, otherwise
--               AVI InfoFrame / Audio InfoFrame when due (every 64 lines),
--               otherwise Null
--     packet 2: Audio Sample Packet (up to 4 samples), Null without samples
--   Packet char k (0..31): channel 0 TERC4 {D3 = 0 only for the first char
--   of the island, D2 = header bit k or ECC, vsync, hsync}; channels 1 and 2:
--   bit i = even / odd bit 2k / 2k+1 of subpacket i, then its ECC.
--   AVI InfoFrame: RGB, 16:9, full range (Q = 2, the source sends 0..255),
--   VIC G_VIC.  Audio InfoFrame: 2 channels, coding and rate from the stream.
--   G_HDMI = false: DVI (no islands), as rgb2dvi.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.hdmi_pkg.all;

entity hdmi_tx is
  generic (
    G_HDMI : boolean  := true;
    G_VIC  : natural  := 4;            -- CEA-861 video code (4 = 1280x720p60)
    G_N    : positive := 6144          -- ACR N, 48 kHz
  );
  port (
    clk      : in  std_logic;          -- pixel clock
    rst      : in  std_logic;          -- synchronous
    vid_data : in  std_logic_vector(23 downto 0);
    vid_de   : in  std_logic;
    vid_hs   : in  std_logic;
    vid_vs   : in  std_logic;
    s_valid  : in  std_logic;          -- audio sample (i2s_rx)
    s_left   : in  std_logic_vector(15 downto 0);
    s_right  : in  std_logic_vector(15 downto 0);
    sym0     : out std_logic_vector(9 downto 0);
    sym1     : out std_logic_vector(9 downto 0);
    sym2     : out std_logic_vector(9 downto 0);
    drops    : out std_logic_vector(15 downto 0)   -- audio samples lost (debug)
  );
end entity hdmi_tx;

architecture rtl of hdmi_tx is

  constant C_LA       : natural := 11;            -- video delay = look-ahead
  constant C_DI_START : natural := 2;             -- island start after the hsync edge
  constant C_DI_LEN   : natural := 8 + 2 + 2 * 32 + 2;
  constant C_DI_ROOM  : natural := C_DI_START + C_DI_LEN + 4 + 10;

  -- InfoFrame packets: header and the 4 subpackets (byte j of subpacket k = PB(7k + j))
  type bytes_t is array (natural range <>) of natural range 0 to 255;

  function checksum(b : bytes_t) return natural is
    variable s : natural := 0;
  begin
    for i in b'range loop
      s := (s + b(i)) mod 256;
    end loop;
    return (256 - s) mod 256;
  end function;

  function if_hdr(t, v, l : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(l, 8)) & std_logic_vector(to_unsigned(v, 8)) &
           std_logic_vector(to_unsigned(t, 8));
  end function;

  -- pb: PB1.. (the checksum PB0 is computed over the header and pb)
  function if_sub(t, v, l : natural; pb : bytes_t) return std_logic_vector is
    variable all_b : bytes_t(0 to 27) := (others => 0);
    variable r     : std_logic_vector(4 * 56 - 1 downto 0) := (others => '0');
    variable hb    : bytes_t(0 to 2 + pb'length);
  begin
    hb(0) := t;
    hb(1) := v;
    hb(2) := l;
    for i in 0 to pb'length - 1 loop
      hb(3 + i)    := pb(pb'low + i);
      all_b(1 + i) := pb(pb'low + i);
    end loop;
    all_b(0) := checksum(hb);
    for k in 0 to 3 loop
      for j in 0 to 6 loop
        r(56 * k + 8 * j + 7 downto 56 * k + 8 * j) := std_logic_vector(to_unsigned(all_b(7 * k + j), 8));
      end loop;
    end loop;
    return r;
  end function;

  constant C_AVI_PB : bytes_t(1 to 13) := (16#00#, 16#28#, 16#08#, G_VIC, others => 0);
  constant C_AIF_PB : bytes_t(1 to 10) := (16#01#, others => 0);
  constant C_AVI_HDR : std_logic_vector(23 downto 0) := if_hdr(16#82#, 2, 13);
  constant C_AVI_SUB : std_logic_vector(4 * 56 - 1 downto 0) := if_sub(16#82#, 2, 13, C_AVI_PB);
  constant C_AIF_HDR : std_logic_vector(23 downto 0) := if_hdr(16#84#, 1, 10);
  constant C_AIF_SUB : std_logic_vector(4 * 56 - 1 downto 0) := if_sub(16#84#, 1, 10, C_AIF_PB);

  function acr_sub(cts : std_logic_vector(19 downto 0)) return std_logic_vector is
    variable n : std_logic_vector(19 downto 0);
    variable s : std_logic_vector(55 downto 0);
  begin
    n := std_logic_vector(to_unsigned(G_N, 20));
    s := n(7 downto 0) & n(15 downto 8) & "0000" & n(19 downto 16) &
         cts(7 downto 0) & cts(15 downto 8) & "0000" & cts(19 downto 16) & x"00";
    return s & s & s & s;
  end function;

  -- delayed video
  type dl_t is array (0 to C_LA - 1) of std_logic_vector(26 downto 0);
  signal dl : dl_t := (others => (others => '0'));
  signal i_de_q : std_logic := '0';
  signal d_data : std_logic_vector(23 downto 0);
  signal d_de, d_hs, d_vs : std_logic;

  -- hsync polarity
  signal hs_q   : std_logic := '0';
  signal run    : unsigned(11 downto 0) := (others => '0');
  signal run_hi : unsigned(11 downto 0) := (others => '1');
  signal run_lo : unsigned(11 downto 0) := (others => '1');
  signal hs_pol : std_logic := '1';
  signal hs_act_q : std_logic := '0';

  -- line position of the delayed stream
  signal hcnt    : unsigned(11 downto 0) := (others => '1');
  signal de_q    : std_logic := '0';
  signal de_pos  : unsigned(11 downto 0) := (others => '0');
  signal de_posv : std_logic := '0';
  signal de_low  : unsigned(3 downto 0) := (others => '0');
  signal lines   : unsigned(5 downto 0) := (others => '0');

  -- video preamble / guard
  signal vp_act : std_logic := '0';
  signal vcnt   : unsigned(3 downto 0) := (others => '0');

  -- data island
  signal di_act : std_logic := '0';
  signal icnt   : unsigned(6 downto 0) := (others => '0');
  signal avi_pend, aif_pend : std_logic := '0';

  -- packet being sent
  type sub_array_t is array (0 to 3) of std_logic_vector(55 downto 0);
  type ecc_array_t is array (0 to 3) of std_logic_vector(7 downto 0);
  signal pk_hdr : std_logic_vector(23 downto 0) := (others => '0');
  signal pk_sub : sub_array_t := (others => (others => '0'));
  signal pk_eh  : std_logic_vector(7 downto 0) := (others => '0');
  signal pk_es  : ecc_array_t := (others => (others => '0'));
  signal pk_k   : unsigned(4 downto 0) := (others => '0');

  -- audio
  signal asp_hdr  : std_logic_vector(23 downto 0);
  signal asp_sub  : std_logic_vector(4 * 56 - 1 downto 0);
  signal asp_take : std_logic;
  signal acr_due  : std_logic;
  signal acr_cts  : std_logic_vector(19 downto 0);
  signal acr_take : std_logic;
  signal load1, load2 : std_logic;

  -- symbols outside video, the encoders' input
  signal s0, s1, s2 : sym_t;

begin

  audio : entity work.hdmi_audio
    generic map (G_N => G_N)
    port map (
      clk => clk, rst => rst,
      s_valid => s_valid, s_left => s_left, s_right => s_right,
      asp_hdr => asp_hdr, asp_sub => asp_sub, asp_take => asp_take,
      acr_due => acr_due, acr_cts => acr_cts, acr_take => acr_take,
      drops => drops);

  -- packet loads (at the last character before the packet); the takes act
  -- on the same edge, so a sample arriving with the load goes to the next packet
  load1    <= '1' when di_act = '1' and icnt = 9 and d_de = '0' and vp_act = '0' else '0';
  load2    <= '1' when di_act = '1' and icnt = 9 + 32 and d_de = '0' and vp_act = '0' else '0';
  asp_take <= load2;
  acr_take <= load1 and acr_due;

  d_data <= dl(C_LA - 1)(23 downto 0);
  d_de   <= dl(C_LA - 1)(24);
  d_hs   <= dl(C_LA - 1)(25);
  d_vs   <= dl(C_LA - 1)(26);

  process (clk)
    variable hs_act : std_logic;
    variable p0, p1 : std_logic_vector(7 downto 0);
    variable acr    : std_logic_vector(4 * 56 - 1 downto 0);
  begin
    if rising_edge(clk) then
      -- delay line; vid_de one clk later is the look-ahead reference
      dl(0) <= vid_vs & vid_hs & vid_de & vid_data;
      for i in 1 to C_LA - 1 loop
        dl(i) <= dl(i - 1);
      end loop;
      i_de_q <= vid_de;

      -- hsync polarity: run lengths of both levels at the input
      hs_q <= vid_hs;
      if vid_hs /= hs_q then
        run <= to_unsigned(1, run'length);
        if hs_q = '1' then
          run_hi <= run;
        else
          run_lo <= run;
        end if;
      elsif run < 4095 then
        run <= run + 1;
      end if;
      if run_hi < run_lo then
        hs_pol <= '1';
      elsif run_lo < run_hi then
        hs_pol <= '0';
      end if;

      -- video preamble and guard band: vid_de rises C_LA clocks before d_de
      -- (dl(0) holds it one clk later, d_de C_LA clks later); preamble at the
      -- next 8 clocks, guard band at the 2 after, then video
      if vp_act = '1' then
        if vcnt = 9 then
          vp_act <= '0';
        end if;
        vcnt <= vcnt + 1;
      end if;
      if vid_de = '1' and i_de_q = '0' then
        vp_act <= '1';
        vcnt   <= (others => '0');
      end if;

      -- line position of the delayed stream
      if d_hs = hs_pol then
        hs_act := '1';
      else
        hs_act := '0';
      end if;
      hs_act_q <= hs_act;
      de_q <= d_de;
      if hs_act = '1' and hs_act_q = '0' then
        hcnt  <= (others => '0');
        lines <= lines + 1;
        if lines = 0 then
          avi_pend <= '1';
          aif_pend <= '1';
        end if;
      elsif hcnt < 4095 then
        hcnt <= hcnt + 1;
      end if;
      if d_de = '1' and de_q = '0' then
        de_pos  <= hcnt;
        de_posv <= '1';
      end if;
      if d_de = '1' then
        de_low <= (others => '0');
      elsif de_low < 15 then
        de_low <= de_low + 1;
      end if;

      -- data island
      if di_act = '1' then
        icnt <= icnt + 1;
        if icnt = C_DI_LEN - 1 then
          di_act <= '0';
        end if;
      elsif G_HDMI and hcnt = C_DI_START - 1 and d_de = '0' and de_low >= 4 and
            de_posv = '1' and de_pos >= C_DI_ROOM then
        di_act <= '1';
        icnt   <= (others => '0');
      end if;
      if d_de = '1' or vp_act = '1' then             -- never across video (cannot happen with de_pos)
        di_act <= '0';
      end if;

      -- packet shift registers and ECC
      if pk_k < 24 then
        pk_eh  <= ecc_step(pk_eh, pk_hdr(0));
        pk_hdr <= '0' & pk_hdr(23 downto 1);
      else
        pk_eh <= '0' & pk_eh(7 downto 1);
      end if;
      for i in 0 to 3 loop
        if pk_k < 28 then
          p0 := ecc_step(pk_es(i), pk_sub(i)(0));
          p1 := ecc_step(p0, pk_sub(i)(1));
          pk_es(i)  <= p1;
          pk_sub(i) <= "00" & pk_sub(i)(55 downto 2);
        else
          pk_es(i) <= "00" & pk_es(i)(7 downto 2);
        end if;
      end loop;
      pk_k <= pk_k + 1;
      if load1 = '1' or load2 = '1' then
        pk_k  <= (others => '0');
        pk_eh <= (others => '0');
        pk_es <= (others => (others => '0'));
        if load1 = '1' then                          -- packet 1
          if acr_due = '1' then
            pk_hdr   <= x"000001";
            acr      := acr_sub(acr_cts);
            for i in 0 to 3 loop
              pk_sub(i) <= acr(56 * i + 55 downto 56 * i);
            end loop;
          elsif avi_pend = '1' then
            pk_hdr <= C_AVI_HDR;
            for i in 0 to 3 loop
              pk_sub(i) <= C_AVI_SUB(56 * i + 55 downto 56 * i);
            end loop;
            avi_pend <= '0';
          elsif aif_pend = '1' then
            pk_hdr <= C_AIF_HDR;
            for i in 0 to 3 loop
              pk_sub(i) <= C_AIF_SUB(56 * i + 55 downto 56 * i);
            end loop;
            aif_pend <= '0';
          else
            pk_hdr <= (others => '0');
            pk_sub <= (others => (others => '0'));
          end if;
        else                                         -- packet 2
          pk_hdr <= asp_hdr;
          for i in 0 to 3 loop
            pk_sub(i) <= asp_sub(56 * i + 55 downto 56 * i);
          end loop;
        end if;
      end if;

      if rst = '1' then
        vp_act   <= '0';
        di_act   <= '0';
        de_posv  <= '0';
        avi_pend <= '0';
        aif_pend <= '0';
        lines    <= (others => '0');
      end if;
    end if;
  end process;

  -- symbols outside video
  process (vp_act, vcnt, di_act, icnt, d_hs, d_vs, pk_k, pk_hdr, pk_eh, pk_sub, pk_es)
    variable sync   : std_logic_vector(1 downto 0);
    variable hb, d3 : std_logic;
    variable n1, n2 : std_logic_vector(3 downto 0);
  begin
    sync := d_vs & d_hs;
    s0 <= ctrl_token(sync);
    s1 <= ctrl_token("00");
    s2 <= ctrl_token("00");
    if vp_act = '1' then
      if vcnt < 8 then
        s1 <= ctrl_token("01");                      -- CTL0 = 1
      else
        s0 <= C_VGB_02;
        s1 <= C_VGB_1;
        s2 <= C_VGB_02;
      end if;
    elsif di_act = '1' then
      if icnt < 8 then
        s1 <= ctrl_token("01");                      -- CTL0 = 1
        s2 <= ctrl_token("01");                      -- CTL2 = 1
      elsif icnt < 10 or icnt >= C_DI_LEN - 2 then
        s0 <= terc4("11" & sync);
        s1 <= C_DGB_12;
        s2 <= C_DGB_12;
      else
        if pk_k < 24 then
          hb := pk_hdr(0);
        else
          hb := pk_eh(0);
        end if;
        for i in 0 to 3 loop
          if pk_k < 28 then
            n1(i) := pk_sub(i)(0);
            n2(i) := pk_sub(i)(1);
          else
            n1(i) := pk_es(i)(0);
            n2(i) := pk_es(i)(1);
          end if;
        end loop;
        if icnt = 10 then
          d3 := '0';
        else
          d3 := '1';
        end if;
        s0 <= terc4(d3 & hb & sync);
        s1 <= terc4(n1);
        s2 <= terc4(n2);
      end if;
    end if;
  end process;

  enc0 : entity work.tmds_enc port map (clk => clk, de => d_de, d => d_data(15 downto 8), sym => s0, q => sym0);
  enc1 : entity work.tmds_enc port map (clk => clk, de => d_de, d => d_data(7 downto 0), sym => s1, q => sym1);
  enc2 : entity work.tmds_enc port map (clk => clk, de => d_de, d => d_data(23 downto 16), sym => s2, q => sym2);

end architecture rtl;
