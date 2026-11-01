-------------------------------------------------------------------------------
-- Title      : AXI3 memory model for the testbenches (a Zynq S_AXI_HPx port)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : axi3_mem_model.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   64-bit AXI3 slave with 2**G_WORD_BITS words, random ready/valid gaps and an
--   optional minimum read latency (G_RD_LAT cycles from AR to the first R beat,
--   like the DDR behind an HP port).  Address bits above the memory are ignored.
--   Checks the AXI3 rules of the master: 8-byte INCR bursts, aligned, no burst
--   across 4 KB, WLAST on the last beat, no W beat before its AW.
--   Responses in order (single ID).  VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity axi3_mem_model is
  generic (
    G_WORD_BITS : natural := 14;       -- 16 K words = 128 KB
    G_RD_LAT    : natural := 0;        -- minimum cycles from AR to the first R beat
    G_SEED      : positive := 107
  );
  port (
    clk     : in  std_logic;
    awaddr  : in  std_logic_vector(31 downto 0);
    awlen   : in  std_logic_vector(3 downto 0);
    awsize  : in  std_logic_vector(2 downto 0);
    awburst : in  std_logic_vector(1 downto 0);
    awvalid : in  std_logic;
    awready : out std_logic := '0';
    wdata   : in  std_logic_vector(63 downto 0);
    wstrb   : in  std_logic_vector(7 downto 0);
    wlast   : in  std_logic;
    wvalid  : in  std_logic;
    wready  : out std_logic := '0';
    bvalid  : out std_logic := '0';
    bready  : in  std_logic;
    araddr  : in  std_logic_vector(31 downto 0);
    arlen   : in  std_logic_vector(3 downto 0);
    arsize  : in  std_logic_vector(2 downto 0);
    arburst : in  std_logic_vector(1 downto 0);
    arvalid : in  std_logic;
    arready : out std_logic := '0';
    rdata   : out std_logic_vector(63 downto 0) := (others => '0');
    rlast   : out std_logic := '0';
    rvalid  : out std_logic := '0';
    rready  : in  std_logic
  );
end entity axi3_mem_model;

architecture model of axi3_mem_model is
  type mem_t is array (0 to 2 ** G_WORD_BITS - 1) of std_logic_vector(63 downto 0);
  type ax_t is record addr : unsigned(31 downto 0); len : natural; t : natural; end record;
  type axq_t is array (0 to 255) of ax_t;
begin

  process
    variable mem : mem_t := (others => (others => '0'));
    variable s1, s2 : positive := G_SEED;
    variable r : real;
    variable awq, arq : axq_t;
    variable aw_wr, aw_rd, ar_wr, ar_rd : natural := 0;
    variable w_beat, r_beat : natural := 0;
    variable b_due : natural := 0;                  -- write responses owed
    variable idx : natural;
    variable a : ax_t;
    variable now_c : natural := 0;                  -- cycle counter
    variable bv, rv : std_logic := '0';             -- own copies of bvalid / rvalid

    impure function coin(p : real) return std_logic is
    begin
      uniform(s1, s2, r);
      if r < p then return '1'; else return '0'; end if;
    end function;

    function word(addr : unsigned(31 downto 0)) return natural is
    begin
      return to_integer(addr(G_WORD_BITS + 2 downto 3));
    end function;

    procedure check_ax(addr : std_logic_vector; len : std_logic_vector; size : std_logic_vector;
                       burst : std_logic_vector; ch : string) is
      variable first : natural := to_integer(unsigned(addr(11 downto 0)));
      variable bytes : natural := (to_integer(unsigned(len)) + 1) * 8;
    begin
      assert size = "011" and burst = "01" report ch & ": not an 8-byte INCR burst" severity failure;
      assert addr(2 downto 0) = "000" report ch & ": unaligned address" severity failure;
      assert first + bytes <= 4096 report ch & ": burst crosses 4 KB at " & to_hstring(addr) severity failure;
    end procedure;
  begin
    wait until rising_edge(clk);
    loop
      now_c := now_c + 1;
      -- AW
      if awvalid = '1' and awready = '1' then
        check_ax(awaddr, awlen, awsize, awburst, "AW");
        awq(aw_wr mod 256) := (unsigned(awaddr), to_integer(unsigned(awlen)) + 1, now_c);
        aw_wr := aw_wr + 1;
      end if;
      -- W (data of the oldest AW)
      if wvalid = '1' and wready = '1' then
        assert aw_rd < aw_wr report "W beat without AW" severity failure;
        a := awq(aw_rd mod 256);
        idx := (word(a.addr) + w_beat) mod 2 ** G_WORD_BITS;
        for b in 0 to 7 loop
          if wstrb(b) = '1' then mem(idx)(8 * b + 7 downto 8 * b) := wdata(8 * b + 7 downto 8 * b); end if;
        end loop;
        w_beat := w_beat + 1;
        assert (wlast = '1') = (w_beat = a.len) report "WLAST wrong" severity failure;
        if w_beat = a.len then
          w_beat := 0; aw_rd := aw_rd + 1; b_due := b_due + 1;
        end if;
      end if;
      -- B
      if bv = '1' and bready = '1' then
        b_due := b_due - 1;
      end if;
      -- AR
      if arvalid = '1' and arready = '1' then
        check_ax(araddr, arlen, arsize, arburst, "AR");
        arq(ar_wr mod 256) := (unsigned(araddr), to_integer(unsigned(arlen)) + 1, now_c);
        ar_wr := ar_wr + 1;
      end if;
      -- R
      if rv = '1' and rready = '1' then
        r_beat := r_beat + 1;
        if r_beat = arq(ar_rd mod 256).len then r_beat := 0; ar_rd := ar_rd + 1; end if;
      end if;

      -- outputs of the next cycle
      awready <= coin(0.6);
      wready  <= coin(0.7);
      arready <= coin(0.6);
      if b_due > 0 and not (bv = '1' and bready = '0') then
        bv := coin(0.5);
      elsif b_due = 0 then
        bv := '0';
      end if;
      bvalid <= bv;
      if not (rv = '1' and rready = '0') then
        rv := '0';
        rlast <= '0';
        if ar_rd < ar_wr and now_c >= arq(ar_rd mod 256).t + G_RD_LAT and coin(0.7) = '1' then
          a := arq(ar_rd mod 256);
          rdata <= mem((word(a.addr) + r_beat) mod 2 ** G_WORD_BITS);
          rv := '1';
          if r_beat + 1 = a.len then rlast <= '1'; end if;
        end if;
      end if;
      rvalid <= rv;
      wait until rising_edge(clk);
    end loop;
  end process;

end architecture model;
