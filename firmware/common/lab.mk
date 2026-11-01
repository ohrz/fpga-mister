#-----------------------------------------------------------------------------
# File       : lab.mk
#-----------------------------------------------------------------------------
# Description:
# The lab: addresses the flows use (network boot, NFS, rootfs DNS, board
# addresses). Included by Makefiles/common.mk before the board profile.
# The values below are placeholders for a typical home network; set your own
# in lab.local.mk in the repository root (not tracked, see .gitignore), e.g.
#   LAB_TFTP_SERVER_IP      := 10.0.0.5
#   LAB_BOARD_IP_zybo-z7-20 := 10.0.0.30
# The hardware test scripts take the board address as an argument
# (tools/hwtest.py --board, tools/grab_frame.sh); make lab prints the values.
#-----------------------------------------------------------------------------

-include $(dir $(lastword $(MAKEFILE_LIST)))../../lab.local.mk

# the lab network: boards, TFTP/NFS server (this PC), router
LAB_NET				?= 192.168.1.0/24
LAB_NET_GATEWAY		?= 192.168.1.1
LAB_NET_MASK		?= 255.255.255.0
LAB_TFTP_SERVER_IP	?= 192.168.1.10
# DNS of the rootfs when NetworkManager is off (NFS root), the router
LAB_FALLBACK_DNS	?= $(LAB_NET_GATEWAY)
# clients allowed to mount the NFS root
LAB_NFS_CLIENTS		?= $(LAB_NET)

# static addresses of the boards (network boot, uEnv.txt)
LAB_BOARD_IP_zybo-z7-20	?= 192.168.1.20
