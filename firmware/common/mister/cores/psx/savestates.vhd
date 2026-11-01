-------------------------------------------------------------------------------
-- Title      : PSX core profile: savestates without saving and loading
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : savestates.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-31
-------------------------------------------------------------------------------
-- Description:
--   Replaces rtl/savestates.vhd of PSX_MiSTer (same entity name, generics and
--   ports) for a core with savestates off (cores/psx/rules.py ties save_state
--   and load_state of psx_mister to 0).  The original is also the
--   reset sequencer of the core: after reset_in falls it pauses the system,
--   pulses ss_reset (every module loads its reset values into its savestate
--   registers) and reset_out, reads the four savestate headers (validSStates)
--   and clears scratchpad, SPU RAM, VRAM and main RAM (main RAM not after an
--   EXE download) in its "reset mode" load.  That part is kept with the same
--   states, counters and outputs; what only a save (save = '1') or a load of a
--   slot (load = '1') reaches is left out: the save states, the read-back
--   multiplexer of SS_DataRead_*, SS_rden, the header check of a slot.
--   With save = load = '0' the outputs equal those of the original in every
--   cycle (tb/psx_savestates_tb.vhd compares both).  In consequence:
--     SS_rden, saving_savestate, load_done, loading_savestate stay '0'; SS_wren
--     is only set for the scratchpad (12) and main RAM (16); SS_DataWrite,
--     ddr3_DIN and SS_SPURAM_dataWrite are 0 (reset mode writes zeros), so the
--     modules lose their savestate write and read-back logic in synthesis.
--   resetMode and savemode of the original are constant here ('1', '0'):
--   before the first reset neither is read.  Inputs only the left-out part
--   used (save, load, increaseSSHeaderCount, hps_busy, SS_DataRead_*,
--   ram_data, SS_SPURAM_dataRead) are ignored.  VHDL-93: no output port is
--   read back (internal copies instead).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ (derived from rtl/savestates.vhd of PSX_MiSTer,
-- Robert Peip, GPL-2.0-or-later)
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity savestates is
  generic (
    FASTSIM                : std_logic;
    SAVETYPESCOUNT         : integer := 17;
    Softmap_SaveState_ADDR : integer
  );
  port (
    clk1x                 : in  std_logic;
    clk2x                 : in  std_logic;
    clk2xIndex            : in  std_logic;
    ce                    : in  std_logic;
    reset_in              : in  std_logic;
    reset_out             : out std_logic := '0';
    ss_reset              : out std_logic := '0';

    hps_busy              : in  std_logic;
    loadExe               : in  std_logic;

    load_done             : out std_logic := '0';
    validSStates          : out std_logic_vector(3 downto 0);

    savestate_number      : in  integer range 0 to 3;
    increaseSSHeaderCount : in  std_logic;
    save                  : in  std_logic;
    load                  : in  std_logic;
    savestate_address     : in  integer;
    savestate_busy        : out std_logic;

    SS_idle               : in  std_logic;
    system_paused         : in  std_logic;
    savestate_pause       : out std_logic := '0';
    ddr3_savestate        : out std_logic := '0';

    useSPUSDRAM           : in  std_logic;

    SS_DataWrite          : out std_logic_vector(31 downto 0) := (others => '0');
    SS_Adr                : out unsigned(18 downto 0) := (others => '0');
    SS_wren               : out std_logic_vector(SAVETYPESCOUNT - 1 downto 0);
    SS_rden               : out std_logic_vector(SAVETYPESCOUNT - 1 downto 0);
    SS_DataRead_CPU       : in  std_logic_vector(31 downto 0) := (others => '0');
    SS_DataRead_GPU       : in  std_logic_vector(31 downto 0) := (others => '0');
    SS_DataRead_GPUTiming : in  std_logic_vector(31 downto 0) := (others => '0');
    SS_DataRead_DMA       : in  std_logic_vector(31 downto 0) := (others => '0');
    SS_DataRead_GTE       : in  std_logic_vector(31 downto 0) := (others => '0');
    SS_DataRead_JOYPAD    : in  std_logic_vector(31 downto 0) := (others => '0');
    SS_DataRead_MDEC      : in  std_logic_vector(31 downto 0) := (others => '0');
    SS_DataRead_MEMORY    : in  std_logic_vector(31 downto 0) := (others => '0');
    SS_DataRead_TIMER     : in  std_logic_vector(31 downto 0) := (others => '0');
    SS_DataRead_SOUND     : in  std_logic_vector(31 downto 0) := (others => '0');
    SS_DataRead_IRQ       : in  std_logic_vector(31 downto 0) := (others => '0');
    SS_DataRead_SIO       : in  std_logic_vector(31 downto 0) := (others => '0');
    SS_DataRead_SCP       : in  std_logic_vector(31 downto 0) := (others => '0');
    SS_DataRead_CD        : in  std_logic_vector(31 downto 0) := (others => '0');

    sdram_done            : in  std_logic;

    loading_savestate     : out std_logic := '0';
    saving_savestate      : out std_logic := '0';

    ddr3_BUSY             : in  std_logic;
    ddr3_DOUT             : in  std_logic_vector(63 downto 0);
    ddr3_DOUT_READY       : in  std_logic;
    ddr3_BURSTCNT         : out std_logic_vector(7 downto 0) := (others => '0');
    ddr3_ADDR             : out std_logic_vector(25 downto 0) := (others => '0');
    ddr3_DIN              : out std_logic_vector(63 downto 0) := (others => '0');
    ddr3_BE               : out std_logic_vector(7 downto 0) := (others => '0');
    ddr3_WE               : out std_logic := '0';
    ddr3_RD               : out std_logic := '0';

    ram_done              : in  std_logic;
    ram_data              : in  std_logic_vector(31 downto 0);

    SS_SPURAM_dataWrite   : out std_logic_vector(15 downto 0) := (others => '0');
    SS_SPURAM_Adr         : out std_logic_vector(18 downto 0) := (others => '0');
    SS_SPURAM_request     : out std_logic := '0';
    SS_SPURAM_rnw         : out std_logic := '0';
    SS_SPURAM_dataRead    : in  std_logic_vector(15 downto 0);
    SS_SPURAM_done        : in  std_logic
  );
