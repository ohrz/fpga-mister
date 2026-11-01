-------------------------------------------------------------------------------
-- Title      : Stub of sys_top_zynq for mister_zynq_tb
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : sys_top_zynq_stub.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Entity sys_top_zynq with the ports of the generated sys/sys_top_zynq.sv
--   (component in mister_zynq), standing in for sys_top.v and the core.  It
--   checks from the inside what mister_zynq connects (failure on a mismatch):
--     - the clocks by their period (tb constants);
--     - PLL reconfiguration: waitrequest high one cycle after a write;
--     - SDRAM pins: an SDRAM controller on ZYNQ_CLK_CORE (mode register CL 3,
--       BL 1, then full and byte-masked writes and reads in the BRAM region and
--       in the DDR region of the MSX profile); read data sampled in the middle
--       of cycle k + CL (the unisim BUFGCE model delays the gated clock by delta
--       cycles, the middle of the cycle does not depend on them); with
--       free_mode = 1 (G_FREE_CLK) instead: 200 periods of ZYNQ_CLK_CORE, each
--       T_MASTER (no gating), and a read nobody answers (SDRAM_DQ stays Z);
--     - ascal frame buffer: Avalon write burst and read burst on vbuf;
--     - DDRAM_* (sysmem ram1) on the free-running dd_clk_src (T_DDRAM): with
--       dd_mode = 1 a write burst of DD_N beats, a byte-masked single write,
--       then (after the SDRAM and frame buffer sequences) a read burst that
--       must return the merged data, dd_reading from its acceptance (a held
--       bridge accepts no new command) until its last beat; with
--       dd_mode = 0 a read must be accepted and never answered (tie-off);
--     - COREMEM (ZYNQ_coremem_*) on cm_clk_src (T_COREMEM): with cm_mode = 1,
--       after the DDRAM sequence, a write burst of 2 beats at CM_ADDR and its
--       read (cm_reading from acceptance to the last beat, data checked); with
--       cm_mode = 0 the outputs are 0 as sys_top_zynq ties them without
--       MISTER_ZYNQ_COREMEM.
--   and drives patterns for the testbench: HDMI_TX_* on ZYNQ_CLK_HDMI_TX
--   (hdmi_clk_sw output, with vd_mode = 1 vd_clk_src) (counter R, G = R + 1,
--   B = R + 2, DE/HS/VS = R(0)/R(1)/R(2)), I2S (BCLK/LRCLK/DATA = counter bits
--   0/1/2 on the audio clock), GPI = 0 & reset_out & not GPO(29:0) seven
--   clk_sys cycles after GPO (sys_top: 2, plus the 5 cycles of io_dout latency
--   hps_bus_axi tolerates with G_RD_WAIT = 4), reset_core_req = GPO(30),
--   LED = KEY & SW & vbuf done & SDRAM done.  After its sequence the SDRAM
--   controller waits for SW = 0101 and then writes an unsupported mode (full
--   page burst): the emulator's err_mode must reach status_err.
--   VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mister_zynq_tb_pkg.all;

