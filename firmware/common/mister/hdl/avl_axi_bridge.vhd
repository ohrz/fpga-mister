-------------------------------------------------------------------------------
-- Title      : Avalon-MM slave to AXI3 master bridge (MiSTer DDRAM port -> Zynq HP)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : avl_axi_bridge.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Connects a MiSTer Avalon-MM memory master (the DDRAM_* port of a core, the
--   ascal scaler, the SDRAM replacement) to a 64-bit AXI3 slave port of the
--   Zynq PS (S_AXI_HPx), one clock for both sides.
--
--   Avalon side (as on the Cyclone V f2sdram port of the DE10-Nano):
--     avl_address is a 64-bit word address; byte address = avl_address * 8 +
--     G_BYTE_OFFSET.  Bursts of 1..255 beats (avl_burstcount), pipelined reads,
--     avl_waitrequest backpressure, read data in order with avl_readdatavalid.
--   AXI side: INCR bursts of at most 16 beats (AXI3), never across a 4 KB
--   boundary, ID 0 on every channel, so the responses come back in order.
--
--   One Avalon command at a time is turned into AXI bursts; a read is accepted
--   (avl_waitrequest low) in the cycle after it was latched, before its first
--   AR, so no read beat comes before the acceptance (Avalon; PSX memcard.vhd
--   counts its 128 beats from the acceptance on); the next command waits until
--   the last AR of the read was accepted.  A write is accepted per beat when
--   the beat enters a 4-entry write buffer after the AW of its burst was
--   accepted; the W channel is fed from that buffer.
--   avl_waitrequest is a flip-flop output (computed from the next state and
--   buffer level), never combinational from an AXI ready or a state decoder: a core that evaluates DDRAM_BUSY deep in
--   its logic does not get the PS7 WREADY path (PSX GPU).  Read
--   data streams back while the next command is already being issued.
--   A write command whose first beat is withdrawn before it was accepted
--   (avl_write falls while avl_waitrequest was high or before the first beat
--   was taken) is dropped: no AW yet -> back to idle; AW already presented or
--   accepted -> the burst is completed with beats of WSTRB = 0, which change
--   nothing, and the rest of the command is discarded.  A master must hold a
--   command until it is accepted, but a core that resets or switches its
--   DDRAM multiplexer mid-request withdraws it (PSX: savestates.vhd drops
--   ddr3_savestate on reset, the arbiter is preempted by it); on the Cyclone V
--   the command was then simply never taken, here the AXI burst would wait
--   for its W beats forever and block every later command (PSX start
--   hang).  A gap after the first accepted beat is a normal Avalon pause.
--   Ordering: a write waits until every outstanding read beat has returned,
--   a read waits until every outstanding write response has returned, so a
--   read after a write to the same address sees the new data and vice versa.
--
--   Quiescing (before the PL is reconfigured): with hold = 1 no new Avalon
--   command is started; a command in progress is finished.  idle = 1 while
--   hold is set and, since the cycle before, no command is in progress and
--   every AXI transaction has completed (all read beats and write responses
--   back); it stays set until hold drops.  A
--   reconfiguration while a transaction is open leaves it in the AFI of the
--   HP port, and the next design gets its responses (or its write data goes
--   to the old address).
--
--   Physical addresses: the DE10-Nano reserves 0x2000_0000-0x3FFF_FFFF of its
--   1 GB DDR for the FPGA and the cores address it from physical 0; the Zybo
--   Z7-20 reserves the same range in its device tree, G_BYTE_OFFSET = 0.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity avl_axi_bridge is
  generic (
    G_AVL_ADDR_W  : natural := 29;                 -- 64-bit word address bits
    G_BYTE_OFFSET : std_logic_vector(31 downto 0) := x"00000000";
    G_AXI_CACHE   : std_logic_vector(3 downto 0)  := "0011"  -- bufferable, modifiable
  );
  port (
    clk               : in  std_logic;
    rst               : in  std_logic;             -- synchronous, active high
    hold              : in  std_logic := '0';      -- start no new command
    idle              : out std_logic;             -- hold and nothing open on AXI

    -- Avalon-MM slave (64 bit)
    avl_waitrequest   : out std_logic;
    avl_burstcount    : in  std_logic_vector(7 downto 0);
    avl_address       : in  std_logic_vector(G_AVL_ADDR_W - 1 downto 0);
    avl_read          : in  std_logic;
    avl_readdata      : out std_logic_vector(63 downto 0);
    avl_readdatavalid : out std_logic;
    avl_write         : in  std_logic;
    avl_writedata     : in  std_logic_vector(63 downto 0);
    avl_byteenable    : in  std_logic_vector(7 downto 0);

    -- AXI3 master (64 bit)
    m_axi_awid        : out std_logic_vector(5 downto 0);
    m_axi_awaddr      : out std_logic_vector(31 downto 0);
    m_axi_awlen       : out std_logic_vector(3 downto 0);
    m_axi_awsize      : out std_logic_vector(2 downto 0);
    m_axi_awburst     : out std_logic_vector(1 downto 0);
    m_axi_awlock      : out std_logic_vector(1 downto 0);
    m_axi_awcache     : out std_logic_vector(3 downto 0);
    m_axi_awprot      : out std_logic_vector(2 downto 0);
    m_axi_awqos       : out std_logic_vector(3 downto 0);
    m_axi_awvalid     : out std_logic;
    m_axi_awready     : in  std_logic;
    m_axi_wid         : out std_logic_vector(5 downto 0);
    m_axi_wdata       : out std_logic_vector(63 downto 0);
    m_axi_wstrb       : out std_logic_vector(7 downto 0);
    m_axi_wlast       : out std_logic;
    m_axi_wvalid      : out std_logic;
    m_axi_wready      : in  std_logic;
    m_axi_bid         : in  std_logic_vector(5 downto 0);
    m_axi_bresp       : in  std_logic_vector(1 downto 0);
    m_axi_bvalid      : in  std_logic;
    m_axi_bready      : out std_logic;
    m_axi_arid        : out std_logic_vector(5 downto 0);
    m_axi_araddr      : out std_logic_vector(31 downto 0);
    m_axi_arlen       : out std_logic_vector(3 downto 0);
    m_axi_arsize      : out std_logic_vector(2 downto 0);
    m_axi_arburst     : out std_logic_vector(1 downto 0);
    m_axi_arlock      : out std_logic_vector(1 downto 0);
    m_axi_arcache     : out std_logic_vector(3 downto 0);
    m_axi_arprot      : out std_logic_vector(2 downto 0);
    m_axi_arqos       : out std_logic_vector(3 downto 0);
    m_axi_arvalid     : out std_logic;
    m_axi_arready     : in  std_logic;
    m_axi_rid         : in  std_logic_vector(5 downto 0);
    m_axi_rdata       : in  std_logic_vector(63 downto 0);
    m_axi_rresp       : in  std_logic_vector(1 downto 0);
    m_axi_rlast       : in  std_logic;
    m_axi_rvalid      : in  std_logic;
    m_axi_rready      : out std_logic;

    -- sticky error flag: an AXI response other than OKAY (cleared by rst)
    axi_error         : out std_logic
  );