end entity savestates;

architecture reset_only of savestates is

  constant STATESIZE     : integer := 1048574;
  constant SAVESTATESIZE : integer := 16#100000#;  -- 1048576 dwords = 4096 KB
  constant SETTLECOUNT   : integer := 4095;

  signal savetype_counter : integer range 0 to SAVETYPESCOUNT;
  type tsavetype is record
    offset : integer;
    size   : integer;
  end record;
  type t_savetypes is array (0 to SAVETYPESCOUNT - 1) of tsavetype;
  -- the table of the original; reset mode visits 12 (scratchpad), 14 (SPU RAM),
  -- 15 (VRAM) and 16 (main RAM)
  constant savetypes : t_savetypes := (
    (  1024,    128),   -- CPU          0
    (  2048,      8),   -- GPU          1
    (  3072,      8),   -- GPUTiming    2
    (  4096,     64),   -- DMA          3
    (  5120,     64),   -- GTE          4
    (  6144,      8),   -- Joypad       5
    (  7168,    128),   -- MDEC         6
    (  8192,     32),   -- Memory       7
    (  9216,     16),   -- Timer        8
    ( 10240,    512),   -- Sound        9
    ( 11264,      2),   -- IRQ          10
    ( 12288,      8),   -- SIO          11
    ( 31744,    256),   -- Scratchpad   12
    ( 32768,  16384),   -- CDROM        13
    (131072, 131072),   -- SPURAM       14
    (262144, 262144),   -- VRAM         15
    (524288, 524288)    -- RAM          16
  );

  type tstate is (
    IDLE,
    WAITPAUSE,
    WAITIDLE,
    LOAD_WAITSETTLE,
    LOAD_RESETSSCHECK,
    LOAD_HEADERAMOUNTCHECK,
    LOADMEMORY_NEXT,
    LOADMEMORY_READ,
    LOADMEMORY_WRITE,
    LOADMEMORY_WRITE_VRAM,
    LOADMEMORY_WRITE_SDRAM,
    LOADMEMORY_WRITE_SPURAM,
    LOADMEMORY_WAIT_SPURAM,
    LOADMEMORY_WRITE_NEXT
  );
  signal state : tstate := IDLE;

  signal count    : integer range 0 to 524288 := 0;
  signal maxcount : integer range 0 to 524288;

  signal ssValid    : std_logic_vector(3 downto 0) := (others => '0');
  signal ssValidCnt : integer range 0 to 3;

  signal settle : integer range 0 to SETTLECOUNT := 0;

  signal reset_2x      : std_logic := '0';
  signal ss_reset_2x   : std_logic := '0';
  signal loading_ss_2x : std_logic := '0';

  -- internal copies of outputs the original reads back (VHDL-93)
  signal reset_out_i : std_logic := '0';
  signal ss_reset_i  : std_logic := '0';
  signal ddr3_ADDR_i : std_logic_vector(25 downto 0) := (others => '0');

  signal SS_Adr_2x  : unsigned(18 downto 0) := (others => '0');
  signal SS_wren_2x : std_logic_vector(SAVETYPESCOUNT - 1 downto 0);

  signal unstallwait : integer range 0 to 67108863 := 0;

  signal ddr3_ADDR_save : std_logic_vector(25 downto 0) := (others => '0');
  signal dwordcounter   : integer range 0 to 1 := 0;
  signal SPUwordcounter : integer range 0 to 3 := 0;
  signal RAMAddrNext    : unsigned(18 downto 0) := (others => '0');

  signal SPURAM_done1X : std_logic := '0';
  signal SPURAM_done2X : std_logic := '0';

  signal reset_in_1 : std_logic := '0';
  signal exeMode    : std_logic := '0';

