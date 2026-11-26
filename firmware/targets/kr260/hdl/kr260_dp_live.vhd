-------------------------------------------------------------------------------
-- Title      : KR260 video of the MiSTer designs into the DisplayPort live input
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : kr260_dp_live.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-11-26
-- Platform   : KR260 (Kria K26, Zynq UltraScale+ XCK26)
-- Standard   : VHDL-93 (Vivado module reference), the bench uses VHDL-2008
-------------------------------------------------------------------------------
-- Description:
--   The KR260 has no HDMI output. Its only video output is the DisplayPort
--   of the PS (DPSUB, one lane on PS-GTR lane 1). The PS takes PL video at its
--   live video input: dp_live_video_in_pixel1 (36 bit, 3 x 12 bit),
--   dp_live_video_in_hsync, _vsync, _de and the pixel clock dp_video_in_clk.
--
--     mister_zynq vid_data (R & B & G, 8 bit each), vid_de, vid_hs, vid_vs (clk_pix)
--       -> one register stage -> dp_pixel (3 x 12 bit), dp_de, dp_hs, dp_vs (clk_pix)
--
--   Each 8-bit component goes into bits 11..4 of its 12-bit field. Bits 3..0
--   repeat bits 7..4, so full scale stays full scale in 8 and 12 bpc modes.
--   G_ORDER sets which component goes into which field of dp_pixel:
--     0: R in 35..24, G in 23..12, B in 11..0
--     1: B in 35..24, G in 23..12, R in 11..0
--     2: G in 35..24, B in 23..12, R in 11..0
--   The mapping of the DPSUB live input is not checked on the hardware yet
--   (KR260 bring-up: show color bars and compare). G_HS_INV and G_VS_INV
--   invert the sync outputs. The DRM mode of the DisplayPort must give the
--   same polarity (MiSTer 1280x720@60: both syncs active high).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity kr260_dp_live is
  generic (
    G_ORDER  : integer range 0 to 2 := 0;
    G_HS_INV : boolean := false;
    G_VS_INV : boolean := false
  );
  port (
    clk_pix  : in  std_logic;
    -- from mister_zynq (clk_pix = clk_hdmi), order of rgb2dvi: R & B & G
    vid_data : in  std_logic_vector(23 downto 0);
    vid_de   : in  std_logic;
    vid_hs   : in  std_logic;
    vid_vs   : in  std_logic;
    -- to the live video input of zynq_ultra_ps_e (dp_live_video_in_*)
    dp_pixel : out std_logic_vector(35 downto 0);
    dp_de    : out std_logic;
    dp_hs    : out std_logic;
    dp_vs    : out std_logic
  );
end entity;

architecture rtl of kr260_dp_live is

  function to12 (c : std_logic_vector(7 downto 0)) return std_logic_vector is
  begin
    return c & c(7 downto 4);
  end function;

  signal r, g, b : std_logic_vector(11 downto 0);

begin

  r <= to12(vid_data(23 downto 16));
  b <= to12(vid_data(15 downto 8));
  g <= to12(vid_data(7 downto 0));

  process (clk_pix)
  begin
    if rising_edge(clk_pix) then
      case G_ORDER is
        when 1      => dp_pixel <= b & g & r;
        when 2      => dp_pixel <= g & b & r;
        when others => dp_pixel <= r & g & b;
      end case;
      dp_de <= vid_de;
      if G_HS_INV then dp_hs <= not vid_hs; else dp_hs <= vid_hs; end if;
      if G_VS_INV then dp_vs <= not vid_vs; else dp_vs <= vid_vs; end if;
    end if;
  end process;

end architecture;