entity sys_top_zynq is
  port (
    ZYNQ_h2f_gp_gp_in                   : out std_logic_vector(31 downto 0);
    ZYNQ_h2f_gp_gp_out                  : in  std_logic_vector(31 downto 0);
    ZYNQ_uart_ri                        : out std_logic;
    ZYNQ_uart_dsr                       : out std_logic;
    ZYNQ_uart_dcd                       : out std_logic;
    ZYNQ_uart_dtr                       : in  std_logic;
    ZYNQ_uart_cts                       : out std_logic;
    ZYNQ_uart_rts                       : in  std_logic;
    ZYNQ_uart_rxd                       : out std_logic;
    ZYNQ_uart_txd                       : in  std_logic;
    ZYNQ_interrupts_irq                 : out std_logic_vector(63 downto 0);
    ZYNQ_sysmem_reset_core_req          : out std_logic;
    ZYNQ_sysmem_reset_out               : in  std_logic;
    ZYNQ_sysmem_clock                   : in  std_logic;
    ZYNQ_sysmem_reset_hps_cold_req      : out std_logic;
    ZYNQ_sysmem_ram1_clk                : out std_logic;
    ZYNQ_sysmem_ram1_address            : out std_logic_vector(28 downto 0);
    ZYNQ_sysmem_ram1_burstcount         : out std_logic_vector(7 downto 0);
    ZYNQ_sysmem_ram1_waitrequest        : in  std_logic;
    ZYNQ_sysmem_ram1_readdata           : in  std_logic_vector(63 downto 0);
    ZYNQ_sysmem_ram1_readdatavalid      : in  std_logic;
    ZYNQ_sysmem_ram1_read               : out std_logic;
    ZYNQ_sysmem_ram1_writedata          : out std_logic_vector(63 downto 0);
    ZYNQ_sysmem_ram1_byteenable         : out std_logic_vector(7 downto 0);
    ZYNQ_sysmem_ram1_write              : out std_logic;
    ZYNQ_sysmem_ram2_clk                : out std_logic;
    ZYNQ_sysmem_ram2_address            : out std_logic_vector(28 downto 0);
    ZYNQ_sysmem_ram2_burstcount         : out std_logic_vector(7 downto 0);
    ZYNQ_sysmem_ram2_waitrequest        : in  std_logic;
    ZYNQ_sysmem_ram2_readdata           : in  std_logic_vector(63 downto 0);
    ZYNQ_sysmem_ram2_readdatavalid      : in  std_logic;
    ZYNQ_sysmem_ram2_read               : out std_logic;
    ZYNQ_sysmem_ram2_writedata          : out std_logic_vector(63 downto 0);
    ZYNQ_sysmem_ram2_byteenable         : out std_logic_vector(7 downto 0);
    ZYNQ_sysmem_ram2_write              : out std_logic;
    ZYNQ_sysmem_vbuf_clk                : out std_logic;
    ZYNQ_sysmem_vbuf_address            : out std_logic_vector(28 downto 0);
    ZYNQ_sysmem_vbuf_burstcount         : out std_logic_vector(7 downto 0);
    ZYNQ_sysmem_vbuf_waitrequest        : in  std_logic;
    ZYNQ_sysmem_vbuf_writedata          : out std_logic_vector(63 downto 0);
    ZYNQ_sysmem_vbuf_byteenable         : out std_logic_vector(7 downto 0);
    ZYNQ_sysmem_vbuf_write              : out std_logic;
    ZYNQ_sysmem_vbuf_readdata           : in  std_logic_vector(63 downto 0);
    ZYNQ_sysmem_vbuf_readdatavalid      : in  std_logic;
    ZYNQ_sysmem_vbuf_read               : out std_logic;
    ZYNQ_pll_hdmi_refclk                : out std_logic;
    ZYNQ_pll_hdmi_rst                   : out std_logic;
    ZYNQ_pll_hdmi_reconfig_to_pll       : out std_logic_vector(63 downto 0);
    ZYNQ_pll_hdmi_reconfig_from_pll     : in  std_logic_vector(63 downto 0);
    ZYNQ_pll_hdmi_outclk_0              : in  std_logic;
    ZYNQ_pll_cfg_hdmi_mgmt_clk          : out std_logic;
    ZYNQ_pll_cfg_hdmi_mgmt_reset        : out std_logic;
    ZYNQ_pll_cfg_hdmi_mgmt_waitrequest  : in  std_logic;
    ZYNQ_pll_cfg_hdmi_mgmt_write        : out std_logic;
    ZYNQ_pll_cfg_hdmi_mgmt_address      : out std_logic_vector(5 downto 0);
    ZYNQ_pll_cfg_hdmi_mgmt_writedata    : out std_logic_vector(31 downto 0);
    ZYNQ_pll_cfg_hdmi_reconfig_to_pll   : in  std_logic_vector(63 downto 0);
    ZYNQ_pll_cfg_hdmi_reconfig_from_pll : out std_logic_vector(63 downto 0);
    ZYNQ_hdmi_i2c_out_clk               : in  std_logic;
    ZYNQ_hdmi_i2c_scl                   : out std_logic;
    ZYNQ_hdmi_i2c_out_data              : in  std_logic;
    ZYNQ_hdmi_i2c_sda                   : out std_logic;
    ZYNQ_hdmi_clk_sw_clkselect          : out std_logic_vector(1 downto 0);
    ZYNQ_hdmi_clk_sw_inclk              : out std_logic_vector(3 downto 0);
    ZYNQ_hdmi_clk_sw_outclk             : in  std_logic;
    ZYNQ_vga_clk_sw_clkselect           : out std_logic_vector(1 downto 0);
    ZYNQ_vga_clk_sw_inclk               : out std_logic_vector(3 downto 0);
    ZYNQ_vga_clk_sw_outclk              : in  std_logic;
    ZYNQ_pll_audio_refclk               : out std_logic;
    ZYNQ_pll_audio_rst                  : out std_logic;
    ZYNQ_pll_audio_outclk_0             : in  std_logic;
    ZYNQ_spi_sclk_out                   : in  std_logic;
    ZYNQ_spi_txd                        : in  std_logic;
    ZYNQ_spi_rxd                        : out std_logic;
    ZYNQ_spi_ss_0_n                     : in  std_logic;
    ZYNQ_spi_ss_in_n                    : out std_logic;
    ZYNQ_CLK_CORE                       : in  std_logic;
    ZYNQ_CLK_SYS                        : out std_logic;
    ZYNQ_CLK_HDMI_TX                    : out std_logic;
    ZYNQ_PACE_ALT                       : out std_logic;
    ZYNQ_coremem_clk                    : out std_logic;
    ZYNQ_coremem_address                : out std_logic_vector(28 downto 0);
    ZYNQ_coremem_burstcount             : out std_logic_vector(7 downto 0);
    ZYNQ_coremem_waitrequest            : in  std_logic;
    ZYNQ_coremem_readdata               : in  std_logic_vector(63 downto 0);
    ZYNQ_coremem_readdatavalid          : in  std_logic;
    ZYNQ_coremem_read                   : out std_logic;
    ZYNQ_coremem_writedata              : out std_logic_vector(63 downto 0);
    ZYNQ_coremem_byteenable             : out std_logic_vector(7 downto 0);
    ZYNQ_coremem_write                  : out std_logic;
    FPGA_CLK1_50                        : in  std_logic;
    FPGA_CLK2_50                        : in  std_logic;
    FPGA_CLK3_50                        : in  std_logic;
    HDMI_I2C_SCL                        : out std_logic;
    HDMI_I2C_SDA                        : inout std_logic;
    HDMI_MCLK                           : out std_logic;
    HDMI_SCLK                           : out std_logic;
    HDMI_LRCLK                          : out std_logic;
    HDMI_I2S                            : out std_logic;
    HDMI_TX_CLK                         : out std_logic;
    HDMI_TX_DE                          : out std_logic;
    HDMI_TX_D                           : out std_logic_vector(23 downto 0);
    HDMI_TX_HS                          : out std_logic;
    HDMI_TX_VS                          : out std_logic;
    HDMI_TX_INT                         : in  std_logic;
    SDRAM_A                             : out std_logic_vector(12 downto 0);
    SDRAM_DQ                            : inout std_logic_vector(15 downto 0);
    SDRAM_DQML                          : out std_logic;
    SDRAM_DQMH                          : out std_logic;
    SDRAM_nWE                           : out std_logic;
    SDRAM_nCAS                          : out std_logic;
    SDRAM_nRAS                          : out std_logic;
    SDRAM_nCS                           : out std_logic;
    SDRAM_BA                            : out std_logic_vector(1 downto 0);
    SDRAM_CLK                           : out std_logic;
    SDRAM_CKE                           : out std_logic;
    VGA_R                               : out std_logic_vector(5 downto 0);
    VGA_G                               : out std_logic_vector(5 downto 0);
    VGA_B                               : out std_logic_vector(5 downto 0);
    VGA_HS                              : inout std_logic;
    VGA_VS                              : out std_logic;
    VGA_EN                              : in  std_logic;
    AUDIO_L                             : out std_logic;
    AUDIO_R                             : out std_logic;
    AUDIO_SPDIF                         : out std_logic;
    SDIO_DAT                            : inout std_logic_vector(3 downto 0);
    SDIO_CMD                            : inout std_logic;
    SDIO_CLK                            : out std_logic;
    LED_USER                            : out std_logic;
    LED_HDD                             : out std_logic;
    LED_POWER                           : out std_logic;
    BTN_USER                            : in  std_logic;
    BTN_OSD                             : in  std_logic;
    BTN_RESET                           : in  std_logic;
    SD_SPI_CS                           : out std_logic;
    SD_SPI_MISO                         : in  std_logic;
    SD_SPI_CLK                          : out std_logic;
    SD_SPI_MOSI                         : out std_logic;
    SDCD_SPDIF                          : inout std_logic;
    IO_SCL                              : out std_logic;
    IO_SDA                              : inout std_logic;
    ADC_SCK                             : out std_logic;
    ADC_SDO                             : in  std_logic;
    ADC_SDI                             : out std_logic;
    ADC_CONVST                          : out std_logic;
    KEY                                 : in  std_logic_vector(1 downto 0);
    SW                                  : in  std_logic_vector(3 downto 0);
    LED                                 : out std_logic_vector(7 downto 0);
    USER_IO                             : inout std_logic_vector(6 downto 0)
  );
