-------------------------------------------------------------------------------
-- Title      : ZCU106 HDMI output of the MiSTer designs (TMDS over GTH quad 223)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : zcu106_hdmi.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-11-07
-- Platform   : ZCU106 (Zynq UltraScale+ XCZU7EV)
-- Standard   : VHDL-2008
-------------------------------------------------------------------------------
-- Description:
--   The ZCU106 has no TMDS-capable I/O: its HDMI output is three GTH lanes of
--   quad 223 (TX0..TX2) and an LVDS clock lane into the DP159 retimer (U94).
--   This block replaces hdmi_out of firmware/common/ip/hdmi-tx
--   for the board and keeps its symbol generator hdmi_tx and i2s_rx:
--
--     clk_100 --> zcu106_hdmi_ctl (I2C): Si5324 free run 148.5 MHz, DP159, TX_EN
--     Si5324 --> MGTREFCLK0_223 --> IBUFDS_GTE4 --+--> CPLL of the three channels
--                                                 +--> ODIV2 -> BUFG_GT /2 -> clk_pix 74.25 MHz
--     vid_*, i2s_* (clk_pix) -> i2s_rx, hdmi_tx -> sym0..2 (10 bit, clk_pix)
--     -> pairs (60 bit every other clk_pix) -> async_word_fifo -> TXUSRCLK2 (37.125 MHz)
--     -> gtwizard (20 bit raw per lane, 742.5 Mb/s) -> HDMI_TX0..2
--     clk_pix -> ODDRE1 -> OBUFDS -> HDMI_TX_LVDS_OUT (TMDS clock = pixel clock)
--
--   The first symbol of a pair goes into bits 9..0 (the GTH sends the LSB of
--   TXDATA first, TMDS sends bit 0 first).  The fixed mode is 1280x720@60
--   (sys_top of the Zybo designs); a different pixel clock needs another
--   Si5324 setting and line rate.
--   clk_pix only runs after the Si5324 is programmed (the I2C takes a few
--   hundred ms after configuration); pix_ready tells when the output path is up.
--
--   The transceiver is the IP zcu106_gth_tx (gtwizard_ultrascale, created by
--   the board generator scripts/2025.2/zcu106_mister.tcl: channels X0Y0..X0Y2,
--   CPLL from 148.5 MHz, 0.7425 Gb/s, raw 20 bit, user clocking and reset in
--   the core, free-running/DRP clock 25 MHz).
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity zcu106_hdmi is
  generic (
    G_HDMI       : boolean := true;    -- false: DVI (no data islands)
    G_VIC        : natural := 4;       -- AVI InfoFrame video code (4 = 1280x720p60)
    G_TXPOLARITY : std_logic_vector(2 downto 0) := "000"   -- per lane, '1' inverts
  );
  port (
    clk_100       : in    std_logic;   -- I2C controller
    clk_free      : in    std_logic;   -- 25 MHz: GT reset controller and DRP
    rst_100       : in    std_logic;   -- synchronous to clk_100, active high
    -- video (clk_pix) and audio (I2S, asynchronous)
    clk_pix       : out   std_logic;
    pix_ready     : out   std_logic;   -- clk_pix runs, transceiver up (clk_pix domain)
    vid_data      : in    std_logic_vector(23 downto 0);   -- RBG order of rgb2dvi
    vid_de        : in    std_logic;
    vid_hs        : in    std_logic;
    vid_vs        : in    std_logic;
    i2s_bclk      : in    std_logic;
    i2s_lrclk     : in    std_logic;
    i2s_data      : in    std_logic;
    -- board
    gt_refclk_p   : in    std_logic;   -- HDMI_SI5324_OUT_C (MGTREFCLK0_223)
    gt_refclk_n   : in    std_logic;
    gt_rx_p       : in    std_logic_vector(2 downto 0);    -- HDMI_RX0..2 (unused, the channels need them)
    gt_rx_n       : in    std_logic_vector(2 downto 0);
    gt_tx_p       : out   std_logic_vector(2 downto 0);    -- HDMI_TX0..2
    gt_tx_n       : out   std_logic_vector(2 downto 0);
    tx_lvds_p      : out   std_logic;   -- HDMI_TX_LVDS_OUT
    tx_lvds_n      : out   std_logic;
    ctl_scl       : inout std_logic;   -- HDMI_CTL I2C
    ctl_sda       : inout std_logic;
    si5324_rst_n  : out   std_logic;
    si5324_lol    : in    std_logic;
    tx_en         : out   std_logic;   -- DP159 output enable
    -- status (clk_100 domain): 0 I2C done, 1 I2C error, 2 GT TX reset done,
    -- 3 all GT power good, 4 FIFO reader running, 5 FIFO underflow seen
    status        : out   std_logic_vector(5 downto 0);
    -- diagnosis word (clk_100 domain, aux word of hps_bus_axi): (15:0) status of
    -- zcu106_hdmi_ctl (ROM index, state, attempt, LOL; after an error the step
    -- that failed), (21:16) status above, (25:22) cause of the last failed
    -- attempt (0 SCL held low, 1 NACK, 2 check, 3 no lock), (26) SCL, (27) SDA
    -- on the pins, (30:28) step of the transaction that failed (1 address,
    -- 2 register, ...), (31) 0
    dbg           : out   std_logic_vector(31 downto 0)
  );
