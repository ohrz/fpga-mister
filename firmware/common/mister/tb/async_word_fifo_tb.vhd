-------------------------------------------------------------------------------
-- Title      : Testbench of async_word_fifo
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : async_word_fifo_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-11-07
-- Standard   : VHDL-2008
-------------------------------------------------------------------------------
-- Description:
--   Writer at 74.25 MHz writing every other cycle (as zcu106_hdmi), reader at
--   37.125 MHz with a phase offset (generic, the Makefile runs several).
--   Checks:
--     1. the reader starts within a bounded time after reset and reads every
--        cycle from then on (rd_run stays high while the writer keeps up);
--     2. the words come out complete and in order (a counter), none lost or
--        repeated while rd_run is high;
--     3. no underflow in steady state;
--     4. a gap of the writer causes rd_under and a stop of the reader; after
--        the writer resumes the reader starts again, the words still in order;
--     5. the reader never runs with fewer than G_START words written in the
--        start-up window (it waits for G_START), and in steady state the
--        FIFO holds at least G_START + 1 words (G_START seen through the
--        synchronizer plus its latency) and leaves 3 free (depth 16, read
--        from the DUT's pointers).
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity async_word_fifo_tb is
  generic (
    G_PHASE_PS : natural := 13000      -- reader clock phase offset (make test: 13 ns, -g for others)
  );
end entity async_word_fifo_tb;

architecture sim of async_word_fifo_tb is

  constant C_WPER : time := 13468 ps;  -- 74.25 MHz
  constant C_RPER : time := 26936 ps;  -- 37.125 MHz

  signal wr_clk, rd_clk : std_logic := '0';
  signal wr_rst, rd_rst : std_logic := '1';
  signal wr_en          : std_logic := '0';
  signal wr_data        : std_logic_vector(59 downto 0) := (others => '0');
  signal wr_full        : std_logic;
  signal rd_data        : std_logic_vector(59 downto 0);
  signal rd_run         : std_logic;
  signal rd_under       : std_logic;

  signal gap      : boolean := false;   -- writer pauses
  signal done     : boolean := false;
  signal wr_count : natural := 0;

  signal errors   : natural := 0;
  signal rd_count : natural := 0;
  signal min_fill : integer := integer'high;
  signal max_fill : integer := 0;
  signal steady   : boolean := false;
  signal occ      : integer;               -- true occupancy (DUT pointers)

begin

  wr_clk <= not wr_clk after C_WPER / 2 when not done;
  process
  begin
    wait for G_PHASE_PS * 1 ps;
    while not done loop
      rd_clk <= '1'; wait for C_RPER / 2;
      rd_clk <= '0'; wait for C_RPER / 2;
    end loop;
    wait;
  end process;

  dut : entity work.async_word_fifo
    generic map (G_WIDTH => 60, G_ABITS => 4, G_START => 4)
    port map (wr_clk => wr_clk, wr_rst => wr_rst, wr_en => wr_en, wr_data => wr_data, wr_full => wr_full,
              rd_clk => rd_clk, rd_rst => rd_rst, rd_data => rd_data, rd_run => rd_run, rd_under => rd_under);

  -- true occupancy from the DUT's binary pointers (external names, after the instance)
  probe : block
    alias wr_ptr is << signal .async_word_fifo_tb.dut.wr_bin : unsigned(4 downto 0) >>;
    alias rd_ptr is << signal .async_word_fifo_tb.dut.rd_bin : unsigned(4 downto 0) >>;
  begin
    occ <= to_integer(wr_ptr - rd_ptr);
  end block;

  -- writer: a counter every other wr_clk, unless gap
  process (wr_clk)
    variable ph  : std_logic := '0';
    variable cnt : unsigned(59 downto 0) := (others => '0');
  begin
    if rising_edge(wr_clk) then
      wr_en <= '0';
      if wr_rst = '0' and not gap then
        ph := not ph;
        if ph = '1' then
          wr_data <= std_logic_vector(cnt);
          wr_en   <= '1';
          cnt     := cnt + 1;
          wr_count <= wr_count + 1;
        end if;
      end if;
      if wr_full = '1' and wr_en = '1' then
        report "FAIL: write into a full FIFO" severity error;
      end if;
    end if;
  end process;

  -- reader checks
  process (rd_clk)
    variable expect   : unsigned(59 downto 0) := (others => '0');
    variable started  : boolean := false;
    variable last_run : std_logic := '0';
    variable first    : boolean := true;
  begin
    if rising_edge(rd_clk) then
      -- a word was read in the previous cycle when the reader ran then and still runs
      -- (an underflow stops it without a read)
      if last_run = '1' and rd_run = '1' then
        if first then
          expect := unsigned(rd_data);
          first  := false;
        end if;
        if unsigned(rd_data) /= expect then
          report "FAIL: word " & to_hstring(rd_data) & " expected " & to_hstring(std_logic_vector(expect))
            severity error;
          errors <= errors + 1;
          expect := unsigned(rd_data);
        end if;
        expect := expect + 1;
        rd_count <= rd_count + 1;
      end if;
      if steady and occ < min_fill then
        min_fill <= occ;
      end if;
      if steady and occ > max_fill then
        max_fill <= occ;
      end if;
      if rd_run = '1' and not started then
        started := true;
        if wr_count < 4 then
          report "FAIL: reader started with " & integer'image(wr_count) & " words written" severity error;
          errors <= errors + 1;
        end if;
      end if;
      last_run := rd_run;
    end if;
  end process;

  stim : process
    variable runs : natural := 0;
  begin
    wait for 100 ns;
    wr_rst <= '0';
    wait for 37 ns;
    rd_rst <= '0';
    -- 1. start within 20 reader cycles
    for i in 1 to 20 loop
      wait until rising_edge(rd_clk);
      exit when rd_run = '1';
    end loop;
    assert rd_run = '1' report "FAIL: reader did not start" severity error;
    -- 2./3. steady state: 2000 reader cycles with rd_run high, no underflow
    for i in 1 to 20 loop
      wait until rising_edge(rd_clk);
    end loop;
    steady <= true;
    for i in 1 to 2000 loop
      wait until rising_edge(rd_clk);
      if rd_run /= '1' then
        report "FAIL: reader stopped in steady state" severity error;
        exit;
      end if;
    end loop;
    assert rd_under = '0' report "FAIL: underflow in steady state" severity error;
    steady <= false;
    report "steady state: " & integer'image(min_fill) & " to " & integer'image(max_fill) & " words in the FIFO";
    -- the reader waits for G_START words it sees through the synchronizer: at least G_START + 1 stay
    assert min_fill >= 4 + 1 report "FAIL: fill " & integer'image(min_fill) & " below G_START + 1 (underflow margin)"
      severity error;
    assert max_fill <= 16 - 3 report "FAIL: fill " & integer'image(max_fill) & " leaves no margin against overflow"
      severity error;
    -- 4. gap of the writer: underflow and stop, then restart
    gap <= true;
    wait for 30 * C_RPER;
    assert rd_under = '1' report "FAIL: no underflow flag after a writer gap" severity error;
    assert rd_run = '0' report "FAIL: reader still running without data" severity error;
    gap <= false;
    for i in 1 to 20 loop
      wait until rising_edge(rd_clk);
      exit when rd_run = '1';
    end loop;
    assert rd_run = '1' report "FAIL: reader did not restart" severity error;
    for i in 1 to 500 loop
      wait until rising_edge(rd_clk);
      if rd_run = '1' then runs := runs + 1; end if;
    end loop;
    assert runs = 500 report "FAIL: reader not steady after the restart" severity error;
    wait for 1 us;
    if errors = 0 then
      report "async_word_fifo_tb (phase " & integer'image(G_PHASE_PS) & " ps): PASS";
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