end entity sys_top_zynq;

architecture stub of sys_top_zynq is

  constant NOP   : std_logic_vector(3 downto 0) := "0111";   -- cs_n ras_n cas_n we_n
  constant ACT   : std_logic_vector(3 downto 0) := "0011";
  constant READ  : std_logic_vector(3 downto 0) := "0101";
  constant WRITE : std_logic_vector(3 downto 0) := "0100";
  constant MRS   : std_logic_vector(3 downto 0) := "0000";

  signal sd_done, vb_done : std_logic := '0';
  signal dd_clk           : std_logic := '0';
  type gp_pipe_t is array (0 to 5) of std_logic_vector(31 downto 0);
  signal gp_r1            : std_logic_vector(31 downto 0) := (others => '0');
  signal gp_pipe          : gp_pipe_t := (others => (others => '0'));
  signal hc               : unsigned(7 downto 0) := (others => '0');
  signal tx_clk : std_logic;
  signal ac               : unsigned(2 downto 0) := (others => '0');

  procedure check_period(signal c : std_logic; p : time; name : string) is
    variable t0 : time;
  begin
    wait for 1 us;
    wait until rising_edge(c);
    t0 := now;
    wait until rising_edge(c);
    assert now - t0 = p report name & ": period " & time'image(now - t0) & ", expected " & time'image(p)
      severity failure;
  end procedure;

