-------------------------------------------------------------------------------
-- Title      : TMDS encoder of one channel
-- Project    : fpga-mister (hdmi-tx)
-------------------------------------------------------------------------------
-- File       : tmds_enc.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-29
-------------------------------------------------------------------------------
-- Description:
--   de = 1: 8b/10b TMDS video encoding of d (DVI 1.0 3.2.2: transition
--   minimisation, then DC balance with the running disparity).
--   de = 0: sym is passed through (control token, TERC4, guard band, chosen
--   by hdmi_tx) and the disparity restarts at 0.  One clk of latency.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tmds_enc is
  port (
    clk : in  std_logic;
    de  : in  std_logic;
    d   : in  std_logic_vector(7 downto 0);
    sym : in  std_logic_vector(9 downto 0);
    q   : out std_logic_vector(9 downto 0)
  );
end entity tmds_enc;

architecture rtl of tmds_enc is

  signal cnt : signed(4 downto 0) := (others => '0');   -- running disparity: ones - zeros sent so far

  function ones(v : std_logic_vector) return natural is
    variable n : natural := 0;
  begin
    for i in v'range loop
      if v(i) = '1' then
        n := n + 1;
      end if;
    end loop;
    return n;
  end function;

begin

  process (clk)
    variable qm   : std_logic_vector(8 downto 0);
    variable n1d  : natural range 0 to 8;
    variable n1q  : natural range 0 to 8;
    variable diff : integer range -8 to 8;            -- ones - zeros of qm(7:0)
  begin
    if rising_edge(clk) then
      if de = '0' then
        q   <= sym;
        cnt <= (others => '0');
      else
        n1d := ones(d);
        qm(0) := d(0);
        if n1d > 4 or (n1d = 4 and d(0) = '0') then
          for i in 1 to 7 loop
            qm(i) := qm(i - 1) xnor d(i);
          end loop;
          qm(8) := '0';
        else
          for i in 1 to 7 loop
            qm(i) := qm(i - 1) xor d(i);
          end loop;
          qm(8) := '1';
        end if;
        n1q  := ones(qm(7 downto 0));
        diff := 2 * n1q - 8;
        if cnt = 0 or diff = 0 then
          q(9) <= not qm(8);
          q(8) <= qm(8);
          if qm(8) = '1' then
            q(7 downto 0) <= qm(7 downto 0);
            cnt <= cnt + diff;
          else
            q(7 downto 0) <= not qm(7 downto 0);
            cnt <= cnt - diff;
          end if;
        elsif (cnt > 0 and diff > 0) or (cnt < 0 and diff < 0) then
          q(9) <= '1';
          q(8) <= qm(8);
          q(7 downto 0) <= not qm(7 downto 0);
          if qm(8) = '1' then
            cnt <= cnt - diff + 2;
          else
            cnt <= cnt - diff;
          end if;
        else
          q(9) <= '0';
          q(8) <= qm(8);
          q(7 downto 0) <= qm(7 downto 0);
          if qm(8) = '1' then
            cnt <= cnt + diff;
          else
            cnt <= cnt + diff - 2;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
