#-----------------------------------------------------------------------------
# File       : build-zynq-fsbl.tcl
# Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
# Company    : OHRZ
# Created    : 2026-01-03
#-----------------------------------------------------------------------------
# Description:
# xsct build-zynq-fsbl.tcl <xsa> <workspace> [<uart>]
# Zynq-7000 FSBL (Standalone on ps7_cortexa9_0, xilffs + xilrsa) from the XSA of a design.
# The workspace is removed and created anew (firmware/build/<platform>/<version>/fsbl);
# the FSBL ends up in <workspace>/zynq_fsbl/Debug/zynq_fsbl.elf.  <uart> is the console
# of the FSBL output (default ps7_uart_0; zybo-z7-20: ps7_uart_1).
# FLOW=boot runs it (BOOT_FSBL_CMDS of Makefiles/arch-zynq.mk) when the board's
# files/fsbl/fsbl.elf is missing.
#-----------------------------------------------------------------------------
# Copyright (c) 2026 by OHRZ
#-----------------------------------------------------------------------------
if { $argc < 2 || $argc > 3 } {
    puts "usage: xsct build-zynq-fsbl.tcl <xsa> <workspace> \[<uart>\]"
    exit 1
}
set xsa [file normalize [lindex $argv 0]]
set workspace [file normalize [lindex $argv 1]]
set uart [expr { $argc == 3 ? [lindex $argv 2] : "ps7_uart_0" }]
if { ![file isfile $xsa] } {
    puts "ERROR: no XSA $xsa (FLOW=vivado make xsa-export)"
    exit 1
}

# a fresh workspace (an old one makes "platform create" fail with "project already exists")
file delete -force $workspace
setws $workspace

platform create -name "hw_platform" -hw $xsa
domain create -name "fsbl_domain" -os standalone -proc ps7_cortexa9_0
bsp config stdin $uart
bsp config stdout $uart
# the FSBL needs the FAT file system and RSA libraries
bsp setlib -name xilffs
bsp setlib -name xilrsa
platform write
platform generate
bsp regenerate

app create -name "zynq_fsbl" -platform "hw_platform" -domain "fsbl_domain" -template "Zynq FSBL"
app build -name "zynq_fsbl"
puts "FSBL: $workspace/zynq_fsbl/Debug/zynq_fsbl.elf"
