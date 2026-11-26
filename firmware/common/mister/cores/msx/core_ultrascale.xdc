#-----------------------------------------------------------------------------
# Title      : MSX core profile: clock placement rules of UltraScale(+) devices
# Project    : fpga-mister
#-----------------------------------------------------------------------------
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-11-07
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
# Description:
#   core_xdc_ultrascale of core.tcl: mister_project.tcl adds it only on an
#   UltraScale(+) part, for the implementation.  7 series needs none of it.
#   The core clocks are BUFGCEs cascaded behind core_buf (BUFGCE of the gated
#   master clock in mister_zynq), see cores/msx/pll.vhd.  opt_design on
#   UltraScale+ turns such a cascade into parallel BUFGCEs on the MMCM output
#   (CE of both ANDed): core_buf/O, the -source of the generated clocks in
#   cores/msx/core.xdc, then no longer leads to them, the clocks lose their
#   source latency (TIMING-36) and the hold checks between them and the
#   master clock are wrong (ZCU106 MSX 2026-11-07: hold -4.9 ns).
#   DONT_TOUCH keeps the cascade as on the Zybo.
#-----------------------------------------------------------------------------

set_property DONT_TOUCH true [get_cells -hier -filter {NAME =~ */emu/pll/sys_buf && REF_NAME =~ BUFGCE*}]
