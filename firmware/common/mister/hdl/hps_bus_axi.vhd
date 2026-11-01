-------------------------------------------------------------------------------
-- Title      : HPS bus of MiSTer over AXI4-Lite (Zynq M_AXI_GP0)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : hps_bus_axi.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Replaces the GPO/GPI registers of the Cyclone V FPGA manager that
--   Main_MiSTer uses to talk to the core, and the logic of sys_top.v behind
--   them (doc/ARCHITECTURE.md §2): 2-FF synchronizer of gp_out, strobe/ack
--   with io_wait/vs_wait, chip select decode, core magic, reset decoder.
--
--   Registers (AXI4-Lite, 32 bit, offset = address bits 3:2):
--     0x0  GPO     RW  gp_out as on the Cyclone V (bit 15:0 data, 17 strobe,
--                      18/19/20 ss0/ss1/ss2, 29 LED, 31:30 reset/magic select)
--     0x4  GPI     RO  gp_out(31) = 0: core magic 0x5CA623 & G_CORE_TYPE,
--                      else {0, btn_user, btn_osd, io_dig, 0000000, hdmi_int,
--                      io_ver = 01, io_ack, io_wide, io_dout}
--     0x8  ID      RO  x"5A4D5354" ("ZMST": this block, no GPO side effect)
--     0xC  STATUS  RO  bit 0 access lost to a timeout (sticky), bit 1 clk_sys
--                      domain behind, bit 2 idle (synchronized), bit 3 quiesce
--          CTRL    WO  bit 0 quiesce: Main_MiSTer sets it before it reconfigures
--                      the PL and waits for idle (the design has closed every
--                      transaction on its HP ports); reset value 0
--     0x10 + 4 i  AUX  RO  word i of aux (G_AUX words, G_ADDR_W > 4): data of the
--                      design that is quasi-static in any clock domain (it
--                      changes so rarely that the reader can check it, e.g. the
--                      snapshot of perf_counters with its sequence word); writes
--                      there have no effect, addresses without a word read 0
--
--   Clock domains: aclk (AXI, free running) and clk_sys (the core clock of
--   hps_io, gated and stalled in stage C).  Rules that make the unhandshaked
--   block transfers of Main_MiSTer safe at any clk_sys rate:
--     - a GPO write is answered (BVALID) only when the clk_sys domain has taken
--       the new value (toggle handshake; the value is held until then);
--     - a GPI read is answered with a snapshot the clk_sys domain takes
--       G_RD_WAIT clk_sys cycles after the request arrived, so io_dout of the
--       last strobe is valid;
--     - one access at a time, a write before a read.
--   If clk_sys does not answer within G_TIMEOUT aclk cycles (clock stopped),
--   the access ends anyway, a GPI read with x"FFFFFFFF" (bit 31 = 1:
--   Main_MiSTer sees "FPGA not ready", as on the Cyclone V); while the clk_sys
--   domain is behind, GPO writes are dropped and GPI reads end at once the same
--   way.  All responses are OKAY: SLVERR would be an external abort on the
--   Cortex-A9 (SIGBUS in Main_MiSTer); STATUS shows what happened.
--   CDC paths gpo_reg -> gp_outr and gpi_snap -> rdata: held stable by the
--   handshake, constrain with set_max_delay -datapath_only (one period).
--
--   The reset decoder (core reset request, gp_out(31:30): 01 sets, 00 then 10
--   clears) runs on aclk, like sys_top.v on its free running 50 MHz clock.
--
--   G_RAW = true: only the register interface.  gp_out_sys is the GPO value in
--   the clk_sys domain (the gp_out of the Cyclone V block, now synchronous to
--   clk_sys), GPI returns gp_in_sys; sys_top_zynq (sys_top.v with its own
--   strobe/ack logic, chip selects and core magic) sits behind it.  sys_top
--   delays gp_out by two clk_sys cycles (gp_outd, gp_outr), so G_RD_WAIT is 2
--   higher than without it (4 for the same margin).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity hps_bus_axi is
  generic (
    G_CORE_TYPE : std_logic_vector(7 downto 0) := x"A4";   -- A4 generic core, A8 dual SDRAM
    G_RD_WAIT   : natural := 2;                            -- clk_sys cycles before the GPI snapshot
    G_TIMEOUT   : positive := 2 ** 20;                     -- aclk cycles (10.5 ms at 100 MHz)
    G_RAW       : boolean := false;                        -- register interface only (sys_top_zynq)
    G_ADDR_W    : natural := 4;                            -- AXI address bits (4: no aux words)
    G_AUX       : natural := 0                             -- aux words from 0x10
  );
  port (
    -- AXI4-Lite slave (aclk)
    aclk          : in  std_logic;
    aresetn       : in  std_logic;
    s_axi_awaddr  : in  std_logic_vector(G_ADDR_W - 1 downto 0);
    s_axi_awprot  : in  std_logic_vector(2 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_araddr  : in  std_logic_vector(G_ADDR_W - 1 downto 0);
    s_axi_arprot  : in  std_logic_vector(2 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;

    -- aclk domain
    reset_in      : in  std_logic := '0';   -- sets the core reset request (sys_top: reset button)
    reset_req     : out std_logic;          -- core reset request
    quiesce       : out std_logic;          -- CTRL bit 0
    idle          : in  std_logic := '0';   -- asynchronous: HP ports quiesced
    led_disk      : out std_logic;          -- gp_out(29)

    -- clk_sys domain: HPS_BUS signals of hps_io
    clk_sys       : in  std_logic;
    io_din        : out std_logic_vector(15 downto 0);
    io_strobe     : out std_logic;
    io_fpga       : out std_logic;          -- fp_enable (file I/O frame)
    io_uio        : out std_logic;          -- io_enable (user_io frame)
    io_osd_hdmi   : out std_logic;
    io_osd_vga    : out std_logic;
    io_dout       : in  std_logic_vector(15 downto 0);  -- hps_io io_dout or'ed with the system answers
    io_wide       : in  std_logic;
    io_wait       : in  std_logic;
    vs_wait       : in  std_logic := '0';
    -- asynchronous status inputs (synchronized here)
    btn_osd       : in  std_logic := '0';
    btn_user      : in  std_logic := '0';
    io_dig        : in  std_logic := '0';
    hdmi_int      : in  std_logic := '0';   -- GPI bit 20 (~HDMI_TX_INT on the DE10-Nano)
    -- G_RAW (clk_sys domain): gp_out/gp_in of sys_top_zynq
    gp_out_sys    : out std_logic_vector(31 downto 0);
    gp_in_sys     : in  std_logic_vector(31 downto 0) := (others => '0');
    -- quasi-static aux words (no synchronizer)
    aux           : in  std_logic_vector(32 * G_AUX - 1 downto 0) := (others => '0')
  );
end entity hps_bus_axi;

architecture rtl of hps_bus_axi is

  constant C_MAGIC : std_logic_vector(23 downto 0) := x"5CA623";
  constant C_ID    : std_logic_vector(31 downto 0) := x"5A4D5354";
  constant C_ERR   : std_logic_vector(31 downto 0) := x"FFFFFFFF";

  ------------------------------------------------------------------------------
  -- aclk domain
  ------------------------------------------------------------------------------
  type state_t is (S_IDLE, S_W_WAIT, S_B, S_R_WAIT, S_R);
  signal state     : state_t;
  signal gpo_reg   : std_logic_vector(31 downto 0);
  signal w_req     : std_logic := '0';                  -- power-up values: both sides agree
  signal r_req     : std_logic := '0';
  signal w_ack_s   : std_logic_vector(1 downto 0) := "00";   -- synchronizer of w_ack
  signal r_ack_s   : std_logic_vector(1 downto 0) := "00";
  signal behind    : std_logic;
  signal timer     : natural range 0 to G_TIMEOUT;
  signal timeout_seen : std_logic;
  signal rdata     : std_logic_vector(31 downto 0);
  signal aw_go     : std_logic;
  signal ar_go     : std_logic;
  signal resetd    : std_logic_vector(1 downto 0);
  signal resetd2   : std_logic_vector(1 downto 0);
  signal reset_r   : std_logic;
  signal quiesce_r : std_logic;
  signal idle_s    : std_logic_vector(1 downto 0) := "00";
  signal aw_low    : std_logic;                         -- address in 0x0..0xC
  signal ar_low    : std_logic;
  signal aw_sel    : std_logic_vector(1 downto 0);      -- register of 0x0..0xC
  signal ar_sel    : std_logic_vector(1 downto 0);

  -- aux word of a read address >= 0x10 (static slices: no word for G_AUX = 0)
  function aux_word(a : std_logic_vector; v : std_logic_vector) return std_logic_vector is
    variable r : std_logic_vector(31 downto 0) := (others => '0');
  begin
    for k in 0 to G_AUX - 1 loop
      if unsigned(a(a'high downto 2)) = k + 4 then
        r := v(32 * k + 31 downto 32 * k);
      end if;
    end loop;
    return r;
  end function;

  ------------------------------------------------------------------------------
  -- clk_sys domain
  ------------------------------------------------------------------------------
  signal w_req_s   : std_logic_vector(1 downto 0) := "00";
  signal r_req_s   : std_logic_vector(1 downto 0) := "00";
  signal w_ack     : std_logic := '0';
  signal r_ack     : std_logic := '0';
  signal rd_cnt    : natural range 0 to G_RD_WAIT := 0;
  signal rd_busy   : std_logic := '0';
  signal gp_outr   : std_logic_vector(31 downto 0) := (others => '0');
  signal gpi_snap  : std_logic_vector(31 downto 0) := (others => '0');
  signal gpi_now   : std_logic_vector(31 downto 0);
  signal rack      : std_logic := '0';
  signal io_ack    : std_logic := '0';
  signal strobe_i  : std_logic;
  signal in_s1     : std_logic_vector(3 downto 0) := (others => '0');
  signal in_s2     : std_logic_vector(3 downto 0) := (others => '0');

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of w_ack_s, r_ack_s, w_req_s, r_req_s, in_s1, in_s2, idle_s : signal is "TRUE";

begin

  ------------------------------------------------------------------------------
  -- AXI4-Lite slave (one access at a time; write before read)
  ------------------------------------------------------------------------------
  aw_go <= '1' when state = S_IDLE and s_axi_awvalid = '1' and s_axi_wvalid = '1' else '0';
  ar_go <= '1' when state = S_IDLE and s_axi_arvalid = '1' and aw_go = '0' and
                    not (s_axi_awvalid = '1' or s_axi_wvalid = '1') else '0';

  aw_low <= '1' when G_ADDR_W <= 4 or unsigned(s_axi_awaddr(G_ADDR_W - 1 downto 4)) = 0 else '0';
  ar_low <= '1' when G_ADDR_W <= 4 or unsigned(s_axi_araddr(G_ADDR_W - 1 downto 4)) = 0 else '0';

  aw_sel <= s_axi_awaddr(3 downto 2);
  ar_sel <= s_axi_araddr(3 downto 2);

  s_axi_awready <= aw_go;
  s_axi_wready  <= aw_go;
  s_axi_arready <= ar_go;
  s_axi_bvalid  <= '1' when state = S_B else '0';
  s_axi_bresp   <= "00";
  s_axi_rvalid  <= '1' when state = S_R else '0';
  s_axi_rdata   <= rdata;
  s_axi_rresp   <= "00";

  -- the clk_sys domain has not answered an earlier request yet
  behind <= '1' when w_ack_s(1) /= w_req or r_ack_s(1) /= r_req else '0';

  process (aclk)
    variable v : std_logic_vector(31 downto 0);
  begin
    if rising_edge(aclk) then
      w_ack_s <= w_ack_s(0) & w_ack;
      r_ack_s <= r_ack_s(0) & r_ack;
      idle_s  <= idle_s(0) & idle;

      case state is
        when S_IDLE =>
          timer <= 0;
          if aw_go = '1' then
            state <= S_B;                              -- ID: no effect
            if aw_low = '0' then
              null;                                    -- aux: read only
            elsif aw_sel = "11" then
              if s_axi_wstrb(0) = '1' then
                quiesce_r <= s_axi_wdata(0);
              end if;
            elsif aw_sel = "00" then
              if behind = '1' then
                timeout_seen <= '1';                   -- dropped, gpo_reg kept for the pending copy
              else
                v := gpo_reg;
                for b in 0 to 3 loop
                  if s_axi_wstrb(b) = '1' then
                    v(8 * b + 7 downto 8 * b) := s_axi_wdata(8 * b + 7 downto 8 * b);
                  end if;
                end loop;
                gpo_reg <= v;
                w_req   <= not w_req;
                state   <= S_W_WAIT;
              end if;
            end if;
          elsif ar_go = '1' then
            state <= S_R;
            if ar_low = '0' then
              rdata <= aux_word(s_axi_araddr, aux);
            else
            case ar_sel is
              when "00" => rdata <= gpo_reg;
              when "01" =>
                if behind = '1' then
                  rdata <= C_ERR;
                else
                  r_req <= not r_req;
                  state <= S_R_WAIT;
                end if;
              when "10" => rdata <= C_ID;
              when others => rdata <= (31 downto 4 => '0') & quiesce_r & idle_s(1) & behind & timeout_seen;
            end case;
            end if;
          end if;

        when S_W_WAIT =>
          timer <= timer + 1;
          if w_ack_s(1) = w_req then
            state <= S_B;
          elsif timer = G_TIMEOUT - 1 then
            timeout_seen <= '1';
            state <= S_B;
          end if;

        when S_B =>
          if s_axi_bready = '1' then
            state <= S_IDLE;
          end if;

        when S_R_WAIT =>
          timer <= timer + 1;
          if r_ack_s(1) = r_req then
            rdata <= gpi_snap;                         -- stable: taken before r_ack toggled
            state <= S_R;
          elsif timer = G_TIMEOUT - 1 then
            rdata <= C_ERR;
            timeout_seen <= '1';
            state <= S_R;
          end if;

        when S_R =>
          if s_axi_rready = '1' then
            state <= S_IDLE;
          end if;
      end case;

      -- core reset request (sys_top.v): 01 sets it, the sequence 00 -> 10 clears it
      if reset_in = '1' or resetd = "01" then
        reset_r <= '1';
      elsif resetd = "10" and resetd2 = "00" then
        reset_r <= '0';
      end if;
      resetd  <= gpo_reg(31 downto 30);
      resetd2 <= resetd;

      if aresetn = '0' then
        state        <= S_IDLE;
        gpo_reg      <= (others => '0');
        w_req        <= w_ack_s(1);                    -- nothing pending after a reset
        r_req        <= r_ack_s(1);
        timer        <= 0;
        timeout_seen <= '0';
        rdata        <= (others => '0');
        resetd       <= "00";
        resetd2      <= "00";
        reset_r      <= '0';
        quiesce_r    <= '0';
      end if;
    end if;
  end process;

  reset_req <= reset_r;
  quiesce   <= quiesce_r;
  led_disk  <= gpo_reg(29);

  ------------------------------------------------------------------------------
  -- clk_sys domain: take GPO, answer GPI, strobe/ack as in sys_top.v
  ------------------------------------------------------------------------------
  strobe_i <= not rack and gp_outr(17);

  gpi_now <= gp_in_sys when G_RAW else
             C_MAGIC & G_CORE_TYPE when gp_outr(31) = '0' else
             '0' & in_s2(1) & in_s2(0) & in_s2(2) & "0000000" & in_s2(3) & "01" & io_ack & io_wide & io_dout;
  gp_out_sys <= gp_outr;

  process (clk_sys)
  begin
    if rising_edge(clk_sys) then
      w_req_s <= w_req_s(0) & w_req;
      r_req_s <= r_req_s(0) & r_req;
      in_s1   <= hdmi_int & io_dig & btn_user & btn_osd;
      in_s2   <= in_s1;

      -- a new GPO value: the AXI side holds gpo_reg until w_ack follows w_req
      if w_req_s(1) /= w_ack then
        gp_outr <= gpo_reg;
        w_ack   <= w_req_s(1);
      end if;

      -- GPI snapshot G_RD_WAIT cycles after the request arrived
      if rd_busy = '0' then
        if r_req_s(1) /= r_ack then
          rd_busy <= '1';
          rd_cnt  <= 0;
        end if;
      elsif rd_cnt = G_RD_WAIT then
        gpi_snap <= gpi_now;
        r_ack    <= r_req_s(1);
        rd_busy  <= '0';
      else
        rd_cnt <= rd_cnt + 1;
      end if;

      if (io_wait = '0' and vs_wait = '0') or strobe_i = '1' then
        rack   <= gp_outr(17);
        io_ack <= rack;
      end if;
    end if;
  end process;

  io_din      <= gp_outr(15 downto 0);
  io_strobe   <= strobe_i;
  io_fpga     <= not gp_outr(19) and gp_outr(18);
  io_uio      <= not gp_outr(19) and gp_outr(20);
  io_osd_hdmi <= gp_outr(19) and not gp_outr(18);
  io_osd_vga  <= gp_outr(19) and not gp_outr(20);

end architecture rtl;
