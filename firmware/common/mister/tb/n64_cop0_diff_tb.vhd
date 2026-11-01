-------------------------------------------------------------------------------
-- Title      : Original against patched N64 COP0 (exception address one cycle later)
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : n64_cop0_diff_tb.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-31
-------------------------------------------------------------------------------
-- Description:
--   rtl/cpu_cop0.vhd of the checkout (cpu_cop0_orig) against the copy with
--   cores/n64/patches applied (cpu_cop0_new), side by side with the same
--   random stimulus; every output, including all 32 exported COP0 registers
--   (cop0_export, simulation only), is compared after every clock edge and
--   in the middle of the cycle (readValue is combinational on regIndex).
--   The stimulus does not follow the pipeline rules of cpu.vhd: exception3
--   with the address error codes 4/5, TLB data/instruction requests on a
--   few pages (misses raise TLB exceptions), MTC0 to every register, TLBR,
--   TLBWI, TLBWR, TLBP, eret, interrupts and ce = '0' cycles come in any
--   combination, so the patched COP0 must give the same outputs for any
--   input sequence.  Counts exception address writes (BadVAddr changes),
--   TLBR in the same cycle as exception3, MTC0 to EntryHi right after one,
--   TLBP and ce = '0' right after one.  Ends with "PASS" or a failure.
--   VHDL-2008 (ghdl --std=08).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.pexport.all;

entity n64_cop0_diff_tb is
end entity;

architecture tb of n64_cop0_diff_tb is

  -- inputs (shared)
  type ins_t is record
    ce, executeNew, reset, preNMI, irqRequest, irqCartRequest, decode_irq, eret     : std_logic;
    exception3, exceptionNewPC, exceptionFPU, isDelaySlot, nextDelaySlot          : std_logic;
    writeEnable, executeSetLL, executeLLfromTLB, writeDatacacheTagEna              : std_logic;
    TLBR, TLBWI, TLBWR, TLBP, TLB_instrReq, TLB_ss_load, TLB_dataReq, TLB_dataIsWrite : std_logic;
    DISABLE_DTLBMINI                                                               : std_logic;
    stall, stall4Masked                                                            : unsigned(4 downto 0);
    RANDOMMISS, exceptionCode_1, exceptionCode_3                                   : unsigned(3 downto 0);
    exception_COP                                                                  : unsigned(1 downto 0);
    regIndex                                                                       : unsigned(4 downto 0);
    exceptionPCStore, pcOld1, writeValue, TLB_instrAddrIn, TLB_dataAddrIn          : unsigned(63 downto 0);
    executeLLAddr                                                                  : unsigned(31 downto 0);
    writeDatacacheTagValue                                                         : unsigned(21 downto 0);
  end record;
  signal i : ins_t := (stall => "00000", stall4Masked => "00000", RANDOMMISS => x"0", exceptionCode_1 => x"0",
                       exceptionCode_3 => x"0", exception_COP => "00", regIndex => "00000",
                       exceptionPCStore => (others => '0'), pcOld1 => (others => '0'), writeValue => (others => '0'),
                       TLB_instrAddrIn => (others => '0'), TLB_dataAddrIn => (others => '0'),
                       executeLLAddr => (others => '0'), writeDatacacheTagValue => (others => '0'),
                       others => '0');

  type outs_t is record
    error_exception, error_TLB, irqTrigger, exception, exceptionStage1             : std_logic;
    COP1_enable, COP2_enable, fpuRegMode, bit64region, TagLo_Valid, TagLo_Dirty    : std_logic;
    TLBDone, TLB_instrUseCache, TLB_instrStall, TLB_instrUnStall                   : std_logic;
    TLB_dataUseCacheFound, TLB_dataUseCacheLookup, TLB_dataStall, TLB_dataUnStall  : std_logic;
    privilegeMode                                                                  : unsigned(1 downto 0);
    eretPC, exceptionPC, readValue                                                 : unsigned(63 downto 0);
    TagLo_Addr                                                                     : unsigned(19 downto 0);
    TLB_instrAddrOutFound, TLB_instrAddrOutLookup                                  : unsigned(31 downto 0);
    TLB_dataAddrOutFound, TLB_dataAddrOutLookup                                    : unsigned(31 downto 0);
    regs                                                                           : tExportRegs;
  end record;
  signal o_orig, o_new : outs_t;

  signal clk  : std_logic := '0';
  signal done : boolean := false;

