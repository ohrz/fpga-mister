#!/bin/bash
# ----------------------------------------------------------------------------------
#  Title      : Hardware-free self-check of fpga-mister
#  File       : selfcheck.sh
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-18
# ----------------------------------------------------------------------------------
#  Description: make test (without FLOW) from the repository root, or selfcheck.sh
#               directly. Runs in seconds, needs no board, no Vivado, no root:
#                 1. bash -n and shellcheck (if installed) of every tracked shell script
#                 2. python3 -m py_compile of every tracked Python script, and the unit
#                    tests firmware/common/mister/{scripts,tools}/*_test.py, status.py --check
#                    (STATUS.md tables of the cores and boards)
#                 3. make -n of every flow x board x action: a board a flow supports
#                    must dry-run every action of that flow, every other board must be
#                    refused with the "not supported by this flow" message
#                 4. the GHDL testbenches of the own VHDL (firmware/common/mister/tb) and of the
#                    HDMI transmitter (firmware/common/ip/hdmi-tx)
#                 5. the patches of the port (cores/<core>/patches, patches/<checkout>) apply
#                    to the pinned checkout in _Checkouts (git apply one after the other on
#                    an export of the pin, as prepare_sources.py does: several patches may
#                    change the same file; not run for a checkout that is not cloned)
#                 6. board scripts with fixed output: ssm2603-init.sh writes the register
#                    sequence of the codec (i2cset replaced by a logger)
#                 7. core profiles (firmware/common/mister/cores/<core>, not _template): the
#                    files core.tcl names exist, and prepare_sources.py with the profile's
#                    rules.py passes on the pinned checkout (every expected rule count, the
#                    sys_top_zynq.sv rewrite, the patches; not run without the checkout), and
#                    core_survey.py completes its report on the checkout
#               Exit code 1 and a FAIL line per finding.
#               Environment: XILINX_VIVADO (default /opt/Xilinx/2025.2/Vivado, only the
#               version is taken from it), SHELLCHECK=0 skips shellcheck, GHDL=0 the testbenches.
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$root" || exit 2
export XILINX_VIVADO=${XILINX_VIVADO:-/opt/Xilinx/2025.2/Vivado}
export LC_ALL=C
fail=0
failed() { echo "FAIL: $*"; fail=1; }

# own files only: tracked, not third party
own_files() {   # own_files <git ls-files pattern>
    git ls-files --cached --others --exclude-standard "$@" | grep -v -E '^_Checkouts/'
}

echo "== 1. shell scripts (bash -n, shellcheck)"
mapfile -t scripts < <(own_files '*.sh')
n=0
for s in "${scripts[@]}"; do
    bash -n "$s" || failed "syntax $s"
    n=$((n + 1))
done
echo "   $n scripts parsed"
if [ "${SHELLCHECK:-1}" = 1 ] && command -v shellcheck >/dev/null; then
    # warnings that are intended in this repository (single-item loops, commas inside
    # generator arguments, word splitting of pkg-config output, helper variables of tests)
    if shellcheck -S warning -e SC1007,SC2034,SC2043,SC2046,SC2054,SC2100,SC2115 "${scripts[@]}"; then
        echo "   shellcheck clean ($(shellcheck --version | sed -n 's/^version: //p'))"
    else
        failed "shellcheck"
    fi
else
    echo "   shellcheck not run (not installed or SHELLCHECK=0)"
fi

