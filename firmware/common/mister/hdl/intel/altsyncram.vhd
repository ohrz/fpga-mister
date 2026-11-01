-------------------------------------------------------------------------------
-- Title      : Replacement of the Intel megafunction altsyncram for Vivado
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : altsyncram.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Same name, generics and ports as the Intel altsyncram, so MiSTer sources
--   that instantiate it (sys/sd_card.sv with defparam, SNES rtl/bram.vhd, N64
--   rtl/dpram.vhd) stay unchanged.  The
--   subset the MiSTer sources use is implemented; any other setting stops the
--   synthesis with an assertion instead of building something different:
--     operation_mode   BIDIR_DUAL_PORT (port A on clock0, port B on clock1) or
--                      SINGLE_PORT (port A only)
--     outdata_reg_a/b  UNREGISTERED: q one clock after the address (block RAM
--                      without output register)
--     read during write on the same port: new data (NEW_DATA_NO_NBE_READ,
--                      NEW_DATA_WITH_NBE_READ, DONT_CARE)
--     widths           width_a / width_b may differ by a power of two (mixed
--                      width ports); the wider word holds the narrower words
--                      little endian, as on Intel
--     clock enables    clock_enable_input_a/b NORMAL: clocken0/clocken1 = '0'
--                      holds port A/B (no write, q keeps its value); BYPASS
--                      ignores them
--     numwords_a/b     up to 2**widthad (0: 2**widthad)
--     init_file        a .mem file: one line per port A word, width_a binary
--                      digits, missing words 0 (prepare_sources.py converts
--                      the .mif files of a core); "UNUSED", "" or " ": none
--     byte enables     width_byteena_a/b > 1: one bit per byte_size bits of the
--                      port word (byte 0 = bit 0), each a column of a narrow
--                      word (byte-write RAM); a disabled byte keeps its
--                      contents and reads back its old value on the write
--                      (NEW_DATA_NO_NBE_READ leaves it undefined,
--                      NEW_DATA_WITH_NBE_READ asks for the old value).  A port
--                      with width_byteena 1 writes whole words.
--   Not supported: address stalls, aclr, ECC, output registers, output clock
--   enables (the inputs exist and must be inactive), an init_file with mixed
--   widths and byte enables.
--   Collisions between the ports (same location, same time) are undefined, as
--   on Intel with two clocks.  Inferred as true dual port block RAM (mixed
--   widths with byte enables: one per narrow word of the wide port).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity altsyncram is
  generic (
    operation_mode                     : string  := "BIDIR_DUAL_PORT";
    width_a                            : integer := 8;
    widthad_a                          : integer := 11;
    numwords_a                         : integer := 0;
    width_b                            : integer := 8;
    widthad_b                          : integer := 11;
    numwords_b                         : integer := 0;
    width_byteena_a                    : integer := 1;
    width_byteena_b                    : integer := 1;
    byte_size                          : integer := 8;
    outdata_reg_a                      : string  := "UNREGISTERED";
    outdata_reg_b                      : string  := "UNREGISTERED";
    outdata_aclr_a                     : string  := "NONE";
    outdata_aclr_b                     : string  := "NONE";
    address_reg_b                      : string  := "CLOCK1";
    indata_reg_b                       : string  := "CLOCK1";
    wrcontrol_wraddress_reg_b          : string  := "CLOCK1";
    clock_enable_input_a               : string  := "BYPASS";
    clock_enable_input_b               : string  := "BYPASS";
    clock_enable_output_a              : string  := "BYPASS";
    clock_enable_output_b              : string  := "BYPASS";
    read_during_write_mode_port_a      : string  := "NEW_DATA_NO_NBE_READ";
    read_during_write_mode_port_b      : string  := "NEW_DATA_NO_NBE_READ";
    read_during_write_mode_mixed_ports : string  := "DONT_CARE";
    power_up_uninitialized             : string  := "FALSE";
    init_file                          : string  := "UNUSED";
    ram_block_type                     : string  := "AUTO";
    intended_device_family             : string  := "Cyclone V";
    lpm_type                           : string  := "altsyncram";
    lpm_hint                           : string  := "UNUSED"
  );
  port (
    clock0         : in  std_logic := '1';
    clock1         : in  std_logic := '1';
    address_a      : in  std_logic_vector(widthad_a - 1 downto 0);
    data_a         : in  std_logic_vector(width_a - 1 downto 0) := (others => '1');
    wren_a         : in  std_logic := '0';
    rden_a         : in  std_logic := '1';
    q_a            : out std_logic_vector(width_a - 1 downto 0);
    address_b      : in  std_logic_vector(widthad_b - 1 downto 0) := (others => '1');
    data_b         : in  std_logic_vector(width_b - 1 downto 0) := (others => '1');
    wren_b         : in  std_logic := '0';
    rden_b         : in  std_logic := '1';
    q_b            : out std_logic_vector(width_b - 1 downto 0);
    aclr0          : in  std_logic := '0';
    aclr1          : in  std_logic := '0';
    addressstall_a : in  std_logic := '0';
    addressstall_b : in  std_logic := '0';
    byteena_a      : in  std_logic_vector(width_byteena_a - 1 downto 0) := (others => '1');
    byteena_b      : in  std_logic_vector(width_byteena_b - 1 downto 0) := (others => '1');
    clocken0       : in  std_logic := '1';
    clocken1       : in  std_logic := '1';
    clocken2       : in  std_logic := '1';
    clocken3       : in  std_logic := '1';
    eccstatus      : out std_logic_vector(2 downto 0)
  );
