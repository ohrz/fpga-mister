-------------------------------------------------------------------------------
-- Title      : Replacement of the Intel megafunction altdpram for Vivado
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : altdpram.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-30
-------------------------------------------------------------------------------
-- Description:
--   Same name, generics and ports as the Intel altdpram, so MiSTer sources that
--   instantiate it (SNES rtl/mlab.vhd, rtl/chip/CX4/cx4cache.vhd) stay
--   unchanged.  The subset these sources use (MLAB as simple dual port RAM) is
--   implemented; any other setting stops the synthesis with an assertion:
--     write port       data, wraddress and wren registered on inclock
--                      (indata_reg, wraddress_reg, wrcontrol_reg INCLOCK)
--     read port        rdaddress and q unregistered (rdaddress_reg,
--                      rdcontrol_reg, outdata_reg UNREGISTERED): q follows
--                      rdaddress and the memory without a clock; outclock is
--                      not used
--   Read during write at the same address: the old word until the write
--   clock edge, then the new one (CONSTRAINED_DONT_CARE allows that).
--   Not supported: byte enables, address stalls, aclr, clock enables (the
--   inputs exist and must be inactive), init files.  Inferred as distributed
--   (LUT) RAM.
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity altdpram is
  generic (
    width                              : integer := 8;
    widthad                            : integer := 8;
    numwords                           : integer := 0;
    width_byteena                      : integer := 1;
    indata_aclr                        : string  := "OFF";
    indata_reg                         : string  := "INCLOCK";
    outdata_aclr                       : string  := "OFF";
    outdata_reg                        : string  := "UNREGISTERED";
    rdaddress_aclr                     : string  := "OFF";
    rdaddress_reg                      : string  := "UNREGISTERED";
    rdcontrol_aclr                     : string  := "OFF";
    rdcontrol_reg                      : string  := "UNREGISTERED";
    wraddress_aclr                     : string  := "OFF";
    wraddress_reg                      : string  := "INCLOCK";
    wrcontrol_aclr                     : string  := "OFF";
    wrcontrol_reg                      : string  := "INCLOCK";
    read_during_write_mode_mixed_ports : string  := "CONSTRAINED_DONT_CARE";
    ram_block_type                     : string  := "AUTO";
    use_eab                            : string  := "ON";
    lpm_file                           : string  := "UNUSED";
    intended_device_family             : string  := "Cyclone V";
    lpm_type                           : string  := "altdpram";
    lpm_hint                           : string  := "UNUSED"
  );
  port (
    data           : in  std_logic_vector(width - 1 downto 0);
    inclock        : in  std_logic := '1';
    outclock       : in  std_logic := '1';
    rdaddress      : in  std_logic_vector(widthad - 1 downto 0);
    wraddress      : in  std_logic_vector(widthad - 1 downto 0);
    wren           : in  std_logic := '0';
    rden           : in  std_logic := '1';
    q              : out std_logic_vector(width - 1 downto 0);
    aclr           : in  std_logic := '0';
    byteena        : in  std_logic_vector(width_byteena - 1 downto 0) := (others => '1');
    inclocken      : in  std_logic := '1';
    outclocken     : in  std_logic := '1';
    rdaddressstall : in  std_logic := '0';
    wraddressstall : in  std_logic := '0'
  );
end entity altdpram;

architecture rtl of altdpram is

  type ram_t is array (0 to 2 ** widthad - 1) of std_logic_vector(width - 1 downto 0);
  signal ram : ram_t := (others => (others => '0'));

  signal ok : boolean;

begin

  -- unsupported settings stop the synthesis
  assert indata_reg = "INCLOCK" and wraddress_reg = "INCLOCK" and wrcontrol_reg = "INCLOCK"
    report "altdpram: write port must be registered on inclock" severity failure;
  assert rdaddress_reg = "UNREGISTERED" and rdcontrol_reg = "UNREGISTERED" and outdata_reg = "UNREGISTERED"
    report "altdpram: registered read port not supported" severity failure;
  assert numwords <= 2 ** widthad
    report "altdpram: numwords larger than 2**widthad" severity failure;
  assert lpm_file = "UNUSED" or lpm_file = ""
    report "altdpram: lpm_file not supported" severity failure;

  -- inactive-only inputs, checked in simulation
  ok <= aclr /= '1' and inclocken /= '0' and outclocken /= '0' and rden /= '0' and rdaddressstall /= '1' and
        wraddressstall /= '1' and byteena = (byteena'range => '1');

  process (inclock)
  begin
    if rising_edge(inclock) then
      assert ok report "altdpram: unsupported control input active" severity error;
      if wren = '1' then
        ram(to_integer(unsigned(wraddress))) <= data;
      end if;
    end if;
  end process;

  q <= ram(to_integer(unsigned(rdaddress)));

end architecture rtl;