echo "== 2. python scripts (py_compile, unit tests)"
mapfile -t pys < <(own_files '*.py')
if [ ${#pys[@]} = 0 ] || python3 -m py_compile "${pys[@]}"; then
    echo "   ${#pys[@]} scripts compiled"
else
    failed "py_compile"
fi
for t in firmware/common/mister/scripts/*_test.py firmware/common/mister/tools/*_test.py; do
    if out=$(python3 "$t" 2>&1); then
        echo "   $(basename "$t"): $(grep -o 'Ran [0-9]* tests' <<<"$out") OK"
    else
        failed "$t"; tail -n 20 <<<"$out" | sed 's/^/      /'
    fi
done

if out=$(python3 firmware/common/mister/scripts/status.py --check 2>&1); then
    sed 's/^/   /' <<<"$out"
else
    failed "status.py --check"; sed 's/^/      /' <<<"$out"
fi

echo "== 3. make -n of every flow x board x action"
flows=$(ls Makefiles/*/Makefile | sed 's|Makefiles/\(.*\)/Makefile|\1|')
boards=""
for mk in firmware/targets/[!_]*/platform.mk; do       # firmware/targets/_template is no board
    boards+=" $(basename "$(dirname "$mk")")"
done
actions="create build xsa-export launch setup checkout patch collect copy clean tftpboot package write image flash"
runs=0
for flow in $flows; do
    for b in $boards; do
        supported=$(sed -n 's/^PLATFORM_FLOWS[[:space:]]*:=//p' "firmware/targets/$b/platform.mk")
        if [[ " $supported " == *" $flow "* ]]; then
            for a in $actions help; do
                out=$(env PLATFORM=$b FLOW=$flow TOPLEVEL=t_$b APP=app SDCARD=/dev/sdz make -n "$a" 2>&1)
                rc=$?
                runs=$((runs + 1))
                # fine: an action the flow does not have, and a recursive make into a build
                # directory that does not exist yet (make -n still enters $(MAKE) -C ...)
                if [ $rc -ne 0 ] && ! grep -qE "No rule to make target|firmware/build/.*: No such file or directory" <<<"$out"; then
                    failed "make -n: PLATFORM=$b FLOW=$flow $a (rc=$rc)"; echo "$out" | tail -3 | sed 's/^/      /'
                fi
            done
        else
            out=$(PLATFORM=$b FLOW=$flow TOPLEVEL=t_$b make -n build 2>&1)
            runs=$((runs + 1))
            grep -q "not supported by this flow" <<<"$out" || failed "make -n: PLATFORM=$b FLOW=$flow must be refused"
        fi
    done
done
echo "   $runs dry runs"

echo "== 4. VHDL testbenches (GHDL)"
if [ "${GHDL:-1}" = 1 ] && command -v ghdl >/dev/null; then
    if out=$(make -s -C firmware/common/mister/tb 2>&1); then
        grep -E '^[A-Za-z0-9_]+: PASS$' <<<"$out" | sed 's/^/   /'
    else
        failed "testbenches"; echo "$out" | grep -E 'FAIL|failure|error' | sed 's/^/      /'
    fi
    if out=$(make -s -C firmware/common/ip/hdmi-tx/tb WORK="$root/firmware/build/tb/hdmi-tx" 2>&1); then
        grep -E '^[A-Za-z0-9_]+: (PASS|NOT RUN.*)$' <<<"$out" | sed 's/^/   hdmi-tx /'
    else
        failed "hdmi-tx testbenches"; grep -E 'FAIL|failure|error' <<<"$out" | sed 's/^/      /'
    fi
else
    echo "   testbenches not run (ghdl not installed or GHDL=0)"
fi

echo "== 5. patches of the port (git apply in order on the pinned checkouts)"
# git apply <patch> ... in <dir>, one patch after the other (git apply with several patches checks
# each one against the unchanged tree); "-R" reverses them in the opposite order
apply_each() {
    local dir=$1 rev=$2; shift 2
    local list=("$@") i
    [ "$rev" = -R ] && for ((i = ${#list[@]} - 1; i >= 0; i--)); do
        (cd "$dir" && GIT_CEILING_DIRECTORIES="$(dirname "$dir")" git apply -R "${list[i]}") || return 1
    done
    [ "$rev" = -R ] || for i in "${list[@]}"; do
        (cd "$dir" && GIT_CEILING_DIRECTORIES="$(dirname "$dir")" git apply "$i") || return 1
    done
}
while read -r name d; do
    patches=("$d"/*.patch)
    [ -f "${patches[0]}" ] || continue
    if [ ! -d "_Checkouts/$name/.git" ]; then
        echo "   $name: not run (no checkout, make setup of its flow)"
    elif [ "$(git -C "_Checkouts/$name" rev-parse HEAD)" != "$(firmware/common/scripts/checkout.sh --rev "$name")" ]; then
        echo "   $name: not run (checkout is not at its pin)"
    else
        mkdir -p "$root/firmware/build"
        pin=$(mktemp -d "$root/firmware/build/selfcheck-pin.XXXXXX")
        git -C "_Checkouts/$name" archive --prefix="$name/" HEAD | tar -x -C "$pin"
        if err=$(apply_each "$pin/$name" + "${patches[@]}" 2>&1); then
            echo "   $name: ${#patches[@]} patches apply"
            # the copy of prepare_sources.py lies inside this repository, like the build copies:
            # the patches must really be in it (they reverse-apply), not skipped by git
            prep=$(mktemp -d "$root/firmware/build/selfcheck-prepare.XXXXXX")
            if ! out=$(firmware/common/mister/scripts/prepare_sources.py "$name" "_Checkouts/$name" "$prep/$name" 2>&1); then
                failed "prepare_sources.py $name"; sed 's/^/      /' <<<"$out"
            elif err=$(apply_each "$prep/$name" -R "${patches[@]}" 2>&1); then
                echo "   $name: prepare_sources.py copy contains the ${#patches[@]} patches"
            else
                failed "prepare_sources.py copy of $name lacks patches"; sed 's/^/      /' <<<"$err"
            fi
            rm -rf "$prep"
        else
            failed "patches of $name"; sed 's/^/      /' <<<"$err"
        fi
        rm -rf "$pin"
    fi
done < <(firmware/common/mister/scripts/prepare_sources.py --patch-dirs || failed "prepare_sources.py --patch-dirs")

echo "== 6. board scripts (ssm2603-init.sh register sequence)"
ssm_tmp=$(mktemp -d)
printf '#!/bin/bash\necho "$*" >> %s/log\n' "$ssm_tmp" > "$ssm_tmp/i2cset"
chmod +x "$ssm_tmp/i2cset"
# R15 reset, R6 power, R2 headphone 0 dB both, R4 DAC, R5 unmute, R7 slave I2S 16 bit,
# R8 MCLK/2 48 kHz, R9 active, R6 output on (byte 1 = register << 1 | bit 8)
ssm_expect='-y 0 0x1a 30 0
-y 0 0x1a 12 119
-y 0 0x1a 5 121
-y 0 0x1a 8 18
-y 0 0x1a 10 0
-y 0 0x1a 14 2
-y 0 0x1a 16 64
-y 0 0x1a 18 1
-y 0 0x1a 12 103'
if SSM2603_I2CSET="$ssm_tmp/i2cset" firmware/targets/zybo-z7-20/files/mister-rootfs/usr/local/sbin/ssm2603-init.sh >/dev/null &&
   [ "$(cat "$ssm_tmp/log")" = "$ssm_expect" ]; then
    echo "   ssm2603-init.sh: 9 register writes as expected"
else
    failed "ssm2603-init.sh register sequence"; diff <(echo "$ssm_expect") "$ssm_tmp/log" | sed 's/^/      /'
fi
rm -rf "$ssm_tmp"

echo "== 7. core profiles (files of core.tcl, prepare_sources.py with rules.py, core_survey.py)"
mdir=firmware/common/mister
for prof in "$mdir"/cores/*/core.tcl; do
    core=$(basename "$(dirname "$prof")")
    [ "${core#_}" = "$core" ] || continue
    name=$(sed -n 's/^set core_name *\([A-Za-z0-9_.-]*\).*/\1/p' "$prof")
    [ -n "$name" ] || { failed "$prof: no core_name"; continue; }
    # files named by core_add / core_xdc (relative to firmware/common/mister)
    missing=""
    for f in $(sed -n 's/^set core_\(add\|xdc\) *{\(.*\)}.*/\2/p' "$prof"); do
        [ -f "$mdir/$f" ] || missing="$missing $f"
    done
    [ -z "$missing" ] || failed "$core: core.tcl names missing files:$missing"
    if [ ! -d "_Checkouts/$name/.git" ]; then
        echo "   $core ($name): prepare_sources.py not run (no checkout)"
        continue
    elif [ "$(git -C "_Checkouts/$name" rev-parse HEAD)" != "$(firmware/common/scripts/checkout.sh --rev "$name")" ]; then
        echo "   $core ($name): prepare_sources.py not run (checkout is not at its pin)"
        continue
    fi
    rules=()
    [ -f "$mdir/cores/$core/rules.py" ] && rules=("$mdir/cores/$core/rules.py")
    mkdir -p "$root/firmware/build"
    prep=$(mktemp -d "$root/firmware/build/selfcheck-core.XXXXXX")
    if out=$("$mdir/scripts/prepare_sources.py" "$name" "_Checkouts/$name" "$prep/$name" "${rules[@]}" 2>&1); then
        echo "   $core ($name): $(grep -c ': rule ' <<<"$out") rules, sys_top_zynq.sv, patches: as expected"
    else
        failed "prepare_sources.py $name (profile $core)"; grep -E 'ERROR|FAILED' <<<"$out" | sed 's/^/      /'
    fi
    rm -rf "$prep"
    tmpl=()
    [ -d _Checkouts/Template_MiSTer/sys ] && tmpl=(_Checkouts/Template_MiSTer)
    if survey=$("$mdir/scripts/core_survey.py" "_Checkouts/$name" "${tmpl[@]}" 2>&1) &&
            grep -q '^## 6\. ' <<<"$survey"; then
        echo "   $core ($name): core_survey.py report complete"
    else
        failed "core_survey.py $name"
    fi
done

if [ $fail = 0 ]; then echo "SELFCHECK PASS"; else echo "SELFCHECK FAIL"; exit 1; fi
