-------------------------------------------------------------------------------
-- Title      : MSX core profile: hide the ROM in the ESE-SCC of slot 1 after a mount
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : scc_rom_hide.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-10-29
-------------------------------------------------------------------------------
-- Description:
--   ROMLOAD /R loads a game into the RAM of the ESE-SCC (OSD Slot1 =
--   MegaSCC+ 1MB) and resets; the BIOS then finds the ROM header "AB" in
--   slot 1 and starts the game like a cartridge.  That RAM keeps its content
--   over every reset, so after the OSD mounts another card (Reset after Mount)
--   the BIOS starts the old game again before MSX-DOS boots the new card.
--   This block makes the slot look empty to the BIOS from a mount until
--   ROMLOAD writes the cartridge again (patch 0001 of MSX_MiSTer wires it):
--     mount  one clock with img_mounted: hide on, not yet armed
--     reset  the MSX reset after the mount arms the release
--     armed  the first memory write to page 1 (4000-7FFFh) of slot 1 ends
--            hiding: ROMLOAD sets the SCC bank registers (5000h, 7000h)
--            while it loads.  The BIOS only reads slot 1 page 1 (its RAM
--            search writes pages 2 and 3), so it cannot end hiding early.
--   While hidden, reads of the header bytes 4000h/4001h and 8000h/8001h
--   return FFh (mask = 1): the BIOS sees no ROM, the rest of the slot (SCC
--   registers, RAM) stays as it is, so ROMLOAD still finds the ESE-SCC.
--   Without Reset after Mount the release is armed by the next reset; the
--   game keeps running until then (it does not read its own header).
--   req / wrt / adr are the slot bus of emsx_top as megaram.vhd sees it
--   (req = Scc1Req, wrt = 1 for a write).
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity scc_rom_hide is
  port (
    clk   : in  std_logic;
    mount : in  std_logic;                        -- a card was mounted (one clock)
    reset : in  std_logic;                        -- MSX reset (emsx_top reset)
    req   : in  std_logic;                        -- slot 1 ESE-SCC access
    wrt   : in  std_logic;                        -- 1 = write
    adr   : in  std_logic_vector(15 downto 0);    -- CPU address
    mask  : out std_logic                         -- 1: read data of slot 1 = FFh
  );
end entity scc_rom_hide;

architecture rtl of scc_rom_hide is
  signal hide  : std_logic := '0';
  signal armed : std_logic := '0';
begin

  process (clk)
  begin
    if rising_edge(clk) then
      if mount = '1' then
        hide  <= '1';
        armed <= '0';
      elsif reset = '1' then
        armed <= hide;
      elsif armed = '1' and req = '1' and wrt = '1' and adr(15 downto 14) = "01" then
        hide  <= '0';
        armed <= '0';
      end if;
    end if;
  end process;

  -- header bytes of page 1 and page 2: 4000h/4001h, 8000h/8001h
  mask <= '1' when hide = '1' and (adr(15 downto 1) = "010000000000000" or
                                   adr(15 downto 1) = "100000000000000") else '0';

end architecture rtl;
