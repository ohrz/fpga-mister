-------------------------------------------------------------------------------
-- Title      : I2C master bit engine (START, Sr, byte, STOP) with clock stretching
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : i2c_bit_engine.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-11-07
-------------------------------------------------------------------------------
-- Description:
--   One bus condition or one byte per command, for a register sequencer of a
--   board (the transaction framing, addresses and the register table are the
--   sequencer's, e.g. firmware/targets/zcu106/hdl/zcu106_hdmi_ctl.vhd):
--     cmd "00" START   bus idle -> SDA falls while SCL is high
--     cmd "01" RSTART  after a byte: repeated start
--     cmd "10" BYTE    txd(8 downto 1) MSB first, txd(0) in the ACK slot
--                      ('1' releases SDA: a slave ACKs, or the master NACKs a
--                      read); rxd = the 9 sampled bits, rxd(0) = ACK slot
--     cmd "11" STOP    SDA rises while SCL is high
--   go starts a command in idle; done pulses one cycle when it is over, tmo
--   with it when SCL stayed low longer than G_STRETCH_MAX_MS after being
--   released (stuck bus); the lines are released then.
--   Timing: 4 quarters of 1/(4*G_I2C_HZ) per bit, SDA changes in the second
--   low quarter, sampled at the end of the first high quarter.  Clock
--   stretching is followed: the high quarters start again from the rising
--   edge seen on the pin, so high time and sample point stay the same.
--   After a byte SCL stays low until the next command (low time grows,
--   never the high time of the ACK bit).
--   Open drain: scl_t/sda_t = '1' releases the line (IOBUF outside, its O
--   input constant '0').  scl_i, sda_i are synchronized here (2 stages).
--   rst (synchronous, active high) aborts a command and releases the bus.
--   Single master: no arbitration.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity i2c_bit_engine is
  generic (
    G_CLK_HZ         : positive := 100_000_000;
    G_I2C_HZ         : positive := 100_000;
    G_STRETCH_MAX_MS : positive := 10       -- SCL held low by a slave: tmo
  );
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;
    go    : in  std_logic;
    cmd   : in  std_logic_vector(1 downto 0);
    txd   : in  std_logic_vector(8 downto 0);
    rxd   : out std_logic_vector(8 downto 0);
    done  : out std_logic;
    tmo   : out std_logic;
    scl_i : in  std_logic;
    scl_t : out std_logic;
    sda_i : in  std_logic;
    sda_t : out std_logic
  );
end entity i2c_bit_engine;

architecture rtl of i2c_bit_engine is

  constant C_Q       : positive := G_CLK_HZ / (4 * G_I2C_HZ);
  constant C_STRETCH : positive := (G_CLK_HZ / 1000) * G_STRETCH_MAX_MS;

  type t_estate is (E_IDLE, E_START, E_RSTART, E_BIT, E_STOP);
  signal e_state : t_estate := E_IDLE;
  signal e_tx    : std_logic_vector(8 downto 0) := (others => '1');
  signal e_rx    : std_logic_vector(8 downto 0) := (others => '1');
  signal e_ph    : natural range 0 to 7 := 0;
  signal e_bitn  : natural range 0 to 8 := 8;
  signal e_qcnt  : natural range 0 to C_Q - 1 := 0;
  signal e_str   : natural range 0 to C_STRETCH := 0;
  signal done_r  : std_logic := '0';
  signal tmo_r   : std_logic := '0';
  signal scl_r   : std_logic := '1';        -- '1' = released
  signal sda_r   : std_logic := '1';

  signal scl_m, scl_s, sda_m, sda_s : std_logic := '1';