end entity zcu106_hdmi;

architecture rtl of zcu106_hdmi is

  component zcu106_gth_tx
    port (
      gtwiz_userclk_tx_reset_in          : in  std_logic_vector(0 downto 0);
      gtwiz_userclk_tx_srcclk_out        : out std_logic_vector(0 downto 0);
      gtwiz_userclk_tx_usrclk_out        : out std_logic_vector(0 downto 0);
      gtwiz_userclk_tx_usrclk2_out       : out std_logic_vector(0 downto 0);
      gtwiz_userclk_tx_active_out        : out std_logic_vector(0 downto 0);
      gtwiz_userclk_rx_reset_in          : in  std_logic_vector(0 downto 0);
      gtwiz_userclk_rx_srcclk_out        : out std_logic_vector(0 downto 0);
      gtwiz_userclk_rx_usrclk_out        : out std_logic_vector(0 downto 0);
      gtwiz_userclk_rx_usrclk2_out       : out std_logic_vector(0 downto 0);
      gtwiz_userclk_rx_active_out        : out std_logic_vector(0 downto 0);
      gtwiz_reset_clk_freerun_in         : in  std_logic_vector(0 downto 0);
      gtwiz_reset_all_in                 : in  std_logic_vector(0 downto 0);
      gtwiz_reset_tx_pll_and_datapath_in : in  std_logic_vector(0 downto 0);
      gtwiz_reset_tx_datapath_in         : in  std_logic_vector(0 downto 0);
      gtwiz_reset_rx_pll_and_datapath_in : in  std_logic_vector(0 downto 0);
      gtwiz_reset_rx_datapath_in         : in  std_logic_vector(0 downto 0);
      gtwiz_reset_rx_cdr_stable_out      : out std_logic_vector(0 downto 0);
      gtwiz_reset_tx_done_out            : out std_logic_vector(0 downto 0);
      gtwiz_reset_rx_done_out            : out std_logic_vector(0 downto 0);
      gtwiz_userdata_tx_in               : in  std_logic_vector(59 downto 0);
      gtwiz_userdata_rx_out              : out std_logic_vector(59 downto 0);
      drpclk_in                          : in  std_logic_vector(2 downto 0);
      gthrxn_in                          : in  std_logic_vector(2 downto 0);
      gthrxp_in                          : in  std_logic_vector(2 downto 0);
      gtrefclk0_in                       : in  std_logic_vector(2 downto 0);
      txpolarity_in                      : in  std_logic_vector(2 downto 0);
      gthtxn_out                         : out std_logic_vector(2 downto 0);
      gthtxp_out                         : out std_logic_vector(2 downto 0);
      gtpowergood_out                    : out std_logic_vector(2 downto 0);
      rxpmaresetdone_out                 : out std_logic_vector(2 downto 0);
      txpmaresetdone_out                 : out std_logic_vector(2 downto 0)
    );
  end component;

  -- I2C
  signal scl_i, scl_o, scl_t, sda_i, sda_o, sda_t : std_logic;
  signal ctl_done, ctl_error : std_logic;

  -- clocks
  signal refclk, refclk_div2 : std_logic;
  signal clk_pix_i           : std_logic;
  signal usrclk2             : std_logic;

  -- transceiver
  signal gt_reset_all     : std_logic := '1';
  signal gt_done_free     : std_logic;
  signal gt_tx_done       : std_logic_vector(0 downto 0);
  signal gt_pg            : std_logic_vector(2 downto 0);
  signal txpmaresetdone   : std_logic_vector(2 downto 0);
  signal userclk_tx_reset : std_logic;
  signal tx_data          : std_logic_vector(59 downto 0);
  signal ctl_done_free    : std_logic_vector(1 downto 0) := "00";

  -- pixel domain
  signal pix_rst_s : std_logic_vector(1 downto 0) := "11";
  signal pix_rst   : std_logic;
  signal s_valid   : std_logic;
  signal s_left, s_right : std_logic_vector(15 downto 0);
  type sym_t is array (0 to 2) of std_logic_vector(9 downto 0);
  signal sym, sym_first  : sym_t;
  signal phase    : std_logic := '0';
  signal wr_en    : std_logic := '0';
  signal wr_word  : std_logic_vector(59 downto 0) := (others => '0');

  -- TXUSRCLK2 domain
  signal usr_rst_s : std_logic_vector(1 downto 0) := "11";
  signal fifo_run, fifo_under : std_logic;

  -- status into clk_100
  signal st_meta, st_sync : std_logic_vector(3 downto 0) := (others => '0');
  signal ctl_status : std_logic_vector(15 downto 0);
  signal ctl_diag   : std_logic_vector(8 downto 0);

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of ctl_done_free, pix_rst_s, usr_rst_s, st_meta, st_sync : signal is "TRUE";