end entity altsyncram;

architecture rtl of altsyncram is

  function minimum(a, b : integer) return integer is
  begin
    if a < b then return a; else return b; end if;
  end function;
  function maximum(a, b : integer) return integer is
  begin
    if a > b then return a; else return b; end if;
  end function;
  function log2(n : integer) return integer is
    variable r : integer := 0;
  begin
    while 2 ** r < n loop r := r + 1; end loop;
    return r;
  end function;

  function sel(c : boolean; a, b : integer) return integer is
  begin
    if c then return a; else return b; end if;
  end function;

  constant C_DUAL   : boolean := operation_mode = "BIDIR_DUAL_PORT";
  -- SINGLE_PORT: port B (default generics) takes the shape of port A
  constant C_WB     : integer := sel(C_DUAL, width_b, width_a);
  constant C_AB     : integer := sel(C_DUAL, widthad_b, widthad_a);
  -- with byte enables a narrow word has byte columns (one write enable per column)
  constant C_BE     : boolean := width_byteena_a > 1 or (C_DUAL and width_byteena_b > 1);
  constant C_NARROW : integer := minimum(width_a, C_WB);
  constant C_COL    : integer := sel(C_BE, byte_size, C_NARROW);   -- column width
  constant C_COLS   : integer := C_NARROW / C_COL;                 -- columns per narrow word
  constant C_RATIO_A : integer := width_a / C_NARROW;          -- narrow words per port A word
  constant C_RATIO_B : integer := C_WB / C_NARROW;
  constant C_LOG_A  : integer := log2(C_RATIO_A);              -- narrow word index bits
  constant C_LOG_B  : integer := log2(C_RATIO_B);
  -- byte enables: Vivado infers no asymmetric byte-write RAM (Synth 8-2913), so one
  -- symmetric byte-write RAM of narrow words per narrow word of the wide port (bank; one
  -- bank for equal widths).  Without byte enables one RAM: the column loop of the
  -- byte-write template breaks the asymmetric template there (Synth 8-2913).
  constant C_BANKS  : integer := sel(C_RATIO_A > C_RATIO_B, C_RATIO_A, C_RATIO_B);
  constant C_BANKED : boolean := C_BE;
  constant C_LOG_K  : integer := log2(C_BANKS);                  -- bank select bits of the narrow port
  constant C_DEPTH  : integer := maximum(2 ** widthad_a * C_RATIO_A, 2 ** C_AB * C_RATIO_B);
  constant C_CE_A   : boolean := clock_enable_input_a = "NORMAL";
  constant C_CE_B   : boolean := clock_enable_input_b = "NORMAL";
  constant C_INIT   : boolean := init_file /= "UNUSED" and init_file /= "" and init_file /= " ";

  -- the memory in words of the narrower port (one array: inferred as one true dual port RAM)
  type ram_t is array (0 to C_DEPTH - 1) of std_logic_vector(C_NARROW - 1 downto 0);

  function is_mem(name : string) return boolean is
  begin
    return name'length > 4 and name(name'right - 3 to name'right) = ".mem";
  end function;

  -- contents of the init file, in port A words split into narrow words
  impure function read_init(name : string) return ram_t is
    file f     : text open read_mode is name;
    variable l : line;
    variable w : bit_vector(width_a - 1 downto 0);
    variable r : ram_t := (others => (others => '0'));
    variable a : integer := 0;
  begin
    while not endfile(f) and a < C_DEPTH / C_RATIO_A loop
      readline(f, l);
      read(l, w);
      for i in 0 to C_RATIO_A - 1 loop
        r(a * C_RATIO_A + i) := to_stdlogicvector(w((i + 1) * C_NARROW - 1 downto i * C_NARROW));
      end loop;
      a := a + 1;
    end loop;
    return r;
  end function;

  impure function init_ram return ram_t is
  begin
    if C_INIT and is_mem(init_file) then
      return read_init(init_file);
    end if;
    return (others => (others => '0'));
  end function;

  -- byte enable of narrow word i of a port (all '1' on a port without byte enables)
  function be_bit(be : std_logic_vector; i : integer) return std_logic is
  begin
    if be'length > 1 then return be(be'low + i); else return '1'; end if;
  end function;

  signal ok_a, ok_b : boolean;
  signal en_a, en_b : std_logic;

