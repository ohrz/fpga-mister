#!/bin/bash
# ----------------------------------------------------------------------------------
#  Title      : Clone and pin the external sources of fpga-mister (firmware/common/checkouts.txt)
#  File       : checkout.sh
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-18
# ----------------------------------------------------------------------------------
#  Description: checkout.sh NAME [DIR]      clone NAME (once) into DIR (default _Checkouts/NAME) and
#                                           check out its pinned rev (or verify the branch tip)
#               checkout.sh --check NAME [DIR]   verify only: exit 1 with the commands to fix it
#               checkout.sh --rev|--url|--branch|--dir NAME   print one field
#               checkout.sh --list          the table
#               The table is firmware/common/checkouts.txt (name url branch rev options);
#               $VIVADO_VER in a branch comes from VIVADO_VER or XILINX_VIVADO (default 2025.2).
#               A checkout is never modified beyond fetch and a detached checkout of the pin;
#               the flows build in worktrees or copies of it.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
table=$root/firmware/common/checkouts.txt
checkouts=${CHECKOUTS_DIR:-$root/_Checkouts}

ver=${VIVADO_VER:-}
if [ -z "$ver" ] && [ -n "${XILINX_VIVADO:-}" ]; then
    v=${XILINX_VIVADO%/}; v=${v%/Vivado}; ver=${v##*/}
fi
ver=${ver:-2025.2}

usage() { sed -n '/^#  Description/,/^# ---/p' "$0" | sed '$d' | sed 's/^#  Description: /  /; s/^#               /  /' >&2; exit 2; }

lookup() {   # lookup NAME -> url branch rev options (branch/rev/options "-" become empty)
    local line
    line=$(awk -v n="$1" '$1 == n && $1 !~ /^#/ {print $2, $3, $4, $5; exit}' "$table")
    [ -n "$line" ] || { echo "checkout.sh: unknown source '$1' (firmware/common/checkouts.txt)" >&2; exit 2; }
    read -r url branch rev options <<<"$line"
    [ "$branch" != - ] || branch=
    [ "$rev" != - ] || rev=
    [ "$options" != - ] || options=
    branch=${branch//\$VIVADO_VER/$ver}
}

mode=checkout
case ${1:-} in
    --list) sed -n '/^[^#]/p' "$table"; exit 0 ;;
    --check) mode=check; shift ;;
    --rev|--url|--branch|--dir) mode=${1#--}; shift ;;
    -*|"") usage ;;
esac
[ $# -ge 1 ] || usage
name=$1
lookup "$name"
dir=${2:-$checkouts/$name}
case $mode in
    rev) echo "$rev"; exit 0 ;;
    url) echo "$url"; exit 0 ;;
    branch) echo "$branch"; exit 0 ;;
    dir) echo "$dir"; exit 0 ;;
esac

if [ ! -e "$dir/.git" ]; then
    [ $mode = checkout ] || { echo "$name: not checked out at $dir (firmware/common/scripts/checkout.sh $name)" >&2; exit 1; }
    args=()
    case " $options " in *" shallow "*) args+=(--depth 1 --single-branch) ;; esac
    if [ -n "$rev" ] && [[ " $options " == *" shallow "* ]]; then
        args+=(--branch "$rev")                      # a tag, the only thing a shallow clone can pin
    elif [ -n "$branch" ]; then
        args+=(--branch "$branch")
    fi
    echo "checkout.sh: clone $name ($url${branch:+, $branch}) -> $dir"
    mkdir -p "$(dirname "$dir")"
    git clone -q "${args[@]}" "$url" "$dir"
fi

if [ -n "$rev" ]; then
    # pinned: fetch the commit or tag when the clone does not have it, then detach on it
    if ! git -C "$dir" cat-file -e "$rev^{commit}" 2>/dev/null; then
        [ $mode = checkout ] || { echo "$name: $dir does not contain $rev" >&2; exit 1; }
        git -C "$dir" fetch -q origin "$rev" 2>/dev/null || git -C "$dir" fetch -q --tags origin
    fi
    want=$(git -C "$dir" rev-parse "$rev^{commit}")
    head=$(git -C "$dir" rev-parse HEAD)
    if [ "$head" != "$want" ]; then
        [ $mode = checkout ] || { echo "$name: $dir is at $head, not at $rev ($want): firmware/common/scripts/checkout.sh $name" >&2; exit 1; }
        git -C "$dir" checkout -q --detach "$rev"
    fi
    case " $options " in *" submodules "*) [ $mode = check ] || git -C "$dir" submodule update -q --init --recursive ;; esac
    echo "$name: $(git -C "$dir" rev-parse --short HEAD) ($rev)"
else
    # the tip of the branch (release branches): the checkout must be that branch at origin's tip
    [ -n "$branch" ] || { echo "checkout.sh: $name has neither a branch nor a rev in the table" >&2; exit 2; }
    head=$(git -C "$dir" rev-parse HEAD)
    tip=$(git -C "$dir" rev-parse -q --verify "origin/$branch" 2>/dev/null || true)
    if [ -z "$tip" ] || [ "$head" != "$tip" ]; then
        echo "$name: $dir is not at origin/$branch, switch it with:" >&2
        echo "  git -C $dir fetch origin +refs/heads/$branch:refs/remotes/origin/$branch" >&2
        echo "  git -C $dir switch -C $branch origin/$branch" >&2
        exit 1
    fi
    echo "$name: $(git -C "$dir" rev-parse --short HEAD) (origin/$branch)"
fi