begin

  -----------------------------------------------------------------------------
  -- HDMI_CTL: Si5324 and DP159 over I2C (clk_100)
  -----------------------------------------------------------------------------
  ctl : entity work.zcu106_hdmi_ctl
    -- 200 ms from RST high to the first access: the Linux driver of a Linux HDMI design
    -- reaches the Si5324 seconds after configuration, the datasheet time was not at hand
    generic map (G_CLK_HZ => 100_000_000, G_RST_WAIT_MS => 200)
    port map (
      clk => clk_100, rst => rst_100,
      scl_i => scl_i, scl_o => scl_o, scl_t => scl_t,
      sda_i => sda_i, sda_o => sda_o, sda_t => sda_t,
      si5324_rst_n => si5324_rst_n, si5324_lol => si5324_lol,
      tx_en => tx_en, done => ctl_done, err => ctl_error, status => ctl_status,
      diag => ctl_diag);

  scl_buf : IOBUF port map (I => scl_o, O => scl_i, T => scl_t, IO => ctl_scl);
  sda_buf : IOBUF port map (I => sda_o, O => sda_i, T => sda_t, IO => ctl_sda);

  -----------------------------------------------------------------------------
  -- reference clock: CPLL input and pixel clock (148.5 MHz / 2)
  -----------------------------------------------------------------------------
  refbuf : IBUFDS_GTE4
    generic map (REFCLK_EN_TX_PATH => '0', REFCLK_HROW_CK_SEL => "00", REFCLK_ICNTL_RX => "00")
    port map (I => gt_refclk_p, IB => gt_refclk_n, CEB => '0', O => refclk, ODIV2 => refclk_div2);

  pixbuf : BUFG_GT
    port map (I => refclk_div2, CE => '1', CEMASK => '0', CLR => '0', CLRMASK => '0',
              DIV => "001", O => clk_pix_i);
  clk_pix <= clk_pix_i;

  -----------------------------------------------------------------------------
  -- transceiver: reset after the Si5324 runs (clk_free domain)
  -----------------------------------------------------------------------------
  process (clk_free)
  begin
    if rising_edge(clk_free) then
      ctl_done_free <= ctl_done_free(0) & ctl_done;
      gt_reset_all  <= not ctl_done_free(1);
    end if;
  end process;

  userclk_tx_reset <= not (txpmaresetdone(0) and txpmaresetdone(1) and txpmaresetdone(2));

  gth : zcu106_gth_tx
    port map (
      gtwiz_userclk_tx_reset_in(0)          => userclk_tx_reset,
      gtwiz_userclk_tx_srcclk_out           => open,
      gtwiz_userclk_tx_usrclk_out           => open,
      gtwiz_userclk_tx_usrclk2_out(0)       => usrclk2,
      gtwiz_userclk_tx_active_out           => open,
      gtwiz_userclk_rx_reset_in(0)          => '1',
      gtwiz_userclk_rx_srcclk_out           => open,
      gtwiz_userclk_rx_usrclk_out           => open,
      gtwiz_userclk_rx_usrclk2_out          => open,
      gtwiz_userclk_rx_active_out           => open,
      gtwiz_reset_clk_freerun_in(0)         => clk_free,
      gtwiz_reset_all_in(0)                 => gt_reset_all,
      gtwiz_reset_tx_pll_and_datapath_in(0) => '0',
      gtwiz_reset_tx_datapath_in(0)         => '0',
      gtwiz_reset_rx_pll_and_datapath_in(0) => '0',
      gtwiz_reset_rx_datapath_in(0)         => '0',
      gtwiz_reset_rx_cdr_stable_out         => open,
      gtwiz_reset_tx_done_out               => gt_tx_done,
      gtwiz_reset_rx_done_out               => open,
      gtwiz_userdata_tx_in                  => tx_data,
      gtwiz_userdata_rx_out                 => open,
      drpclk_in                             => (others => clk_free),
      gthrxn_in                             => gt_rx_n,
      gthrxp_in                             => gt_rx_p,
      gtrefclk0_in                          => (others => refclk),
      txpolarity_in                         => G_TXPOLARITY,
      gthtxn_out                            => gt_tx_n,
      gthtxp_out                            => gt_tx_p,
      gtpowergood_out                       => gt_pg,
      rxpmaresetdone_out                    => open,
      txpmaresetdone_out                    => txpmaresetdone);

  gt_done_free <= gt_tx_done(0);

  -----------------------------------------------------------------------------
  -- pixel domain: symbols, pairs into the FIFO
  -----------------------------------------------------------------------------
  process (clk_pix_i)
  begin
    if rising_edge(clk_pix_i) then
      pix_rst_s <= pix_rst_s(0) & not gt_done_free;
    end if;
  end process;
  pix_rst   <= pix_rst_s(1);
  pix_ready <= not pix_rst;

  rx : entity work.i2s_rx
    generic map (G_BITS => 16)
    port map (clk => clk_pix_i, bclk => i2s_bclk, lrclk => i2s_lrclk, sdata => i2s_data,
              left => s_left, right => s_right, valid => s_valid);

  tx : entity work.hdmi_tx
    generic map (G_HDMI => G_HDMI, G_VIC => G_VIC)
    port map (clk => clk_pix_i, rst => pix_rst,
              vid_data => vid_data, vid_de => vid_de, vid_hs => vid_hs, vid_vs => vid_vs,
              s_valid => s_valid, s_left => s_left, s_right => s_right,
              sym0 => sym(0), sym1 => sym(1), sym2 => sym(2), drops => open);

  process (clk_pix_i)
  begin
    if rising_edge(clk_pix_i) then
      wr_en <= '0';
      if pix_rst = '1' then
        phase <= '0';
      else
        phase <= not phase;
        if phase = '0' then
          sym_first <= sym;
        else
          for l in 0 to 2 loop
            wr_word(20 * l + 19 downto 20 * l) <= sym(l) & sym_first(l);
          end loop;
          wr_en <= '1';
        end if;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- TXUSRCLK2 domain
  -----------------------------------------------------------------------------
  process (usrclk2)
  begin
    if rising_edge(usrclk2) then
      usr_rst_s <= usr_rst_s(0) & not gt_done_free;
    end if;
  end process;

  fifo : entity work.async_word_fifo
    generic map (G_WIDTH => 60, G_ABITS => 4, G_START => 4)
    port map (wr_clk => clk_pix_i, wr_rst => pix_rst, wr_en => wr_en, wr_data => wr_word, wr_full => open,
              rd_clk => usrclk2, rd_rst => usr_rst_s(1), rd_data => tx_data,
              rd_run => fifo_run, rd_under => fifo_under);

  -----------------------------------------------------------------------------
  -- TMDS clock lane
  -----------------------------------------------------------------------------
  clk_ddr : block
    signal clk_q : std_logic;
  begin
    oddr : ODDRE1
      generic map (SRVAL => '0')
      port map (C => clk_pix_i, D1 => '1', D2 => '0', SR => pix_rst, Q => clk_q);
    obuf : OBUFDS port map (I => clk_q, O => tx_lvds_p, OB => tx_lvds_n);
  end block;

  -----------------------------------------------------------------------------
  -- status (quasi-static, two stages into clk_100)
  -----------------------------------------------------------------------------
  process (clk_100)
  begin
    if rising_edge(clk_100) then
      st_meta <= fifo_under & fifo_run & (gt_pg(0) and gt_pg(1) and gt_pg(2)) & gt_done_free;
      st_sync <= st_meta;
    end if;
  end process;
  status <= st_sync & ctl_error & ctl_done;
  dbg    <= '0' & ctl_diag & st_sync & ctl_error & ctl_done & ctl_status;

end architecture rtl;