begin

  assert C_Q >= 4
    report "i2c_bit_engine: G_CLK_HZ must be at least 16 * G_I2C_HZ" severity failure;

  scl_t <= scl_r;
  sda_t <= sda_r;
  rxd   <= e_rx;
  done  <= done_r;
  tmo   <= tmo_r;

  sync : process (clk)
  begin
    if rising_edge(clk) then
      scl_m <= scl_i;
      scl_s <= scl_m;
      sda_m <= sda_i;
      sda_s <= sda_m;
    end if;
  end process;

  -- One step per command; a step is a number of quarters, the line levels of
  -- quarter ph are set when the quarter starts.
  --   START   (bus idle)        ph0-1 SCL 1 SDA 1, ph2-3 SCL 1 SDA 0
  --   RSTART  (SCL high)        ph0 SCL 0, ph1 SDA 1, ph2-3 SCL 1, ph4-5 SDA 0
  --   bit     (SCL high)        ph0 SCL 0, ph1 SDA bit, ph2-3 SCL 1, sample at
  --                             the end of ph2; 9 bits per byte (8 + ACK)
  --   STOP    (SCL high)        ph0 SCL 0, ph1 SDA 0, ph2-3 SCL 1, ph4-5 SDA 1
  engine : process (clk)
    variable last : natural range 0 to 7;
  begin
    if rising_edge(clk) then
      done_r <= '0';
      tmo_r  <= '0';
      if rst = '1' then
        e_state <= E_IDLE;
        scl_r   <= '1';
        sda_r   <= '1';
        e_qcnt  <= 0;
        e_str   <= 0;
      elsif e_state = E_IDLE then
        e_qcnt <= 0;
        e_str  <= 0;
        e_ph   <= 0;
        if go = '1' then
          case cmd is
            when "00" =>
              e_state <= E_START;
              scl_r   <= '1';
              sda_r   <= '1';
            when "01" =>
              e_state <= E_RSTART;
              scl_r   <= '0';
            when "10" =>
              e_state <= E_BIT;
              e_tx    <= txd;
              e_bitn  <= 8;
              scl_r   <= '0';
            when others =>
              e_state <= E_STOP;
              scl_r   <= '0';
          end case;
        end if;
      elsif e_qcnt /= C_Q - 1 then
        e_qcnt <= e_qcnt + 1;
      elsif scl_r = '1' and scl_s = '0' then
        -- SCL released but still low: clock stretching (or a stuck bus)
        if e_str = C_STRETCH then
          e_state <= E_IDLE;
          scl_r   <= '1';
          sda_r   <= '1';
          done_r  <= '1';
          tmo_r   <= '1';
        else
          e_str <= e_str + 1;
        end if;
      elsif e_str /= 0 then
        -- stretching ended: the quarter starts again from the rising edge on
        -- the pin (scl_s lags it by the two synchronizer stages), so the high
        -- time and the sample point stay as without stretching
        e_str  <= 0;
        e_qcnt <= 2;
      else
        e_qcnt <= 0;
        if e_state = E_START or e_state = E_BIT then
          last := 3;
        else
          last := 5;
        end if;
        if e_state = E_BIT and e_ph = 2 then
          e_rx <= e_rx(7 downto 0) & sda_s;
        end if;
        if e_ph = last then
          if e_state = E_BIT and e_bitn /= 0 then
            e_bitn <= e_bitn - 1;
            e_ph  <= 0;
            scl_r <= '0';
          else
            -- every command after a byte (byte, Sr, STOP) starts with SCL
            -- low: pull it now, the time to the next command adds to the
            -- low time instead of the high time of the ACK bit
            if e_state = E_BIT then
              scl_r <= '0';
            end if;
            e_state <= E_IDLE;
            done_r  <= '1';
          end if;
        else
          e_ph <= e_ph + 1;
          -- levels of quarter e_ph + 1
          case e_state is
            when E_START =>
              if e_ph + 1 = 2 then
                sda_r <= '0';
              end if;
            when E_RSTART =>
              case e_ph + 1 is
                when 1      => sda_r <= '1';
                when 2      => scl_r <= '1';
                when 4      => sda_r <= '0';
                when others => null;
              end case;
            when E_BIT =>
              case e_ph + 1 is
                when 1      => sda_r <= e_tx(e_bitn);
                when 2      => scl_r <= '1';
                when others => null;
              end case;
            when E_STOP =>
              case e_ph + 1 is
                when 1      => sda_r <= '0';
                when 2      => scl_r <= '1';
                when 4      => sda_r <= '1';
                when others => null;
              end case;
            when others => null;
          end case;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
