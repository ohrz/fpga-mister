# Licenses

## Own work

Everything in this repository that is not listed below is the own work of OHRZ (Konstantin Schmidt) and is
licensed under the GNU General Public License, version 2 or (at your option) any later version
(SPDX `GPL-2.0-or-later`). Full text: [../LICENSE](../LICENSE), also [GPL-2.0.txt](GPL-2.0.txt).

    Copyright (C) 2026 OHRZ

    This program is free software; you can redistribute it and/or modify it under the terms of the
    GNU General Public License as published by the Free Software Foundation; either version 2 of the
    License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without
    even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
    General Public License for more details.

GPL-2.0-or-later was chosen because the bitstreams combine this code with the MiSTer framework
(Template_MiSTer `sys/`, GPL-2.0-or-later) and with cores under GPL-2.0 (PSX_MiSTer) as well as GPL-3.0
(N64_MiSTer, SNES_MiSTer); "or later" keeps the code compatible with both.

## Derived files

The patches and replacement files of a core profile change or replace files of that core. They are
derived works and are distributed under the license of the respective upstream project:

| Path | Upstream | License | Text |
| ---- | -------- | ------- | ---- |
| `firmware/common/mister/cores/msx/patches/`, `scc_rom_hide.vhd` | [MSX_MiSTer](https://github.com/MiSTer-devel/MSX_MiSTer) (`MSX.sv`, Copyright (C) 2017-2019 Sorgelig) | GPL-2.0-or-later | [GPL-2.0.txt](GPL-2.0.txt) |
| `firmware/common/mister/cores/psx/patches/`, `sdram.vhd`, `savestates.vhd` | [PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) | GPL-2.0 | [GPL-2.0.txt](GPL-2.0.txt) |
| `firmware/common/mister/cores/n64/patches/`, `sdram.vhd`, `Shiftreg.vhd`, `RDP_CombineAlpha.vhd`, `cpu_mul.vhd`, `cpu_addr_fwd.vhd` | [N64_MiSTer](https://github.com/MiSTer-devel/N64_MiSTer) | GPL-3.0 | [GPL-3.0.txt](GPL-3.0.txt) |
| `firmware/common/mister/cores/snes/patches/`, `msu_fifo.vhd` | [SNES_MiSTer](https://github.com/MiSTer-devel/SNES_MiSTer) | GPL-3.0 | [GPL-3.0.txt](GPL-3.0.txt) |
| `firmware/common/mister/patches/Main_MiSTer/` | [Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) | GPL-3.0 | [GPL-3.0.txt](GPL-3.0.txt) |

The other files of these core directories (`core.tcl`, `rules.py`, `core.xdc`, `pll*.vhd`, `hwtest.cfg`,
documentation) are own work under GPL-2.0-or-later; where they are combined with a GPL-3.0 core, the
combination is distributed under GPL-3.0.

## Third-party files

| Path | Origin | License | Text |
| ---- | ------ | ------- | ---- |
| `firmware/targets/zybo-z7-20/board_files/zybo-z7-20/` | [Digilent vivado-boards](https://github.com/Digilent/vivado-boards), Copyright (c) 2021 Digilent, Inc. | MIT | [MIT-Digilent-vivado-boards.txt](MIT-Digilent-vivado-boards.txt) |
| `firmware/targets/zybo-z7-20/constraints/Zybo-Z7-Master.xdc` | [Digilent digilent-xdc](https://github.com/Digilent/digilent-xdc), Copyright (c) 2017 Digilent | MIT | [MIT-Digilent-digilent-xdc.txt](MIT-Digilent-digilent-xdc.txt) |

## Not included

The following are cloned by the flows at pinned revisions (`firmware/common/checkouts.txt`) and are not
redistributed here: Template_MiSTer, Main_MiSTer, Menu_MiSTer, MSX_MiSTer, N64_MiSTer, SNES_MiSTer,
PSX_MiSTer (MiSTer-devel), vivado-library (Digilent), soc-prebuilt-firmware, linux-xlnx and u-boot-xlnx
(AMD/Xilinx). Their licenses apply to them and to everything built from them.

Note for MSX bitstreams: the core of MSX_MiSTer is based on the One Chip MSX / OCM-PLD sources (ESE
MSX-SYSTEM3, Copyright (c) 2006 Kazuhiro Tsujikawa, ESE Artists' factory; OCM-PLD Pack by KdL), which carry their own
BSD-style license with an additional condition that redistributions may not be sold or used commercially
without permission (header of `rtl/emsx_top.vhd` in MSX_MiSTer). A bitstream containing them is subject to it.

Who wrote the upstream projects: [../README.md](../README.md#credits).

No ROM, BIOS, firmware or game image of any third party is part of this repository.
