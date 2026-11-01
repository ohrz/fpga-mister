-------------------------------------------------------------------------------
-- Title      : HDMI output with audio (module reference of the _hdmi designs)
-- Project    : fpga-mister (hdmi-tx)
-------------------------------------------------------------------------------
-- File       : hdmi_out.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-29
-------------------------------------------------------------------------------
-- Description:
--   HDMI transmitter for 7-series pins (module reference in a block design,
--   drop-in for rgb2dvi: same video inputs and pin order, plus I2S sound):
--   i2s_rx samples the I2S stream (it may also drive a codec in parallel),
--   hdmi_tx builds the symbols, one 10:1 serializer per channel (OSERDESE2
--   master/slave, DDR, bit 0 first, as rgb2dvi) drives the TMDS_33 pins.
--   clk_ser = 5 * clk_pix from the same MMCM; locked resets everything
--   (asynchronous assertion, release synchronous to clk_pix).  README.md.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

entity hdmi_out is
  generic (
    G_HDMI : boolean  := true;         -- false: DVI (no data islands)
    G_VIC  : natural  := 4             -- AVI InfoFrame video code (4 = 1280x720p60)
  );
  port (
    clk_pix   : in  std_logic;
    clk_ser   : in  std_logic;         -- 5 * clk_pix
    locked    : in  std_logic;         -- MMCM of both clocks
    vid_data  : in  std_logic_vector(23 downto 0);  -- RBG order of rgb2dvi
    vid_de    : in  std_logic;
    vid_hs    : in  std_logic;
    vid_vs    : in  std_logic;
    i2s_bclk  : in  std_logic;         -- asynchronous (clk_audio)
    i2s_lrclk : in  std_logic;
    i2s_data  : in  std_logic;
    tx_clk_p  : out std_logic;
    tx_clk_n  : out std_logic;
    tx_data_p : out std_logic_vector(2 downto 0);
    tx_data_n : out std_logic_vector(2 downto 0)
  );
end entity hdmi_out;

architecture rtl of hdmi_out is

  signal rst_s : std_logic_vector(1 downto 0) := "11";
  signal rst   : std_logic;

  signal s_valid : std_logic;
  signal s_left, s_right : std_logic_vector(15 downto 0);

  type sym3_t is array (0 to 3) of std_logic_vector(9 downto 0);
  signal sym : sym3_t;                 -- 0..2 data channels, 3 clock

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of rst_s : signal is "TRUE";

begin

  -- reset bridge
  process (clk_pix, locked)
  begin
    if locked = '0' then
      rst_s <= "11";
    elsif rising_edge(clk_pix) then
      rst_s <= rst_s(0) & '0';
    end if;
  end process;
  rst <= rst_s(1);

  rx : entity work.i2s_rx
    generic map (G_BITS => 16)
    port map (clk => clk_pix, bclk => i2s_bclk, lrclk => i2s_lrclk, sdata => i2s_data,
              left => s_left, right => s_right, valid => s_valid);

  tx : entity work.hdmi_tx
    generic map (G_HDMI => G_HDMI, G_VIC => G_VIC)
    port map (clk => clk_pix, rst => rst,
              vid_data => vid_data, vid_de => vid_de, vid_hs => vid_hs, vid_vs => vid_vs,
              s_valid => s_valid, s_left => s_left, s_right => s_right,
              sym0 => sym(0), sym1 => sym(1), sym2 => sym(2), drops => open);

  sym(3) <= "1111100000";              -- clock channel as rgb2dvi

  g_ser : for c in 0 to 3 generate
    signal oq, sh1, sh2 : std_logic;
  begin
    master : OSERDESE2
      generic map (DATA_RATE_OQ => "DDR", DATA_RATE_TQ => "SDR", DATA_WIDTH => 10, TRISTATE_WIDTH => 1,
                   TBYTE_CTL => "FALSE", TBYTE_SRC => "FALSE", SERDES_MODE => "MASTER")
      port map (OFB => open, OQ => oq, SHIFTOUT1 => open, SHIFTOUT2 => open, TBYTEOUT => open, TFB => open,
                TQ => open, CLK => clk_ser, CLKDIV => clk_pix,
                D1 => sym(c)(0), D2 => sym(c)(1), D3 => sym(c)(2), D4 => sym(c)(3),
                D5 => sym(c)(4), D6 => sym(c)(5), D7 => sym(c)(6), D8 => sym(c)(7),
                OCE => '1', RST => rst, SHIFTIN1 => sh1, SHIFTIN2 => sh2,
                T1 => '0', T2 => '0', T3 => '0', T4 => '0', TBYTEIN => '0', TCE => '0');
    slave : OSERDESE2
      generic map (DATA_RATE_OQ => "DDR", DATA_RATE_TQ => "SDR", DATA_WIDTH => 10, TRISTATE_WIDTH => 1,
                   TBYTE_CTL => "FALSE", TBYTE_SRC => "FALSE", SERDES_MODE => "SLAVE")
      port map (OFB => open, OQ => open, SHIFTOUT1 => sh1, SHIFTOUT2 => sh2, TBYTEOUT => open, TFB => open,
                TQ => open, CLK => clk_ser, CLKDIV => clk_pix,
                D1 => '0', D2 => '0', D3 => sym(c)(8), D4 => sym(c)(9),
                D5 => '0', D6 => '0', D7 => '0', D8 => '0',
                OCE => '1', RST => rst, SHIFTIN1 => '0', SHIFTIN2 => '0',
                T1 => '0', T2 => '0', T3 => '0', T4 => '0', TBYTEIN => '0', TCE => '0');
    g_data : if c < 3 generate
      buf : OBUFDS generic map (IOSTANDARD => "TMDS_33") port map (I => oq, O => tx_data_p(c), OB => tx_data_n(c));
    end generate;
    g_clk : if c = 3 generate
      buf : OBUFDS generic map (IOSTANDARD => "TMDS_33") port map (I => oq, O => tx_clk_p, OB => tx_clk_n);
    end generate;
  end generate;

end architecture rtl;
