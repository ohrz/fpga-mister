-------------------------------------------------------------------------------
-- Title      : N64 core profile: memory address adder with forwarding after the add
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : cpu_addr_fwd.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-31
-------------------------------------------------------------------------------
-- Description:
--   calcMemAddr of rtl/cpu.vhd (N64_MiSTer, stage 3) is
--     value1 + sign_extend(decodeImmData)
--   where value1 is the operand forwarding mux
--     resultData    when executeForwardValue1 = '1' and resultWriteEnable = '1'
--     writebackData when writebackForwardValue1 = '1'
--     decodeValue1  otherwise.
--   On the xc7z020 at 93.75 MHz the select (resultWriteEnable, fan-out ~90)
--   sits in front of the 64-bit carry chain and starts the CPU's worst paths
--   (address -> TLB, COP0 BadVAddr/EntryHi, cache tag, stall).
--   Here each source gets its own adder and the forwarding select picks the
--   sum: x + c selected by s equals the selected x plus c, so sum is the
--   same value in every cycle; only the select moves behind the adders.  The
--   three sums carry KEEP so that synthesis does not share them back into one
--   adder behind the mux (resource sharing).  Patch
--   cores/n64/patches/0001-cpu-memory-address-forwarding-after-the-adder.patch
--   wires it in.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity n64_cpu_addr_fwd is
  port (
    resultData             : in  unsigned(63 downto 0);
    writebackData          : in  unsigned(63 downto 0);
    decodeValue1           : in  unsigned(63 downto 0);
    decodeImmData          : in  unsigned(15 downto 0);
    executeForwardValue1   : in  std_logic;
    resultWriteEnable      : in  std_logic;
    writebackForwardValue1 : in  std_logic;
    calcMemAddr            : out unsigned(63 downto 0)
  );
end entity n64_cpu_addr_fwd;

architecture rtl of n64_cpu_addr_fwd is

  signal imm                  : unsigned(63 downto 0);
  signal sum_res, sum_wb, sum_dec : unsigned(63 downto 0);
  attribute KEEP : string;
  attribute KEEP of sum_res, sum_wb, sum_dec : signal is "TRUE";

begin

  imm     <= unsigned(resize(signed(decodeImmData), 64));
  sum_res <= resultData + imm;
  sum_wb  <= writebackData + imm;
  sum_dec <= decodeValue1 + imm;

  calcMemAddr <= sum_res when (executeForwardValue1 = '1' and resultWriteEnable = '1') else
                 sum_wb  when (writebackForwardValue1 = '1') else
                 sum_dec;

end architecture rtl;