end entity avl_axi_bridge;

architecture rtl of avl_axi_bridge is

  type state_t is (S_IDLE, S_RD_AR, S_WR_AW, S_WR_DATA, S_WR_FLUSH);
  signal state       : state_t;

  signal word_addr   : unsigned(28 downto 0);       -- 64-bit word address of the next burst
  signal remaining   : unsigned(8 downto 0);        -- beats of the command not yet in a burst
  signal chunk       : unsigned(4 downto 0);        -- beats of the current burst (1..16)
  signal wbeats      : unsigned(4 downto 0);        -- write beats of the current burst left
  signal wtaken      : std_logic;                   -- a beat of the current write command was accepted
  signal wabort      : std_logic;                   -- the write command was withdrawn before its first beat

  signal awvalid     : std_logic;
  signal arvalid     : std_logic;
  signal ax_addr     : std_logic_vector(31 downto 0);
  signal ax_len      : std_logic_vector(3 downto 0);

  signal rd_pending  : unsigned(9 downto 0);        -- read beats requested, not yet returned
  signal wr_pending  : unsigned(5 downto 0);        -- write bursts without a response
  signal error_flag  : std_logic;
  signal idle_i      : std_logic;

  -- write buffer: Avalon write beats -> W channel
  type wbuf_data_t is array (0 to 3) of std_logic_vector(64 + 8 downto 0);   -- last & strb & data
  signal wbuf        : wbuf_data_t;
  signal wbuf_wr     : unsigned(1 downto 0);
  signal wbuf_rd     : unsigned(1 downto 0);
  signal wbuf_level  : unsigned(2 downto 0);        -- 0..4
  signal wbuf_space  : std_logic;
  signal w_in        : std_logic;                   -- an Avalon write beat is taken this cycle
  signal w_fill      : std_logic;                   -- a WSTRB = 0 beat completes a withdrawn burst
  signal w_push      : std_logic;                   -- a beat enters the write buffer
  signal w_gone      : std_logic;                   -- the write command is withdrawn now
  signal w_out       : std_logic;                   -- a W beat moves this cycle
  signal w_head      : std_logic_vector(64 + 8 downto 0);
  signal wait_r      : std_logic;                   -- avl_waitrequest, registered

  -- beats of the next burst: at most 16, at most the rest of the command, never across 4 KB
  function burst_beats(addr : unsigned(28 downto 0); rest : unsigned(8 downto 0)) return unsigned is
    variable to_4k : unsigned(9 downto 0);
    variable n     : unsigned(9 downto 0);
  begin
    to_4k := to_unsigned(512, 10) - resize(addr(8 downto 0), 10);   -- 512 words per 4 KB
    n := resize(rest, 10);
    if to_4k < n then n := to_4k; end if;
    if n > 16 then n := to_unsigned(16, 10); end if;
    return n(4 downto 0);
  end function;