begin

  clk <= not clk after 5 ns when not done;

  u_orig : entity work.cpu_cop0_orig
    port map (
      clk93 => clk, ce => i.ce, stall => i.stall, stall4Masked => i.stall4Masked, executeNew => i.executeNew,
      reset => i.reset, preNMI => i.preNMI, RANDOMMISS => i.RANDOMMISS, DISABLE_BOOTCOUNT => '0',
      DISABLE_DTLBMINI => i.DISABLE_DTLBMINI, error_exception => o_orig.error_exception,
      error_TLB => o_orig.error_TLB, irqRequest => i.irqRequest, irqCartRequest => i.irqCartRequest,
      irqTrigger => o_orig.irqTrigger, decode_irq => i.decode_irq, cop0_export => o_orig.regs,
      eret => i.eret, exception3 => i.exception3, exceptionNewPC => i.exceptionNewPC,
      exceptionPCStore => i.exceptionPCStore, exceptionFPU => i.exceptionFPU,
      exceptionCode_1 => i.exceptionCode_1, exceptionCode_3 => i.exceptionCode_3,
      exception_COP => i.exception_COP, isDelaySlot => i.isDelaySlot, nextDelaySlot => i.nextDelaySlot,
      pcOld1 => i.pcOld1, eretPC => o_orig.eretPC, exceptionPC => o_orig.exceptionPC,
      exception => o_orig.exception, exceptionStage1 => o_orig.exceptionStage1,
      COP1_enable => o_orig.COP1_enable, COP2_enable => o_orig.COP2_enable, fpuRegMode => o_orig.fpuRegMode,
      privilegeMode => o_orig.privilegeMode, bit64region => o_orig.bit64region,
      writeEnable => i.writeEnable, regIndex => i.regIndex, writeValue => i.writeValue,
      readValue => o_orig.readValue, executeSetLL => i.executeSetLL, executeLLfromTLB => i.executeLLfromTLB,
      executeLLAddr => i.executeLLAddr, TagLo_Valid => o_orig.TagLo_Valid, TagLo_Dirty => o_orig.TagLo_Dirty,
      TagLo_Addr => o_orig.TagLo_Addr, writeDatacacheTagEna => i.writeDatacacheTagEna,
      writeDatacacheTagValue => i.writeDatacacheTagValue, TLBR => i.TLBR, TLBWI => i.TLBWI, TLBWR => i.TLBWR,
      TLBP => i.TLBP, TLBDone => o_orig.TLBDone, TLB_instrReq => i.TLB_instrReq, TLB_ss_load => i.TLB_ss_load,
      TLB_instrAddrIn => i.TLB_instrAddrIn, TLB_instrUseCache => o_orig.TLB_instrUseCache,
      TLB_instrStall => o_orig.TLB_instrStall, TLB_instrUnStall => o_orig.TLB_instrUnStall,
      TLB_instrAddrOutFound => o_orig.TLB_instrAddrOutFound, TLB_instrAddrOutLookup => o_orig.TLB_instrAddrOutLookup,
      TLB_dataReq => i.TLB_dataReq, TLB_dataIsWrite => i.TLB_dataIsWrite, TLB_dataAddrIn => i.TLB_dataAddrIn,
      TLB_dataUseCacheFound => o_orig.TLB_dataUseCacheFound, TLB_dataUseCacheLookup => o_orig.TLB_dataUseCacheLookup,
      TLB_dataStall => o_orig.TLB_dataStall, TLB_dataUnStall => o_orig.TLB_dataUnStall,
      TLB_dataAddrOutFound => o_orig.TLB_dataAddrOutFound, TLB_dataAddrOutLookup => o_orig.TLB_dataAddrOutLookup,
      SS_reset => '0', loading_savestate => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren_CPU => '0', SS_rden_CPU => '0');

  u_new : entity work.cpu_cop0_new
    port map (
      clk93 => clk, ce => i.ce, stall => i.stall, stall4Masked => i.stall4Masked, executeNew => i.executeNew,
      reset => i.reset, preNMI => i.preNMI, RANDOMMISS => i.RANDOMMISS, DISABLE_BOOTCOUNT => '0',
      DISABLE_DTLBMINI => i.DISABLE_DTLBMINI, error_exception => o_new.error_exception,
      error_TLB => o_new.error_TLB, irqRequest => i.irqRequest, irqCartRequest => i.irqCartRequest,
      irqTrigger => o_new.irqTrigger, decode_irq => i.decode_irq, cop0_export => o_new.regs,
      eret => i.eret, exception3 => i.exception3, exceptionNewPC => i.exceptionNewPC,
      exceptionPCStore => i.exceptionPCStore, exceptionFPU => i.exceptionFPU,
      exceptionCode_1 => i.exceptionCode_1, exceptionCode_3 => i.exceptionCode_3,
      exception_COP => i.exception_COP, isDelaySlot => i.isDelaySlot, nextDelaySlot => i.nextDelaySlot,
      pcOld1 => i.pcOld1, eretPC => o_new.eretPC, exceptionPC => o_new.exceptionPC,
      exception => o_new.exception, exceptionStage1 => o_new.exceptionStage1,
      COP1_enable => o_new.COP1_enable, COP2_enable => o_new.COP2_enable, fpuRegMode => o_new.fpuRegMode,
      privilegeMode => o_new.privilegeMode, bit64region => o_new.bit64region,
      writeEnable => i.writeEnable, regIndex => i.regIndex, writeValue => i.writeValue,
      readValue => o_new.readValue, executeSetLL => i.executeSetLL, executeLLfromTLB => i.executeLLfromTLB,
      executeLLAddr => i.executeLLAddr, TagLo_Valid => o_new.TagLo_Valid, TagLo_Dirty => o_new.TagLo_Dirty,
      TagLo_Addr => o_new.TagLo_Addr, writeDatacacheTagEna => i.writeDatacacheTagEna,
      writeDatacacheTagValue => i.writeDatacacheTagValue, TLBR => i.TLBR, TLBWI => i.TLBWI, TLBWR => i.TLBWR,
      TLBP => i.TLBP, TLBDone => o_new.TLBDone, TLB_instrReq => i.TLB_instrReq, TLB_ss_load => i.TLB_ss_load,
      TLB_instrAddrIn => i.TLB_instrAddrIn, TLB_instrUseCache => o_new.TLB_instrUseCache,
      TLB_instrStall => o_new.TLB_instrStall, TLB_instrUnStall => o_new.TLB_instrUnStall,
      TLB_instrAddrOutFound => o_new.TLB_instrAddrOutFound, TLB_instrAddrOutLookup => o_new.TLB_instrAddrOutLookup,
      TLB_dataReq => i.TLB_dataReq, TLB_dataIsWrite => i.TLB_dataIsWrite, TLB_dataAddrIn => i.TLB_dataAddrIn,
      TLB_dataUseCacheFound => o_new.TLB_dataUseCacheFound, TLB_dataUseCacheLookup => o_new.TLB_dataUseCacheLookup,
      TLB_dataStall => o_new.TLB_dataStall, TLB_dataUnStall => o_new.TLB_dataUnStall,
      TLB_dataAddrOutFound => o_new.TLB_dataAddrOutFound, TLB_dataAddrOutLookup => o_new.TLB_dataAddrOutLookup,
      SS_reset => '0', loading_savestate => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren_CPU => '0', SS_rden_CPU => '0');

  process
    variable s1, s2 : positive := 31;
    variable v      : ins_t;
    variable n_bad, n_tlbr, n_mtc0, n_tlbp, n_ce0, n_tlbexc : natural := 0;
    variable bad_prev  : boolean := false;
    variable bva_prev  : unsigned(63 downto 0) := (others => '0');
    type page_t is array (0 to 3) of unsigned(63 downto 0);
    constant C_PAGE : page_t := (x"0000000000400000", x"FFFFFFFF80000000", x"0000000000002000", x"C000000000004000");

    impure function rnd(k : positive) return natural is
      variable r : real;
    begin
      uniform(s1, s2, r);
      return integer(trunc(r * real(k))) mod k;
    end function;
    impure function bit(k : positive) return std_logic is   -- '1' with probability 1/k
    begin
      if rnd(k) = 0 then return '1'; else return '0'; end if;
    end function;
    impure function rnd64 return unsigned is
      variable x : unsigned(63 downto 0);
    begin
      for b in 0 to 3 loop x(16 * b + 15 downto 16 * b) := to_unsigned(rnd(65536), 16); end loop;
      return x;
    end function;
    impure function addr return unsigned is
    begin
      return C_PAGE(rnd(4)) + to_unsigned(rnd(8192), 64);
    end function;

    procedure compare(tag : string; cyc : natural) is
    begin
      for r in 0 to 31 loop
        assert o_new.regs(r) = o_orig.regs(r)
          report tag & " cycle " & integer'image(cyc) & ": COP0 register " & integer'image(r) & " "
                 & to_hstring(o_new.regs(r)) & " /= " & to_hstring(o_orig.regs(r)) severity failure;
      end loop;
      assert o_new = o_orig report tag & " cycle " & integer'image(cyc) & ": outputs differ" severity failure;
    end procedure;
  begin
    v := i;
    v.reset := '1'; v.ce := '1';
    i <= v;
    wait until rising_edge(clk); wait until rising_edge(clk);
    for cyc in 1 to 200000 loop
      v.reset            := '1' when cyc = 100000 else '0';
      v.ce               := not bit(10);
      v.executeNew       := not bit(4);
      v.stall            := "00000" when rnd(4) /= 0 else to_unsigned(rnd(32), 5);
      v.stall4Masked     := "00000" when rnd(4) /= 0 else to_unsigned(rnd(32), 5);
      v.RANDOMMISS       := to_unsigned(rnd(16), 4);
      v.DISABLE_DTLBMINI := bit(8);
      v.irqRequest       := bit(50);
      v.irqCartRequest   := bit(80);
      v.decode_irq       := bit(60);
      v.eret             := bit(30);
      v.exception3       := bit(6);
      v.exceptionCode_3  := to_unsigned(4 + rnd(2), 4) when rnd(3) /= 0 else to_unsigned(rnd(16), 4);
      v.exceptionCode_1  := to_unsigned(rnd(16), 4);
      v.exception_COP    := to_unsigned(rnd(4), 2);
      v.exceptionNewPC   := bit(3);
      v.exceptionFPU     := bit(80);
      v.exceptionPCStore := addr;
      v.isDelaySlot      := bit(4);
      v.nextDelaySlot    := bit(4);
      v.pcOld1           := addr;
      v.writeEnable      := bit(4);
      v.regIndex         := to_unsigned(rnd(32), 5) when rnd(2) = 0 else
                            to_unsigned(4, 5) when rnd(4) = 0 else to_unsigned(8, 5) when rnd(3) = 0 else
                            to_unsigned(10, 5) when rnd(2) = 0 else to_unsigned(20, 5);
      v.writeValue       := rnd64 when rnd(2) = 0 else addr;
      v.executeSetLL     := bit(40);
      v.executeLLfromTLB := bit(2);
      v.executeLLAddr    := to_unsigned(rnd(65536), 32);
      v.writeDatacacheTagEna   := bit(40);
      v.writeDatacacheTagValue := to_unsigned(rnd(65536), 22);
      v.TLBR             := bit(12);
      v.TLBWI            := bit(25);
      v.TLBWR            := bit(25);
      v.TLBP             := bit(25);
      v.TLB_instrReq     := bit(3);
      v.TLB_ss_load      := bit(50);
      v.TLB_instrAddrIn  := addr;
      v.TLB_dataReq      := bit(3);
      v.TLB_dataIsWrite  := bit(2);
      v.TLB_dataAddrIn   := addr;
      v.preNMI           := '0';
      i <= v;
      wait for 1 ns;
      compare("mid", cyc);
      -- coverage of the cases the patch has to keep equal
      if bad_prev and v.ce = '0' then n_ce0 := n_ce0 + 1; end if;
      if bad_prev and v.writeEnable = '1' and v.regIndex = 10 then n_mtc0 := n_mtc0 + 1; end if;
      if bad_prev and v.TLBP = '1' then n_tlbp := n_tlbp + 1; end if;
      if v.TLBR = '1' and v.exception3 = '1' and (v.exceptionCode_3 = 4 or v.exceptionCode_3 = 5)
         and v.ce = '1' and v.executeNew = '1' and v.stall4Masked = 0 and o_orig.exception = '0' then
        n_tlbr := n_tlbr + 1;
      end if;
      wait until rising_edge(clk);
      wait for 1 ns;
      compare("edge", cyc);
      bad_prev := o_orig.regs(8) /= bva_prev;
      if bad_prev then n_bad := n_bad + 1; end if;
      bva_prev := o_orig.regs(8);
    end loop;
    report "BadVAddr writes " & integer'image(n_bad) & ", TLBR with exception3 " & integer'image(n_tlbr)
           & ", MTC0 EntryHi after " & integer'image(n_mtc0) & ", TLBP after " & integer'image(n_tlbp)
           & ", ce=0 after " & integer'image(n_ce0);
    assert n_bad > 1000 and n_tlbr > 100 and n_mtc0 > 100 and n_tlbp > 100 and n_ce0 > 100
      report "too few cases" severity failure;
    report "PASS";
    done <= true;
    wait;
  end process;

end architecture tb;