begin

  -- unsupported settings stop the synthesis
  assert operation_mode = "BIDIR_DUAL_PORT" or operation_mode = "SINGLE_PORT"
    report "altsyncram: operation_mode " & operation_mode & " not supported" severity failure;
  assert outdata_reg_a = "UNREGISTERED" and (not C_DUAL or outdata_reg_b = "UNREGISTERED")
    report "altsyncram: registered outputs not supported" severity failure;
  assert not C_DUAL or (address_reg_b = "CLOCK1" and indata_reg_b = "CLOCK1" and wrcontrol_wraddress_reg_b = "CLOCK1")
    report "altsyncram: port B must be registered on clock1" severity failure;
  assert width_a mod C_NARROW = 0 and C_WB mod C_NARROW = 0 and
         2 ** log2(C_RATIO_A) = C_RATIO_A and 2 ** log2(C_RATIO_B) = C_RATIO_B
    report "altsyncram: port widths must differ by a power of two" severity failure;
  assert not C_DUAL or 2 ** widthad_a * C_RATIO_A = 2 ** widthad_b * C_RATIO_B
    report "altsyncram: ports address different memory sizes" severity failure;
  assert numwords_a <= 2 ** widthad_a and (not C_DUAL or numwords_b <= 2 ** widthad_b)
    report "altsyncram: numwords larger than 2**widthad" severity failure;
  assert not C_BE or ((width_byteena_a = 1 or width_byteena_a * byte_size = width_a) and
                       (not C_DUAL or width_byteena_b = 1 or width_byteena_b * byte_size = C_WB) and
                       C_NARROW mod byte_size = 0)
    report "altsyncram: byte enables need one bit per byte_size bits of the port word" severity failure;
  assert not (C_INIT and C_BANKED)
    report "altsyncram: init_file with mixed widths and byte enables not supported" severity failure;
  assert not C_INIT or is_mem(init_file)
    report "altsyncram: init_file " & init_file & " is not a .mem file (prepare_sources.py converts .mif)"
    severity failure;
  assert (clock_enable_input_a = "BYPASS" or C_CE_A) and (clock_enable_input_b = "BYPASS" or C_CE_B) and
         clock_enable_output_a = "BYPASS" and (not C_DUAL or clock_enable_output_b = "BYPASS")
    report "altsyncram: clock enables other than input NORMAL/BYPASS not supported" severity failure;

  -- inactive-only inputs, checked in simulation
  ok_a <= aclr0 /= '1' and addressstall_a /= '1' and rden_a /= '0' and
          (width_byteena_a > 1 or byteena_a = (byteena_a'range => '1'));
  ok_b <= not C_DUAL or (aclr1 /= '1' and addressstall_b /= '1' and rden_b /= '0' and
                         (width_byteena_b > 1 or byteena_b = (byteena_b'range => '1')));

  eccstatus <= (others => '0');

  -- clock enables (inside the clock edge, as in the Vivado RAM templates)
  en_a <= clocken0 when C_CE_A else '1';
  en_b <= clocken1 when C_CE_B else '1';

  -- Write first: the narrow words of a port are written, then read (variable semantics),
  -- one loop iteration per narrow word, as in the Vivado template asym_ram_tdp_write_first
  -- (UG901).  The narrow word address is the port address & the index bits: with
  -- "address * ratio + i" Vivado finds no RAM for mixed widths (Synth 8-2913).
  g_one : if not C_BANKED generate
  shared variable ram : ram_t := init_ram;
  begin
  port_a : process (clock0)
  begin
    if rising_edge(clock0) then
      if en_a = '1' then
        assert ok_a report "altsyncram: unsupported control input active on port A" severity error;
      end if;
      for i in 0 to C_RATIO_A - 1 loop
        if en_a = '1' then
          if wren_a = '1' then
            ram(to_integer(unsigned(address_a) & to_unsigned(i, C_LOG_A))) :=
              data_a((i + 1) * C_NARROW - 1 downto i * C_NARROW);
          end if;
          q_a((i + 1) * C_NARROW - 1 downto i * C_NARROW) <=
            ram(to_integer(unsigned(address_a) & to_unsigned(i, C_LOG_A)));
        end if;
      end loop;
    end if;
  end process;

  g_b : if C_DUAL generate
    port_b : process (clock1)
    begin
      if rising_edge(clock1) then
        if en_b = '1' then
          assert ok_b report "altsyncram: unsupported control input active on port B" severity error;
        end if;
        for i in 0 to C_RATIO_B - 1 loop
          if en_b = '1' then
            if wren_b = '1' then
              ram(to_integer(unsigned(address_b) & to_unsigned(i, C_LOG_B))) :=
                data_b((i + 1) * C_NARROW - 1 downto i * C_NARROW);
            end if;
            q_b((i + 1) * C_NARROW - 1 downto i * C_NARROW) <=
              ram(to_integer(unsigned(address_b) & to_unsigned(i, C_LOG_B)));
          end if;
        end loop;
      end if;
    end process;
  end generate;

  g_no_b : if not C_DUAL generate
    q_b <= (others => '0');
  end generate;
  end generate;

  -- Byte enables: bank k holds the narrow words
  -- k, k + C_BANKS, ...; the wide port reaches narrow word k of its word in bank k, the
  -- narrow port one bank, selected by its low address bits, and reads through a mux by the
  -- registered bank number.  Each bank is the write-first byte-write template (UG901).
  g_banked : if C_BANKED generate
    type bank_q_t is array (0 to C_BANKS - 1) of std_logic_vector(C_NARROW - 1 downto 0);
    constant C_BA : integer := log2(C_DEPTH / C_BANKS);           -- bank address bits
    signal bq_a, bq_b   : bank_q_t;
    signal ba_a, ba_b   : std_logic_vector(C_BA - 1 downto 0);
    signal bs_a, bs_b   : integer range 0 to C_BANKS - 1;           -- bank of the narrow port
    signal sel_a, sel_b : integer range 0 to C_BANKS - 1 := 0;

    function low_bits(a : std_logic_vector; n : integer) return integer is
    begin
      if n = 0 or a'length < n then return 0; end if;
      return to_integer(unsigned(a(a'low + n - 1 downto a'low)));
    end function;
  begin
    -- bank address: the port address of the wide port, the high bits of the narrow one
    ba_a <= address_a(widthad_a - 1 downto widthad_a - C_BA);
    ba_b <= address_b(widthad_b - 1 downto widthad_b - C_BA);
    bs_a <= low_bits(address_a, C_LOG_K) when C_RATIO_A = 1 else 0;
    bs_b <= low_bits(address_b, C_LOG_K) when C_RATIO_B = 1 else 0;

    g_bank : for k in 0 to C_BANKS - 1 generate
      type bank_t is array (0 to 2 ** C_BA - 1) of std_logic_vector(C_NARROW - 1 downto 0);
      -- narrow word of a wide port word in this bank (0 for the narrow port)
      constant IA : integer := sel(C_RATIO_A > 1, k, 0);
      constant IB : integer := sel(C_RATIO_B > 1, k, 0);

      shared variable bank : bank_t := (others => (others => '0'));
    begin
      bank_a : process (clock0)
      begin
        if rising_edge(clock0) then
          if en_a = '1' then
            for j in 0 to C_COLS - 1 loop
              if wren_a = '1' and (C_RATIO_A > 1 or bs_a = k) and be_bit(byteena_a, IA * C_COLS + j) = '1' then
                bank(to_integer(unsigned(ba_a)))((j + 1) * C_COL - 1 downto j * C_COL) :=
                  data_a(IA * C_NARROW + (j + 1) * C_COL - 1 downto IA * C_NARROW + j * C_COL);
              end if;
            end loop;
            bq_a(k) <= bank(to_integer(unsigned(ba_a)));
          end if;
        end if;
      end process;

      bank_b : process (clock1)
      begin
        if rising_edge(clock1) then
          if en_b = '1' then
            for j in 0 to C_COLS - 1 loop
              if wren_b = '1' and (C_RATIO_B > 1 or bs_b = k) and be_bit(byteena_b, IB * C_COLS + j) = '1' then
                bank(to_integer(unsigned(ba_b)))((j + 1) * C_COL - 1 downto j * C_COL) :=
                  data_b(IB * C_NARROW + (j + 1) * C_COL - 1 downto IB * C_NARROW + j * C_COL);
              end if;
            end loop;
            bq_b(k) <= bank(to_integer(unsigned(ba_b)));
          end if;
        end if;
      end process;

      g_wide_a : if C_RATIO_A > 1 generate
        q_a((k + 1) * C_NARROW - 1 downto k * C_NARROW) <= bq_a(k);
      end generate;
      g_wide_b : if C_RATIO_B > 1 generate
        q_b((k + 1) * C_NARROW - 1 downto k * C_NARROW) <= bq_b(k);
      end generate;
    end generate;

    process (clock0)
    begin
      if rising_edge(clock0) then
        if en_a = '1' then
          assert ok_a report "altsyncram: unsupported control input active on port A" severity error;
          sel_a <= bs_a;
        end if;
      end if;
    end process;

    process (clock1)
    begin
      if rising_edge(clock1) then
        if en_b = '1' then
          assert ok_b report "altsyncram: unsupported control input active on port B" severity error;
          sel_b <= bs_b;
        end if;
      end if;
    end process;

    g_narrow_a : if C_RATIO_A = 1 generate
      q_a <= bq_a(sel_a);
    end generate;
    g_narrow_b : if C_RATIO_B = 1 generate
      q_b <= bq_b(sel_b);
    end generate;
  end generate;

end architecture rtl;
