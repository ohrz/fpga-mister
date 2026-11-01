-------------------------------------------------------------------------------
-- Title      : Replacement of the Intel megafunction altddio_out for Vivado
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : altddio_out.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-28
-------------------------------------------------------------------------------
-- Description:
--   Same name, generics and ports as the Intel altddio_out (DDR output
--   register).  MiSTer cores use it to forward the SDRAM clock (SDRAM_CLK,
--   datain_h = 0, datain_l = 1: the inverted clock).  With the SDRAM pin
--   emulator SDRAM_CLK goes nowhere and this logic is removed; the function is
--   still that of the original, for other uses:
--     datain_h and datain_l are both taken on the rising edge of outclock;
--     dataout shows the datain_h value while outclock is high and the datain_l
--     value while it is low (Xilinx ODDR SAME_EDGE; behavioural, LUT based).
--     For an output that reaches a pin, the top level instantiates an ODDR.
--   aclr/aset, sclr/sset, outclocken as on Intel; oe = 0 gives 'Z' (a
--   tristate at a pin, logic inside the FPGA).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity altddio_out is
  generic (
    width                  : integer := 1;
    power_up_high          : string  := "OFF";
    oe_reg                 : string  := "UNREGISTERED";
    extend_oe_disable      : string  := "OFF";
    invert_output          : string  := "OFF";
    intended_device_family : string  := "Cyclone V";
    lpm_type               : string  := "altddio_out";
    lpm_hint               : string  := "UNUSED"
  );
  port (
    datain_h   : in  std_logic_vector(width - 1 downto 0);
    datain_l   : in  std_logic_vector(width - 1 downto 0);
    outclock   : in  std_logic;
    outclocken : in  std_logic := '1';
    aclr       : in  std_logic := '0';
    aset       : in  std_logic := '0';
    sclr       : in  std_logic := '0';
    sset       : in  std_logic := '0';
    oe         : in  std_logic := '1';
    oe_out     : out std_logic_vector(width - 1 downto 0);
    dataout    : out std_logic_vector(width - 1 downto 0)
  );
end entity altddio_out;

architecture rtl of altddio_out is

  function init return std_logic_vector is
  begin
    if power_up_high = "ON" then return (width - 1 downto 0 => '1'); end if;
    return (width - 1 downto 0 => '0');
  end function;

  signal reg_h : std_logic_vector(width - 1 downto 0) := init;
  signal reg_l : std_logic_vector(width - 1 downto 0) := init;
  signal d     : std_logic_vector(width - 1 downto 0);

begin

  process (outclock, aclr, aset)
  begin
    if aclr = '1' then
      reg_h <= (others => '0');
      reg_l <= (others => '0');
    elsif aset = '1' then
      reg_h <= (others => '1');
      reg_l <= (others => '1');
    elsif rising_edge(outclock) then
      if outclocken = '1' then
        if sclr = '1' then
          reg_h <= (others => '0');
          reg_l <= (others => '0');
        elsif sset = '1' then
          reg_h <= (others => '1');
          reg_l <= (others => '1');
        else
          reg_h <= datain_h;
          reg_l <= datain_l;
        end if;
      end if;
    end if;
  end process;

  d <= reg_h when outclock = '1' else reg_l;

  process (d, oe)
  begin
    if oe = '0' then
      dataout <= (others => 'Z');
    elsif invert_output = "ON" then
      dataout <= not d;
    else
      dataout <= d;
    end if;
  end process;

  oe_out <= (others => oe);

end architecture rtl;