begin

  ZYNQ_CLK_SYS <= ZYNQ_CLK_CORE;
  ZYNQ_PACE_ALT <= '0';

  ------------------------------------------------------------------------------
  -- clocks
  ------------------------------------------------------------------------------
  per_50a : process begin check_period(FPGA_CLK1_50, T_50, "FPGA_CLK1_50"); wait; end process;
  per_50b : process begin check_period(FPGA_CLK2_50, T_50, "FPGA_CLK2_50"); wait; end process;
  per_50c : process begin check_period(FPGA_CLK3_50, T_50, "FPGA_CLK3_50"); wait; end process;
  per_mem : process begin check_period(ZYNQ_sysmem_clock, T_100, "sysmem clock"); wait; end process;
  per_hd0 : process begin check_period(ZYNQ_pll_hdmi_outclk_0, T_HDMI, "pll_hdmi outclk_0"); wait; end process;
  per_hd1 : process begin check_period(ZYNQ_hdmi_clk_sw_outclk, T_HDMI, "hdmi_clk_sw outclk"); wait; end process;
  per_hd2 : process begin check_period(ZYNQ_vga_clk_sw_outclk, T_HDMI, "vga_clk_sw outclk"); wait; end process;
  per_aud : process begin check_period(ZYNQ_pll_audio_outclk_0, T_AUDIO, "pll_audio outclk_0"); wait; end process;

  ------------------------------------------------------------------------------
  -- PLL reconfiguration (pll_cfg_hdmi on FPGA_CLK1_50)
  ------------------------------------------------------------------------------
  cfg : process
  begin
    ZYNQ_pll_cfg_hdmi_mgmt_write <= '0';
    wait for 2 us;
    wait until rising_edge(FPGA_CLK1_50);
    assert ZYNQ_pll_cfg_hdmi_mgmt_waitrequest = '0' report "pll_cfg waitrequest before a write" severity failure;
    ZYNQ_pll_cfg_hdmi_mgmt_write <= '1';
    wait until rising_edge(FPGA_CLK1_50);
    ZYNQ_pll_cfg_hdmi_mgmt_write <= '0';
    wait until falling_edge(FPGA_CLK1_50);
    assert ZYNQ_pll_cfg_hdmi_mgmt_waitrequest = '1' report "pll_cfg waitrequest after a write" severity failure;
    wait until falling_edge(FPGA_CLK1_50);
    assert ZYNQ_pll_cfg_hdmi_mgmt_waitrequest = '0' report "pll_cfg waitrequest stays" severity failure;
    wait;
  end process;

  ------------------------------------------------------------------------------
  -- HPS bus: GPO register (sys_top), GPI 6 cycles later (sys_top register, io_dout latency)
  ------------------------------------------------------------------------------
  process (ZYNQ_CLK_SYS)
  begin
    if rising_edge(ZYNQ_CLK_SYS) then
      gp_r1 <= ZYNQ_h2f_gp_gp_out;
      gp_pipe(0)      <= '0' & ZYNQ_sysmem_reset_out & not gp_r1(29 downto 0);
      gp_pipe(1 to 5) <= gp_pipe(0 to 4);
    end if;
  end process;
  ZYNQ_h2f_gp_gp_in          <= gp_pipe(5);
  ZYNQ_sysmem_reset_core_req <= gp_r1(30);

  ------------------------------------------------------------------------------
  -- video and audio patterns, board
  ------------------------------------------------------------------------------
  -- HDMI_TX_* on tx_clk as in sys_top: the clock select (clk_hdmi), with
  -- MISTER_DEBUG_NOHDMI (vd_mode) the core's CLK_VIDEO
  tx_clk      <= vd_clk_src when vd_mode = '1' else ZYNQ_hdmi_clk_sw_outclk;
  ZYNQ_CLK_HDMI_TX <= tx_clk;
  process (tx_clk)
  begin
    if rising_edge(tx_clk) then
      hc <= hc + 1;
    end if;
  end process;
  HDMI_TX_D  <= std_logic_vector(hc) & std_logic_vector(hc + 1) & std_logic_vector(hc + 2);
  HDMI_TX_DE <= hc(0);
  HDMI_TX_HS <= hc(1);
  HDMI_TX_VS <= hc(2);

  process (ZYNQ_pll_audio_outclk_0)
  begin
    if rising_edge(ZYNQ_pll_audio_outclk_0) then
      ac <= ac + 1;
    end if;
  end process;
  HDMI_MCLK  <= ZYNQ_pll_audio_outclk_0;
  HDMI_SCLK  <= ac(0);
  HDMI_LRCLK <= ac(1);
  HDMI_I2S   <= ac(2);

  LED <= KEY & SW & vb_done & sd_done;

  ------------------------------------------------------------------------------
  -- SDRAM controller on the gated core clock
  ------------------------------------------------------------------------------
  SDRAM_CLK <= ZYNQ_CLK_CORE;
  SDRAM_CKE <= '1';

  sdram : process
    variable rd : std_logic_vector(15 downto 0);
    variable t0 : time;

    procedure cyc(c : std_logic_vector(3 downto 0); a : natural := 0;
                  dq : std_logic_vector(15 downto 0) := (others => 'Z'); dqm : std_logic_vector(1 downto 0) := "00") is
    begin
      wait until rising_edge(ZYNQ_CLK_CORE);
      SDRAM_nCS <= c(3); SDRAM_nRAS <= c(2); SDRAM_nCAS <= c(1); SDRAM_nWE <= c(0);
      SDRAM_BA  <= "00";
      SDRAM_A   <= std_logic_vector(to_unsigned(a, 13));
      SDRAM_DQ  <= dq;
      SDRAM_DQMH <= dqm(1); SDRAM_DQML <= dqm(0);
    end procedure;

    procedure rd_check(col : natural; exp : std_logic_vector(15 downto 0)) is
    begin
      cyc(READ, col);
      for i in 1 to SD_CL loop cyc(NOP); end loop;        -- edges starting cycles k + 1 .. k + CL
      wait until falling_edge(ZYNQ_CLK_CORE);               -- middle of cycle k + CL
      assert SDRAM_DQ = exp report "SDRAM column " & integer'image(col) & ": read " & to_hstring(SDRAM_DQ) &
        ", expected " & to_hstring(exp) severity failure;
    end procedure;

  begin
    SDRAM_nCS <= '1'; SDRAM_nRAS <= '1'; SDRAM_nCAS <= '1'; SDRAM_nWE <= '1';
    SDRAM_BA <= "00"; SDRAM_A <= (others => '0'); SDRAM_DQ <= (others => 'Z');
    SDRAM_DQMH <= '0'; SDRAM_DQML <= '0';
    wait until ZYNQ_sysmem_reset_out = '0';
    if free_mode = '1' then
      -- free-running core clock: every period T_MASTER, no emulator behind the pins
      wait until rising_edge(ZYNQ_CLK_CORE);
      for i in 1 to 200 loop
        t0 := now;
        wait until rising_edge(ZYNQ_CLK_CORE);
        assert now - t0 = T_MASTER report "free core clock: period " & time'image(now - t0) & ", expected " &
          time'image(T_MASTER) severity failure;
      end loop;
      cyc(MRS, SD_CL * 16);
      cyc(ACT, SD_ROW);
      cyc(READ, SD_COLS(0));
      for i in 1 to SD_CL + 2 loop
        cyc(NOP);
        wait until falling_edge(ZYNQ_CLK_CORE);
        assert SDRAM_DQ = x"ZZZZ" report "free core clock: SDRAM_DQ driven " & to_hstring(SDRAM_DQ)
          severity failure;
      end loop;
      sd_done <= '1';
      wait until SW = "0101";
      cyc(MRS, SD_CL * 16 + 7);                             -- no emulator: no error either
      cyc(NOP);
      wait;
    end if;
    for i in 1 to 20 loop cyc(NOP); end loop;
    cyc(MRS, SD_CL * 16);                                   -- CL in A6:4, BL 1, sequential, burst write
    cyc(NOP); cyc(NOP);
    cyc(ACT, SD_ROW);
    cyc(NOP); cyc(NOP);
    for r in SD_COLS'range loop
      cyc(WRITE, SD_COLS(r), SD_W1); cyc(NOP);
      cyc(WRITE, SD_COLS(r), SD_W2, "10"); cyc(NOP);       -- DQMH: lower byte only
      cyc(WRITE, SD_COLS(r) + 1, SD_W3); cyc(NOP);
    end loop;
    for r in SD_COLS'range loop
      rd_check(SD_COLS(r), SD_W1(15 downto 8) & SD_W2(7 downto 0));
      rd_check(SD_COLS(r) + 1, SD_W3);
    end loop;
    cyc(NOP);
    sd_done <= '1';
    wait until SW = "0101";
    cyc(MRS, SD_CL * 16 + 7);                               -- full page burst: unsupported
    cyc(NOP);
    wait;
  end process;

  ------------------------------------------------------------------------------
  -- ascal frame buffer: write burst, read burst (Avalon on the sysmem clock)
  ------------------------------------------------------------------------------
  vbuf : process
    alias clk is ZYNQ_sysmem_clock;
    variable n : natural;
  begin
    ZYNQ_sysmem_vbuf_write <= '0'; ZYNQ_sysmem_vbuf_read <= '0';
    ZYNQ_sysmem_vbuf_address <= (others => '0'); ZYNQ_sysmem_vbuf_burstcount <= (others => '0');
    ZYNQ_sysmem_vbuf_writedata <= (others => '0'); ZYNQ_sysmem_vbuf_byteenable <= (others => '1');
    wait until ZYNQ_sysmem_reset_out = '0';
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    -- write burst
    ZYNQ_sysmem_vbuf_address    <= VB_ADDR;
    ZYNQ_sysmem_vbuf_burstcount <= std_logic_vector(to_unsigned(VB_DATA'length, 8));
    for i in VB_DATA'range loop
      ZYNQ_sysmem_vbuf_write     <= '1';
      ZYNQ_sysmem_vbuf_writedata <= VB_DATA(i);
      loop
        wait until rising_edge(clk);
        exit when ZYNQ_sysmem_vbuf_waitrequest = '0';
      end loop;
    end loop;
    ZYNQ_sysmem_vbuf_write <= '0';
    for i in 1 to 50 loop wait until rising_edge(clk); end loop;
    -- read burst
    ZYNQ_sysmem_vbuf_read <= '1';
    loop
      wait until rising_edge(clk);
      exit when ZYNQ_sysmem_vbuf_waitrequest = '0';
    end loop;
    ZYNQ_sysmem_vbuf_read <= '0';
    n := 0;
    while n < VB_DATA'length loop
      if ZYNQ_sysmem_vbuf_readdatavalid = '1' then
        assert ZYNQ_sysmem_vbuf_readdata = VB_DATA(n) report "vbuf beat " & integer'image(n) & ": read " &
          to_hstring(ZYNQ_sysmem_vbuf_readdata) severity failure;
        n := n + 1;
      end if;
      if n < VB_DATA'length then wait until rising_edge(clk); end if;
    end loop;
    vb_done <= '1';
    wait;
  end process;

  ------------------------------------------------------------------------------
  -- DDRAM_* of the core (sysmem ram1) on its own clock
  ------------------------------------------------------------------------------
  dd_clk <= dd_clk_src;
  ZYNQ_sysmem_ram1_clk <= dd_clk_src;

  ddram : process
    alias clk is dd_clk;
    variable n : natural;
    variable e : std_logic_vector(63 downto 0);
  begin
    ZYNQ_sysmem_ram1_write <= '0'; ZYNQ_sysmem_ram1_read <= '0';
    ZYNQ_sysmem_ram1_address <= (others => '0'); ZYNQ_sysmem_ram1_burstcount <= (others => '0');
    ZYNQ_sysmem_ram1_writedata <= (others => '0'); ZYNQ_sysmem_ram1_byteenable <= (others => '1');
    wait until ZYNQ_sysmem_reset_out = '0';
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    if dd_mode = '1' then
      -- write burst
      ZYNQ_sysmem_ram1_address    <= DD_ADDR;
      ZYNQ_sysmem_ram1_burstcount <= std_logic_vector(to_unsigned(DD_N, 8));
      for i in 0 to DD_N - 1 loop
        ZYNQ_sysmem_ram1_write     <= '1';
        ZYNQ_sysmem_ram1_writedata <= dd_data(i);
        loop
          wait until rising_edge(clk);
          exit when ZYNQ_sysmem_ram1_waitrequest = '0';
        end loop;
      end loop;
      -- beat 3 once more, only its lower four bytes
      ZYNQ_sysmem_ram1_address    <= std_logic_vector(unsigned(DD_ADDR) + 3);
      ZYNQ_sysmem_ram1_burstcount <= x"01";
      ZYNQ_sysmem_ram1_writedata  <= x"FFFFFFFF11112222";
      ZYNQ_sysmem_ram1_byteenable <= x"0F";
      loop
        wait until rising_edge(clk);
        exit when ZYNQ_sysmem_ram1_waitrequest = '0';
      end loop;
      ZYNQ_sysmem_ram1_write <= '0';
      ZYNQ_sysmem_ram1_byteenable <= (others => '1');
      -- read burst when the other ports are done (the testbench quiesces while it is open)
      if sd_done /= '1' or vb_done /= '1' then
        wait until sd_done = '1' and vb_done = '1';
      end if;
      wait until rising_edge(clk);
      ZYNQ_sysmem_ram1_address    <= DD_ADDR;
      ZYNQ_sysmem_ram1_burstcount <= std_logic_vector(to_unsigned(DD_N, 8));
      ZYNQ_sysmem_ram1_read <= '1';
      loop
        wait until rising_edge(clk);
        exit when ZYNQ_sysmem_ram1_waitrequest = '0';
      end loop;
      ZYNQ_sysmem_ram1_read <= '0';
      -- accepted: every AR of the burst is out, the data follow after the memory latency
      dd_reading <= '1';
      n := 0;
      while n < DD_N loop
        wait until rising_edge(clk);
        if ZYNQ_sysmem_ram1_readdatavalid = '1' then
          e := dd_data(n);
          if n = 3 then
            e(31 downto 0) := x"11112222";
          end if;
          assert ZYNQ_sysmem_ram1_readdata = e report "DDRAM beat " & integer'image(n) & ": read " &
            to_hstring(ZYNQ_sysmem_ram1_readdata) & ", expected " & to_hstring(e) severity failure;
          n := n + 1;
        end if;
      end loop;
      dd_reading <= '0';
    else
      -- tie-off: the read is accepted at once and never answered
      ZYNQ_sysmem_ram1_address <= DD_ADDR;
      ZYNQ_sysmem_ram1_burstcount <= x"01";
      ZYNQ_sysmem_ram1_read <= '1';
      wait until rising_edge(clk);
      assert ZYNQ_sysmem_ram1_waitrequest = '0' report "DDRAM tie-off: waitrequest" severity failure;
      ZYNQ_sysmem_ram1_read <= '0';
      for i in 1 to 50 loop
        wait until rising_edge(clk);
        assert ZYNQ_sysmem_ram1_readdatavalid = '0' report "DDRAM tie-off: read data" severity failure;
      end loop;
    end if;
    dd_done <= '1';
    wait;
  end process;

  ------------------------------------------------------------------------------
  -- COREMEM: memory port of a core with a replaced SDRAM controller (stage D)
  ------------------------------------------------------------------------------
  ZYNQ_coremem_clk <= cm_clk_src when cm_mode = '1' else '0';

  -- clocked by ZYNQ_coremem_clk itself (VHDL-2008 reads the out port), the clock the bridge in mister_zynq
  -- samples on: cm_clk_src is one delta earlier, a stimulus driven on it would be sampled at the same edge
  coremem : process
    variable n : natural;
  begin
    ZYNQ_coremem_write <= '0'; ZYNQ_coremem_read <= '0';
    ZYNQ_coremem_address <= (others => '0'); ZYNQ_coremem_burstcount <= (others => '0');
    ZYNQ_coremem_writedata <= (others => '0'); ZYNQ_coremem_byteenable <= (others => '0');
    if cm_mode /= '1' then
      wait until cm_mode = '1';
    end if;
    if dd_done /= '1' then
      wait until dd_done = '1';
    end if;
    wait until rising_edge(ZYNQ_coremem_clk);
    ZYNQ_coremem_address    <= CM_ADDR;
    ZYNQ_coremem_burstcount <= x"02";
    ZYNQ_coremem_byteenable <= (others => '1');
    for i in CM_DATA'range loop
      ZYNQ_coremem_write     <= '1';
      ZYNQ_coremem_writedata <= CM_DATA(i);
      loop
        wait until rising_edge(ZYNQ_coremem_clk);
        exit when ZYNQ_coremem_waitrequest = '0';
      end loop;
    end loop;
    ZYNQ_coremem_write <= '0';
    ZYNQ_coremem_read  <= '1';
    loop
      wait until rising_edge(ZYNQ_coremem_clk);
      exit when ZYNQ_coremem_waitrequest = '0';
    end loop;
    ZYNQ_coremem_read <= '0';
    cm_reading <= '1';
    n := 0;
    while n < CM_DATA'length loop
      wait until rising_edge(ZYNQ_coremem_clk);
      if ZYNQ_coremem_readdatavalid = '1' then
        assert ZYNQ_coremem_readdata = CM_DATA(n) report "COREMEM beat " & integer'image(n) & ": read " &
          to_hstring(ZYNQ_coremem_readdata) severity failure;
        n := n + 1;
      end if;
    end loop;
    cm_reading <= '0';
    cm_done <= '1';
    wait;
  end process;

end architecture stub;