begin

  -- constant AXI attributes
  m_axi_awid    <= (others => '0');
  m_axi_wid     <= (others => '0');
  m_axi_arid    <= (others => '0');
  m_axi_awsize  <= "011";                           -- 8 bytes per beat
  m_axi_arsize  <= "011";
  m_axi_awburst <= "01";                            -- INCR
  m_axi_arburst <= "01";
  m_axi_awlock  <= "00";
  m_axi_arlock  <= "00";
  m_axi_awcache <= G_AXI_CACHE;
  m_axi_arcache <= G_AXI_CACHE;
  m_axi_awprot  <= "000";
  m_axi_arprot  <= "000";
  m_axi_awqos   <= "0000";
  m_axi_arqos   <= "0000";

  m_axi_awaddr  <= ax_addr;
  m_axi_araddr  <= ax_addr;
  m_axi_awlen   <= ax_len;
  m_axi_arlen   <= ax_len;
  m_axi_awvalid <= awvalid;
  m_axi_arvalid <= arvalid;

  -- write beats of the current burst go into the buffer while it has room (registered level)
  wbuf_space    <= '0' when wbuf_level = 4 else '1';
  w_in          <= '1' when state = S_WR_DATA and avl_write = '1' and wbuf_space = '1' else '0';
  w_fill        <= '1' when state = S_WR_FLUSH and wbuf_space = '1' else '0';
  w_push        <= w_in or w_fill;
  w_gone        <= '1' when wtaken = '0' and avl_write = '0' else '0';
  w_head        <= wbuf(to_integer(wbuf_rd));
  w_out         <= '1' when wbuf_level /= 0 and m_axi_wready = '1' else '0';
  m_axi_wvalid  <= '1' when wbuf_level /= 0 else '0';
  m_axi_wlast   <= w_head(72);
  m_axi_wstrb   <= w_head(71 downto 64);
  m_axi_wdata   <= w_head(63 downto 0);

  avl_waitrequest <= wait_r;

  m_axi_bready  <= '1';
  m_axi_rready  <= '1';

  avl_readdata      <= m_axi_rdata;
  avl_readdatavalid <= m_axi_rvalid;

  axi_error <= error_flag;
  idle      <= idle_i and hold;                 -- drops with hold (idle_i is one cycle late)

  process (clk)
    variable n       : unsigned(4 downto 0);
    variable rd_add  : unsigned(9 downto 0);
    variable wr_add  : std_logic;
    variable rd_sub  : std_logic;
    variable wr_sub  : std_logic;
    variable byte_a  : unsigned(31 downto 0);
    variable ns      : state_t;                     -- next state
    variable nlevel  : unsigned(2 downto 0);        -- next write buffer level
  begin
    if rising_edge(clk) then
      ns     := state;
      nlevel := wbuf_level;
      rd_add := (others => '0');
      wr_add := '0';
      rd_sub := m_axi_rvalid;
      wr_sub := m_axi_bvalid;

      case state is
        when S_IDLE =>
          -- a new command; the master holds address and burst count until it is accepted
          if hold = '1' then
            null;
          elsif avl_read = '1' and wr_pending = 0 then
            word_addr <= resize(unsigned(avl_address), 29);
            remaining <= resize(unsigned(avl_burstcount), 9);
            ns     := S_RD_AR;
          elsif avl_write = '1' and rd_pending = 0 then
            word_addr <= resize(unsigned(avl_address), 29);
            remaining <= resize(unsigned(avl_burstcount), 9);
            wtaken    <= '0';
            wabort    <= '0';
            ns     := S_WR_AW;
          end if;

        when S_RD_AR =>
          if arvalid = '0' then
            n       := burst_beats(word_addr, remaining);
            chunk   <= n;
            byte_a  := shift_left(resize(word_addr, 32), 3) + unsigned(G_BYTE_OFFSET);
            ax_addr <= std_logic_vector(byte_a);
            ax_len  <= std_logic_vector(n(3 downto 0) - 1);
            arvalid <= '1';
          elsif m_axi_arready = '1' then
            arvalid   <= '0';
            rd_add    := resize(chunk, 10);
            word_addr <= word_addr + chunk;
            remaining <= remaining - chunk;
            if remaining = chunk then
              ns := S_IDLE;
            end if;
          end if;

        when S_WR_AW =>
          if awvalid = '0' and w_gone = '1' then
            ns := S_IDLE;                         -- withdrawn before any AXI request
          elsif awvalid = '0' then
            n       := burst_beats(word_addr, remaining);
            chunk   <= n;
            wbeats  <= n;
            byte_a  := shift_left(resize(word_addr, 32), 3) + unsigned(G_BYTE_OFFSET);
            ax_addr <= std_logic_vector(byte_a);
            ax_len  <= std_logic_vector(n(3 downto 0) - 1);
            awvalid <= '1';
          else
            if w_gone = '1' then
              wabort <= '1';                      -- the AW cannot be taken back
            end if;
            if m_axi_awready = '1' then
              awvalid   <= '0';
              wr_add    := '1';
              word_addr <= word_addr + chunk;
              remaining <= remaining - chunk;
              if wabort = '1' or w_gone = '1' then
                ns := S_WR_FLUSH;
              else
                ns := S_WR_DATA;
              end if;
            end if;
          end if;

        when S_WR_DATA =>
          if w_gone = '1' then
            ns := S_WR_FLUSH;                     -- withdrawn before its first beat
          elsif w_in = '1' then
            wtaken <= '1';
            wbeats <= wbeats - 1;
            if wbeats = 1 then
              -- the responses are counted below; a following read waits in S_IDLE for them
              if remaining = 0 then
                ns := S_IDLE;
              else
                ns := S_WR_AW;
              end if;
            end if;
          end if;

        when S_WR_FLUSH =>
          -- the rest of the burst as beats that write nothing; the rest of the command is dropped
          if w_fill = '1' then
            wbeats <= wbeats - 1;
            if wbeats = 1 then
              ns := S_IDLE;
            end if;
          end if;
      end case;

      -- write buffer
      if w_push = '1' then
        if w_fill = '1' then
          wbuf(to_integer(wbuf_wr)) <= (others => '0');
        else
          wbuf(to_integer(wbuf_wr)) <= '0' & avl_byteenable & avl_writedata;
        end if;
        if wbeats = 1 then
          wbuf(to_integer(wbuf_wr))(72) <= '1';
        end if;
        wbuf_wr <= wbuf_wr + 1;
      end if;
      if w_out = '1' then
        wbuf_rd <= wbuf_rd + 1;
      end if;
      if w_push = '1' and w_out = '0' then
        nlevel := wbuf_level + 1;
      elsif w_push = '0' and w_out = '1' then
        nlevel := wbuf_level - 1;
      end if;

      state      <= ns;
      wbuf_level <= nlevel;
      -- avl_waitrequest as a flip-flop output: the same function of state and level, one cycle ahead
      -- a read is accepted in its first S_RD_AR cycle (address and count are latched): its data
      -- can only follow the acceptance, also when the AXI side splits it into several bursts
      if (state = S_IDLE and ns = S_RD_AR) or (ns = S_WR_DATA and nlevel /= 4) then
        wait_r <= '0';
      else
        wait_r <= '1';
      end if;

      -- outstanding read beats and write responses
      if rd_sub = '1' then
        rd_pending <= rd_pending + rd_add - 1;
      else
        rd_pending <= rd_pending + rd_add;
      end if;
      if wr_add = '1' and wr_sub = '0' then
        wr_pending <= wr_pending + 1;
      elsif wr_add = '0' and wr_sub = '1' then
        wr_pending <= wr_pending - 1;
      end if;

      if hold = '1' and state = S_IDLE and rd_pending = 0 and wr_pending = 0 then
        idle_i <= '1';
      else
        idle_i <= '0';
      end if;

      if (m_axi_rvalid = '1' and m_axi_rresp /= "00") or (m_axi_bvalid = '1' and m_axi_bresp /= "00") then
        error_flag <= '1';
      end if;

      if rst = '1' then
        state      <= S_IDLE;
        awvalid    <= '0';
        arvalid    <= '0';
        rd_pending <= (others => '0');
        wr_pending <= (others => '0');
        error_flag <= '0';
        idle_i     <= '0';
        remaining  <= (others => '0');
        wbeats     <= (others => '0');
        wtaken     <= '0';
        wabort     <= '0';
        wbuf_wr    <= (others => '0');
        wbuf_rd    <= (others => '0');
        wbuf_level <= (others => '0');
        wait_r     <= '1';
      end if;
    end if;
  end process;

end architecture rtl;
