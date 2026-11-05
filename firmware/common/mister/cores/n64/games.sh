#!/bin/bash
# ----------------------------------------------------------------------------------
#  Title      : Start files of the N64 core: games/N64/N64-database.txt
#  Project    : fpga-mister
#  File       : games.sh
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-11-05
# ----------------------------------------------------------------------------------
#  Description: games.sh <games dir> [<rom dir>]
#               Copies the game database next to the games, where Main_MiSTer looks for
#               it. Without an entry for the game there is no save type and no save file.
#               <rom dir> is not used. Called by FLOW=mister make package for the core N64.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
set -euo pipefail

games=${1:?usage: games.sh <games dir> [<rom dir>]}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

cp "$here/N64-database.txt" "$games/N64-database.txt"
echo "games.sh: $games/N64-database.txt"
