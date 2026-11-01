-------------------------------------------------------------------------------
-- Title      : SDR SDRAM pin emulator (front end of the SDRAM replacement)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : sdram_emu.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Sits behind the unchanged SDRAM_* pins of a MiSTer core and behaves like a
--   16-bit SDR SDRAM (doc/ARCHITECTURE.md §3, stages B and C).  It decodes the
--   commands (ACTIVE, READ, WRITE, PRECHARGE, BURST TERMINATE, REFRESH, MODE
--   REGISTER SET), keeps the open row of every bank, runs read and write bursts
--   (length 1/2/4/8, sequential or interleaved, write burst mode) and turns
--   every beat into one word request on a generic back end port.  The back end
--   is a BRAM (sdram_bram, stage B) or a cache in front of the DDR (stage C).
--
--   Timing (all on clk, the clock the core runs its SDRAM controller on; the
--   core's command outputs are registered on its rising edge):
--     cycle k     the core shows a command; the emulator decodes it
--                 combinationally, a READ/WRITE beat goes to the back end in the
--                 same cycle (be_req), write data and DQM are taken from this cycle
--     edge n      the n-th rising edge after cycle k (edge 1 ends cycle k)
--     read beat i is put on dq_o at edge CL + G_RD_ADJ + i and held until the
--                 next beat replaces it.  G_RD_ADJ = 0 suits a core that samples
--                 DQ at edge CL + 1 (MSX: SDRAM_CLK = inverted clk_mem, data
--                 latched one clk_mem edge after the SDRAM's CL edge); edge
--                 CL + G_RD_ADJ must be >= 2 (the back end needs one cycle).
--   Read DQM is ignored (the core ignores masked beats); write DQM masks bytes.
--
--   Stalls (stage C): ce = 1 means the core gets the coming rising edge; the
--   emulator's own state advances only then.  stall (combinational) asks to
--   withhold the edge: a read beat is due and its data has not come back, or the
--   back end does not accept a beat.  While ce = 0 the core is frozen and its
--   command stays on the pins; a request accepted then is not repeated.  With
--   ce = 1 constant (stage B) a stall is an error: err_late is set.
--
--   Flat word address of a beat: bank & row & column (G_BANK_BITS + G_ROW_BITS +
--   G_COL_BITS bits); the region decoder of the back end works on it.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram_emu is
  generic (
    G_BANK_BITS : natural := 2;
    G_ROW_BITS  : natural := 13;
    G_COL_BITS  : natural := 9;        -- 9: 32 MB module, 10: 64/128 MB
    G_RD_ADJ    : integer := 0;        -- read data at edge CL + G_RD_ADJ (see above)
    G_MODE_INIT : std_logic_vector(12 downto 0) := "0000000100000"  -- CL 2, BL 1 until the first MRS
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;        -- synchronous, active high
    ce         : in  std_logic;        -- the core gets the coming edge (stage B: '1')

    -- SDRAM pins of the core
    sd_cs_n    : in  std_logic;
    sd_ras_n   : in  std_logic;
    sd_cas_n   : in  std_logic;
    sd_we_n    : in  std_logic;
    sd_ba      : in  std_logic_vector(G_BANK_BITS - 1 downto 0);
    sd_a       : in  std_logic_vector(12 downto 0);
    sd_dqm     : in  std_logic_vector(1 downto 0);   -- 1: DQMH, 0: DQML
    sd_dq_i    : in  std_logic_vector(15 downto 0);  -- data the core drives
    sd_dq_o    : out std_logic_vector(15 downto 0);  -- read data to the core
    sd_dq_oe   : out std_logic;                      -- '1' in the core cycle after a beat was put on dq_o

    -- back end: one word per request, read data in request order
    be_req     : out std_logic;
    be_we      : out std_logic;
    be_addr    : out std_logic_vector(G_BANK_BITS + G_ROW_BITS + G_COL_BITS - 1 downto 0);
    be_wdata   : out std_logic_vector(15 downto 0);
    be_wstrb   : out std_logic_vector(1 downto 0);   -- byte enables (not DQM)
    be_ready   : in  std_logic;
    be_rvalid  : in  std_logic;
    be_rdata   : in  std_logic_vector(15 downto 0);

    stall      : out std_logic;
    err_late   : out std_logic;        -- sticky: an edge passed while stall was set
    err_mode   : out std_logic         -- sticky: unsupported mode (full page, CL, edge < 2)
  );
end entity sdram_emu;

architecture rtl of sdram_emu is

  constant C_ADDR_W : natural := G_BANK_BITS + G_ROW_BITS + G_COL_BITS;
  constant C_DUE_W  : natural := 6;                 -- read beats in flight per edge position

  type row_array_t is array (0 to 2 ** G_BANK_BITS - 1) of std_logic_vector(G_ROW_BITS - 1 downto 0);
  signal open_row   : row_array_t;

  -- mode register
  signal mode       : std_logic_vector(12 downto 0);
  signal mode_bl    : unsigned(3 downto 0);         -- 1, 2, 4, 8
  signal mode_cl    : natural range 0 to 7;
  signal due_edge   : integer range -8 to 15;       -- edge of beat 0

  -- burst in progress (beats 1 .. b_len-1 come from here)
  signal b_active   : std_logic;
  signal b_we       : std_logic;
  signal b_bank     : std_logic_vector(G_BANK_BITS - 1 downto 0);
  signal b_row      : std_logic_vector(G_ROW_BITS - 1 downto 0);
  signal b_col      : unsigned(G_COL_BITS - 1 downto 0);
  signal b_cnt      : unsigned(3 downto 0);         -- next beat
  signal b_len      : unsigned(3 downto 0);

  -- decoded command of this cycle
  signal cmd        : std_logic_vector(3 downto 0);
  signal is_act, is_rd, is_wr, is_pre, is_bst, is_mrs : std_logic;

  -- the beat of this cycle
  signal beat_v     : std_logic;
  signal beat_we    : std_logic;
  signal beat_addr  : std_logic_vector(C_ADDR_W - 1 downto 0);
  signal req_done   : std_logic;                    -- accepted while the core was frozen
  signal req        : std_logic;

  -- read beats in flight: due(n) = beats issued n edges ago (bit vector over edges)
  signal due        : std_logic_vector(C_DUE_W downto 1);
  signal due_now    : std_logic;

  -- returned read data waiting for its edge
  type fifo_t is array (0 to 15) of std_logic_vector(15 downto 0);
  signal fifo       : fifo_t;
  signal f_wr, f_rd : unsigned(3 downto 0);
  signal f_cnt      : unsigned(4 downto 0);
  signal data_avail : std_logic;
  signal data_head  : std_logic_vector(15 downto 0);

  signal stall_i    : std_logic;
  signal dq_o       : std_logic_vector(15 downto 0);
  signal dq_oe      : std_logic;
  signal e_late     : std_logic;
  signal e_mode     : std_logic;

  -- column of beat i of a burst starting at col (sequential or interleaved, wrap in the burst)
  function beat_col(col : unsigned; i : unsigned(3 downto 0); bl : unsigned(3 downto 0);
                    interleave : std_logic) return unsigned is
    variable low  : unsigned(2 downto 0);
    variable c    : unsigned(col'length - 1 downto 0) := col;
    variable mask : unsigned(2 downto 0);
  begin
    mask := resize(bl - 1, 3);                       -- 0, 1, 3, 7
    if interleave = '1' then
      low := c(2 downto 0) xor resize(i, 3);
    else
      low := c(2 downto 0) + resize(i, 3);
    end if;
    c(2 downto 0) := (c(2 downto 0) and not mask) or (low and mask);
    return c;
  end function;

begin

  ------------------------------------------------------------------------------
  -- mode register fields
  ------------------------------------------------------------------------------
  with mode(2 downto 0) select mode_bl <=
    to_unsigned(1, 4) when "000",
    to_unsigned(2, 4) when "001",
    to_unsigned(4, 4) when "010",
    to_unsigned(8, 4) when others;                  -- "011"; reserved and full page flagged below
  mode_cl  <= to_integer(unsigned(mode(6 downto 4)));
  due_edge <= mode_cl + G_RD_ADJ;

  ------------------------------------------------------------------------------
  -- command decode (cs_n ras_n cas_n we_n)
  ------------------------------------------------------------------------------
  cmd    <= sd_cs_n & sd_ras_n & sd_cas_n & sd_we_n;
  is_act <= '1' when cmd = "0011" else '0';
  is_rd  <= '1' when cmd = "0101" else '0';
  is_wr  <= '1' when cmd = "0100" else '0';
  is_pre <= '1' when cmd = "0010" else '0';
  is_bst <= '1' when cmd = "0110" else '0';
  is_mrs <= '1' when cmd = "0000" else '0';

  ------------------------------------------------------------------------------
  -- the beat of this cycle: a new READ/WRITE, else the next beat of the burst
  -- (PRECHARGE and BURST TERMINATE end the burst)
  ------------------------------------------------------------------------------
  process (is_rd, is_wr, is_pre, is_bst, sd_ba, sd_a, open_row, b_active, b_we, b_bank, b_row,
           b_col, b_cnt, b_len, mode_bl, mode)
    variable col : unsigned(G_COL_BITS - 1 downto 0);
  begin
    beat_v    <= '0';
    beat_we   <= '0';
    beat_addr <= (others => '0');
    if is_rd = '1' or is_wr = '1' then
      beat_v    <= '1';
      beat_we   <= is_wr;
      beat_addr <= sd_ba & open_row(to_integer(unsigned(sd_ba))) & sd_a(G_COL_BITS - 1 downto 0);
    elsif b_active = '1' and is_pre = '0' and is_bst = '0' and b_cnt < b_len then
      col       := beat_col(b_col, b_cnt, mode_bl, mode(3));
      beat_v    <= '1';
      beat_we   <= b_we;
      beat_addr <= b_bank & b_row & std_logic_vector(col);
    end if;
  end process;

  req      <= beat_v and not req_done;
  be_req   <= req;
  be_we    <= beat_we;
  be_addr  <= beat_addr;
  be_wdata <= sd_dq_i;
  be_wstrb <= not sd_dqm;

  ------------------------------------------------------------------------------
  -- read data: due at the coming edge, available from the FIFO or straight from
  -- the back end
  ------------------------------------------------------------------------------
  process (due, due_edge)
  begin
    due_now <= '0';
    if due_edge >= 2 and due_edge - 1 <= C_DUE_W then
      due_now <= due(due_edge - 1);
    end if;
  end process;

  data_avail <= '1' when f_cnt /= 0 or be_rvalid = '1' else '0';
  data_head  <= fifo(to_integer(f_rd)) when f_cnt /= 0 else be_rdata;

  stall_i <= (due_now and not data_avail) or (req and not be_ready);
  stall   <= stall_i;

  ------------------------------------------------------------------------------
  -- state
  ------------------------------------------------------------------------------
  process (clk)
    variable pop  : std_logic;
    variable push : std_logic;
  begin
    if rising_edge(clk) then
      -- returned read data: straight to dq_o when due now, else into the FIFO
      pop  := ce and due_now and data_avail;
      if f_cnt = 0 then
        push := be_rvalid and not pop;              -- no FIFO entry: the beat went straight out
      else
        push := be_rvalid;
      end if;
      if push = '1' then
        fifo(to_integer(f_wr)) <= be_rdata;
        f_wr <= f_wr + 1;
      end if;
      if pop = '1' and f_cnt /= 0 then
        f_rd <= f_rd + 1;
      end if;
      if push = '1' and not (pop = '1' and f_cnt /= 0) then
        f_cnt <= f_cnt + 1;
      elsif push = '0' and pop = '1' and f_cnt /= 0 then
        f_cnt <= f_cnt - 1;
      end if;

      -- a request accepted while the core is frozen is not repeated
      if ce = '1' then
        req_done <= '0';
      elsif req = '1' and be_ready = '1' then
        req_done <= '1';
      end if;

      if ce = '1' then
        if stall_i = '1' then
          e_late <= '1';
        end if;

        -- read beat on the pins, driven until the next core edge (the core samples it there,
        -- however many master cycles without a core edge lie in between)
        dq_oe <= '0';
        if due_now = '1' then
          dq_o  <= data_head;
          dq_oe <= '1';
        end if;

        -- read beats in flight
        due <= due(C_DUE_W - 1 downto 1) & (beat_v and not beat_we);

        -- commands
        if is_act = '1' then
          open_row(to_integer(unsigned(sd_ba))) <= sd_a(G_ROW_BITS - 1 downto 0);
        end if;
        if is_mrs = '1' then
          mode <= sd_a;
        end if;
        if is_rd = '1' or is_wr = '1' then
          b_active <= '1';
          b_we     <= is_wr;
          b_bank   <= sd_ba;
          b_row    <= open_row(to_integer(unsigned(sd_ba)));
          b_col    <= unsigned(sd_a(G_COL_BITS - 1 downto 0));
          b_cnt    <= to_unsigned(1, 4);
          if is_wr = '1' and mode(9) = '1' then
            b_len <= to_unsigned(1, 4);             -- write burst mode: single location
          else
            b_len <= mode_bl;
          end if;
        elsif is_pre = '1' or is_bst = '1' then
          b_active <= '0';
        elsif b_active = '1' then
          if b_cnt + 1 >= b_len then
            b_active <= '0';
          end if;
          b_cnt <= b_cnt + 1;
        end if;
      end if;

      -- unsupported: full page burst, CL other than 2/3, read data before edge 2
      if mode(2) = '1' or (mode_cl /= 2 and mode_cl /= 3) or due_edge < 2 then
        e_mode <= '1';
      end if;

      if rst = '1' then
        mode     <= G_MODE_INIT;
        b_active <= '0';
        b_cnt    <= (others => '0');
        b_len    <= (others => '0');
        due      <= (others => '0');
        f_wr     <= (others => '0');
        f_rd     <= (others => '0');
        f_cnt    <= (others => '0');
        req_done <= '0';
        dq_o     <= (others => '0');
        dq_oe    <= '0';
        e_late   <= '0';
        e_mode   <= '0';
      end if;
    end if;
  end process;

  sd_dq_o  <= dq_o;
  sd_dq_oe <= dq_oe;
  err_late <= e_late;
  err_mode <= e_mode;

end architecture rtl;
