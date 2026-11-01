-------------------------------------------------------------------------------
-- Title      : Testbench of scc_rom_hide (MSX profile)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : scc_rom_hide_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-29
-------------------------------------------------------------------------------
-- Description:
--   Directed sequence of the game change: no mask before a mount; after a
--   mount the header bytes 4000h/4001h/8000h/8001h are masked and nothing
--   else; writes before the following reset, writes to page 2, reads and
--   writes without req keep the mask; the first page 1 write after the reset
--   (ROMLOAD's bank register 5000h) ends it and further resets keep it off;
--   a mount in the same clock as a reset hides again and the reset arms.
--   Ends with "PASS" or stops at the first failed check.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity scc_rom_hide_tb is
end entity scc_rom_hide_tb;

architecture sim of scc_rom_hide_tb is
  constant T : time := 46 ns;                     -- 21.48 MHz
  signal clk   : std_logic := '0';
  signal mount : std_logic := '0';
  signal reset : std_logic := '0';
  signal req   : std_logic := '0';
  signal wrt   : std_logic := '0';
  signal adr   : std_logic_vector(15 downto 0) := (others => '0');
  signal mask  : std_logic;
  signal done  : boolean := false;
begin

  clk <= not clk after T / 2 when not done;

  dut : entity work.scc_rom_hide
    port map (clk => clk, mount => mount, reset => reset, req => req, wrt => wrt, adr => adr, mask => mask);

  process
    -- one bus cycle of a few clocks at address a
    procedure access_cycle(a : natural; w : std_logic; r : std_logic := '1') is
    begin
      adr <= std_logic_vector(to_unsigned(a, 16));
      wrt <= w;
      req <= r;
      for i in 1 to 3 loop
        wait until rising_edge(clk);
      end loop;
      req <= '0';
      wrt <= '0';
      wait until rising_edge(clk);
    end procedure;

    procedure pulse(signal s : out std_logic; n : positive) is
    begin
      s <= '1';
      for i in 1 to n loop
        wait until rising_edge(clk);
      end loop;
      s <= '0';
      wait until rising_edge(clk);
    end procedure;

    -- mask at address a (combinational from adr)
    procedure expect(a : natural; m : std_logic; what : string) is
    begin
      adr <= std_logic_vector(to_unsigned(a, 16));
      wait for 1 ns;
      assert mask = m
        report what & ": mask at " & integer'image(a) & " = " & std_logic'image(mask) severity failure;
    end procedure;

    procedure expect_hidden(hidden : boolean; what : string) is
      variable m : std_logic;
    begin
      if hidden then m := '1'; else m := '0'; end if;
      expect(16#4000#, m, what);
      expect(16#4001#, m, what);
      expect(16#8000#, m, what);
      expect(16#8001#, m, what);
      -- never anything else
      expect(16#4002#, '0', what);
      expect(16#3FFF#, '0', what);
      expect(16#5000#, '0', what);
      expect(16#8002#, '0', what);
      expect(16#9800#, '0', what);
      expect(16#C000#, '0', what);
      expect(16#0000#, '0', what);
    end procedure;
  begin
    wait until rising_edge(clk);
    expect_hidden(false, "power-on");
    access_cycle(16#5000#, '1');
    pulse(reset, 20);
    expect_hidden(false, "reset without mount");

    -- mount while the old game runs: hidden, its bank writes do not end hiding
    pulse(mount, 1);
    expect_hidden(true, "after mount");
    access_cycle(16#5000#, '1');
    access_cycle(16#7000#, '1');
    expect_hidden(true, "page 1 writes before the reset");

    -- the reset after the mount (BIOS, MSX-DOS): reads, page 2/3 writes, writes without req
    pulse(reset, 20);
    expect_hidden(true, "after reset");
    access_cycle(16#4000#, '0');
    access_cycle(16#5000#, '0');
    access_cycle(16#8000#, '1');
    access_cycle(16#9000#, '1');
    access_cycle(16#BFFE#, '1');
    access_cycle(16#C000#, '1');
    access_cycle(16#3FFF#, '1');
    access_cycle(16#5000#, '1', '0');
    expect_hidden(true, "reads, page 0/2/3 writes, write without req");

    -- ROMLOAD sets bank 0: hiding ends, the next reset (ROMLOAD /R) keeps it off
    access_cycle(16#5000#, '1');
    expect_hidden(false, "after ROMLOAD bank write");
    pulse(reset, 20);
    access_cycle(16#5000#, '1');
    expect_hidden(false, "after ROMLOAD reset");

    -- second game change: mount in the same clock as a reset, the reset arms
    mount <= '1';
    reset <= '1';
    wait until rising_edge(clk);
    mount <= '0';
    for i in 1 to 20 loop
      wait until rising_edge(clk);
    end loop;
    reset <= '0';
    wait until rising_edge(clk);
    expect_hidden(true, "mount with reset");
    access_cycle(16#7FFF#, '1');
    expect_hidden(false, "page 1 end address write");

    report "PASS" severity note;
    done <= true;
    wait;
  end process;

end architecture sim;
