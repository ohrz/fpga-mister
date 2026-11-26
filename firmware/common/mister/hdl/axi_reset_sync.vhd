-------------------------------------------------------------------------------
-- Title      : AXI reset on a clock that starts late
-- Project    : fpga-mister
-------------------------------------------------------------------------------
-- File       : axi_reset_sync.vhd
-- Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
-- Company    : OHRZ
-- Created    : 2026-11-07
-------------------------------------------------------------------------------
-- Description:
--   Reset of AXI logic on a core clock (DDRAM_CLK, the memory clock of a
--   stage D core): the bridge in mister_zynq and the SmartConnect between it
--   and the HP port.  The PL reset (rst_in, from the 100 MHz domain) ends
--   long before the core's MMCM locks and its clock runs; a SmartConnect
--   needs its aresetn low for at least 16 cycles of a running aclk (PG247);
--   the HP3 path lost read responses and address beats at the start of the
--   PSX core while its SmartConnect had the PL reset.
--     rst_in   asynchronous, active high; two synchronizer stages on clk
--     aresetn  '0' from configuration and while rst_in, then '1' after
--              G_CYCLES further cycles of clk (so at least G_CYCLES running
--              cycles of clk with reset, whenever clk starts)
--     rst      not aresetn (for logic that wants active high)
-------------------------------------------------------------------------------
-- Copyright (c) 2026 by OHRZ
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity axi_reset_sync is
  generic (
    G_CYCLES : positive := 32                   -- running cycles of clk with reset
  );
  port (
    clk     : in  std_logic;
    rst_in  : in  std_logic;                    -- asynchronous, active high
    aresetn : out std_logic;
    rst     : out std_logic
  );
end entity axi_reset_sync;

architecture rtl of axi_reset_sync is

  signal rst_s : std_logic_vector(1 downto 0) := "11";
  signal cnt   : natural range 0 to G_CYCLES := 0;
  signal arn   : std_logic := '0';

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of rst_s : signal is "TRUE";

begin

  process (clk)
  begin
    if rising_edge(clk) then
      rst_s <= rst_s(0) & rst_in;
      if rst_s(1) = '1' then
        cnt <= 0;
        arn <= '0';
      elsif cnt = G_CYCLES then
        arn <= '1';
      else
        cnt <= cnt + 1;
      end if;
    end if;
  end process;

  aresetn <= arn;
  rst     <= not arn;

end architecture rtl;
