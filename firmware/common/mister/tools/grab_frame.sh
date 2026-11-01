#!/bin/bash
# ----------------------------------------------------------------------------------
#  Title      : Grab the scaler input frame of a running core
#  Project    : fpga-mister
#  File       : grab_frame.sh
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-28
# ----------------------------------------------------------------------------------
#  Description: grab_frame.sh <png> [<board>]
#               Reads the first ascal buffer from the reserved DDR of the board over ssh
#               (/dev/mem, header at 0x20000000, image at +0x100, 1280 bytes per line,
#               RGB565 little endian) and writes the first 242 lines x 598 pixels, doubled,
#               as PNG (python3-pil on the host). Board default root@192.168.1.20
#               (the placeholder of firmware/common/lab.mk).
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
set -euo pipefail
png=${1:?usage: grab_frame.sh <png> [<board>]}
board=${2:-root@192.168.1.20}
raw=$(mktemp)
trap 'rm -f "$raw"' EXIT
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$board" \
    'python3 -c "
import mmap, os, sys
f = os.open(\"/dev/mem\", os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(f, 0x100000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x20000000)
sys.stdout.buffer.write(m[:0x100 + 1280 * 260])"' > "$raw"
python3 - "$raw" "$png" <<'PY'
import sys
from PIL import Image
d = open(sys.argv[1], "rb").read()
img = Image.new("RGB", (598, 242)); px = img.load()
for y in range(242):
    for x in range(598):
        o = 0x100 + y * 1280 + 2 * x; v = d[o] | d[o + 1] << 8
        px[x, y] = ((v >> 11) << 3, ((v >> 5) & 63) << 2, (v & 31) << 3)
img.resize((1196, 484), Image.NEAREST).save(sys.argv[2])
PY
echo "grab_frame.sh: $png"