begin

  savestate_busy <= '0' when state = IDLE else '1';

  ddr3_BURSTCNT <= x"01";

  validSStates <= ssValid;

  reset_out <= reset_out_i;
  ss_reset  <= ss_reset_i;
  ddr3_ADDR <= ddr3_ADDR_i;

  -- reset mode writes zeros, nothing is ever read back
  SS_DataWrite        <= (others => '0');
  SS_SPURAM_dataWrite <= (others => '0');
  SS_SPURAM_rnw       <= '0';
  ddr3_DIN            <= (others => '0');
  saving_savestate    <= '0';
  load_done           <= '0';
  loading_savestate   <= '0';

  process (clk1x)
  begin
    if rising_edge(clk1x) then

      reset_out_i <= reset_2x and (not ss_reset_2x);
      ss_reset_i  <= ss_reset_2x;

      SS_wren <= (others => '0');
      if (unsigned(SS_wren_2x) > 0) then
        SS_Adr  <= SS_Adr_2x;
        SS_wren <= SS_wren_2x;
      end if;

      SS_rden <= (others => '0');

      SPURAM_done1X <= '0';
      if (SS_SPURAM_done = '1') then
        SPURAM_done1X <= '1';
      end if;

    end if;
  end process;

  process (clk2x)
  begin
    if rising_edge(clk2x) then

      if (clk2xIndex = '0') then
        SS_wren_2x        <= (others => '0');
        SS_SPURAM_request <= '0';
      end if;

      if (reset_out_i = '1') then
        reset_2x <= '0';
      end if;

      if (ss_reset_i = '1') then
        ss_reset_2x <= '0';
      end if;

      SPURAM_done2X <= '0';
      if (SPURAM_done1X = '1') then
        SPURAM_done2X <= '1';
      end if;

      if (ddr3_BUSY = '0') then
        ddr3_WE <= '0';
        ddr3_RD <= '0';
      end if;

      if (loadExe = '1') then
        exeMode <= '1';
      end if;

      case state is

        when IDLE =>
          savestate_pause <= '0';
          ddr3_savestate  <= '0';
          unstallwait     <= 1023;
          if (reset_in_1 = '1' and reset_in = '0') then
            state            <= WAITPAUSE;
            reset_2x         <= '1';
            ss_reset_2x      <= '1';
            savetype_counter <= 12;
            settle           <= 0;
          end if;

        when WAITPAUSE =>
          if (settle < 8) then
            settle <= settle + 1;
          else
            savestate_pause <= '1';
            if (system_paused = '1') then
              state  <= WAITIDLE;
              settle <= 0;
            elsif (unstallwait > 0) then
              unstallwait <= unstallwait - 1;
            elsif (exeMode = '0') then
              reset_2x    <= '1';
              ss_reset_2x <= '1';
              unstallwait <= 1023;
            end if;
          end if;

        when WAITIDLE =>
          if (settle < 8) then
            settle <= settle + 1;
          else
            if (SS_idle = '1') then
              state  <= LOAD_WAITSETTLE;
              settle <= 0;
            else
              state           <= WAITPAUSE;
              settle          <= 0;
              savestate_pause <= '0';
              reset_2x        <= '1';
            end if;
          end if;

        when LOAD_WAITSETTLE =>
          if (settle < SETTLECOUNT) then
            settle <= settle + 1;
          else
            state       <= LOAD_RESETSSCHECK;
            ddr3_ADDR_i <= std_logic_vector(to_unsigned(Softmap_SaveState_ADDR, 26));
            ssValidCnt  <= 0;
            ssValid     <= (others => '0');
            ddr3_RD     <= '1';
          end if;

          if (settle > (SETTLECOUNT / 2)) then
            ddr3_savestate <= '1';
          end if;

        when LOAD_RESETSSCHECK =>
          if (ddr3_DOUT_READY = '1') then
            if (ddr3_DOUT(63 downto 32) = std_logic_vector(to_unsigned(STATESIZE, 32))) then
              ssValid(ssValidCnt) <= '1';
            end if;
            if (ssValidCnt = 3) then
              ddr3_ADDR_i <= std_logic_vector(to_unsigned(savestate_address, 26));
              state       <= LOAD_HEADERAMOUNTCHECK;
            else
              ddr3_ADDR_i <= std_logic_vector(unsigned(ddr3_ADDR_i) + to_unsigned(SAVESTATESIZE, 26));
              ssValidCnt  <= ssValidCnt + 1;
              ddr3_RD     <= '1';
            end if;
          end if;

        when LOAD_HEADERAMOUNTCHECK =>
          state         <= LOADMEMORY_NEXT;
          loading_ss_2x <= '1';
          reset_2x      <= '1';
          ss_reset_2x   <= '1';

        when LOADMEMORY_NEXT =>
          if ((FASTSIM = '0' and ((exeMode = '0' and savetype_counter < SAVETYPESCOUNT) or
                                  (exeMode = '1' and savetype_counter < 16))) or
              (FASTSIM = '1' and savetype_counter < 14)) then
            ddr3_ADDR_i  <= std_logic_vector(to_unsigned(savestate_address + savetypes(savetype_counter).offset, 26));
            ddr3_RD      <= '0';               -- "not resetMode": reset mode reads nothing
            state        <= LOADMEMORY_READ;
            count        <= 2;
            maxcount     <= savetypes(savetype_counter).size;
            RAMAddrNext  <= (others => '0');
            dwordcounter <= 0;
          else
            state         <= IDLE;
            reset_2x      <= '1';
            loading_ss_2x <= '0';
          end if;

        when LOADMEMORY_READ =>
          ddr3_ADDR_save <= ddr3_ADDR_i;
          state          <= LOADMEMORY_WRITE;

          if (savetype_counter = 14) then  -- spuram
            if (useSPUSDRAM = '1' or count <= 1024 or count > 16#1C000#) then
              dwordcounter   <= 1;
              state          <= LOADMEMORY_WRITE_SPURAM;
              SPUwordcounter <= 0;
            else
              dwordcounter <= 1;
              state        <= LOADMEMORY_WRITE_VRAM;
              ddr3_WE      <= '1';
              ddr3_BE      <= x"FF";
              ddr3_ADDR_i  <= "000000110" & std_logic_vector(RAMAddrNext(17 downto 1));
              RAMAddrNext  <= RAMAddrNext + 4;
            end if;
          end if;
          if (savetype_counter = 15) then  -- vram
            dwordcounter <= 1;
            state        <= LOADMEMORY_WRITE_VRAM;
            ddr3_WE      <= '1';
            ddr3_BE      <= x"FF";
            ddr3_ADDR_i  <= "0000000" & std_logic_vector(RAMAddrNext);
            RAMAddrNext  <= RAMAddrNext + 2;
          end if;

        when LOADMEMORY_WRITE =>
          -- reached for the scratchpad (12) and main RAM (16) only
          if (clk2xIndex = '0') then
            RAMAddrNext <= RAMAddrNext + 1;
            SS_Adr_2x   <= RAMAddrNext;
            state       <= LOADMEMORY_WRITE_NEXT;
            if (savetype_counter = 16) then  -- sdram
              SS_wren_2x(16) <= '1';
              state          <= LOADMEMORY_WRITE_SDRAM;
            else
              SS_wren_2x(12) <= '1';
            end if;
          end if;

        when LOADMEMORY_WRITE_VRAM =>
          if (ddr3_BUSY = '0') then
            state <= LOADMEMORY_WRITE_NEXT;
          end if;

        when LOADMEMORY_WRITE_SDRAM =>
          if (sdram_done = '1') then
            state <= LOADMEMORY_WRITE_NEXT;
          end if;

        when LOADMEMORY_WRITE_SPURAM =>
          state             <= LOADMEMORY_WAIT_SPURAM;
          SS_SPURAM_Adr     <= std_logic_vector(RAMAddrNext(17 downto 0) & '0');
          SS_SPURAM_request <= '1';
          RAMAddrNext       <= RAMAddrNext + 1;

        when LOADMEMORY_WAIT_SPURAM =>
          if (SPURAM_done2X = '1') then
            if (SPUwordcounter = 3) then
              state <= LOADMEMORY_WRITE_NEXT;
              if (FASTSIM = '1' and count = 1024) then
                count          <= count + 16#1C000# - 1024;
                RAMAddrNext    <= RAMAddrNext + (16#38000# - 2048);
                ddr3_ADDR_save <= std_logic_vector(unsigned(ddr3_ADDR_save) + 16#1C000# - 1024);
              end if;
            else
              state          <= LOADMEMORY_WRITE_SPURAM;
              SPUwordcounter <= SPUwordcounter + 1;
            end if;
          end if;

        when LOADMEMORY_WRITE_NEXT =>
          state <= LOADMEMORY_WRITE;
          if (dwordcounter < 1) then
            dwordcounter <= dwordcounter + 1;
          else
            ddr3_ADDR_i <= std_logic_vector(unsigned(ddr3_ADDR_save) + 2);
            if (count < maxcount) then
              state        <= LOADMEMORY_READ;
              count        <= count + 2;
              dwordcounter <= 0;
              ddr3_RD      <= '0';             -- "not resetMode"
            else
              if (savetype_counter = 12) then
                savetype_counter <= 14;
              else
                savetype_counter <= savetype_counter + 1;
              end if;
              state <= LOADMEMORY_NEXT;
            end if;
          end if;

      end case;

      reset_in_1 <= reset_in;
      if (reset_in = '1' and reset_in_1 = '0') then
        state <= IDLE;
      end if;

    end if;
  end process;

end architecture reset_only;
