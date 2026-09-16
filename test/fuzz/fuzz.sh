#!/usr/bin/env bash
# Mutation fuzzing of the front end, the loader and the byte-oriented
# libraries on the ReleaseSafe build, where a memory error is a panic:
#
#   zig build fuzz -- [target|all] [cases] [seed]      # crash hunt on a fresh ReleaseSafe build
#   FUZZ_DIFF=1 test/fuzz/fuzz.sh [target] [cases]     # also diff outcomes against the reference
#                                                      # (run `zig build test-diff-safe` first: the
#                                                      #  ReleaseSafe binary is built only by that)
#
# A crash reproduces with the case number written to the log:
#   prolua run test/fuzz/fuzz.lua <target> <seed+case-1> 1 /dev/null <seed files>
# and the reproducer is saved under test/fuzz/crashes/.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
prolua="${PROLUA:-$root/zig-out/bin/prolua-safe}"
lua="${LUA:-lua}"
target="${1:-all}"
cases="${2:-2000}"
seed="${3:-$RANDOM}"
targets="source binary chunk pattern format pack numeral utf8 modules"
[ "$target" = all ] || targets="$target"
mapfile -t seeds < <(ls "$root"/test/diff/*.lua "$root"/test/puc/*.lua | head -60)
mkdir -p "$root/test/fuzz/crashes"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
[ -x "$prolua" ] || { echo "no ReleaseSafe binary at $prolua (zig build test-diff-safe builds it)" >&2; exit 1; }

# The `modules` target needs a project for the searcher: the same shape as
# the command-line suite's fixture, in the scratch directory
modroot="$tmp/modproj"
mkdir -p "$modroot/app/src/util" "$modroot/app/vendor/example.com/lib/two/src" "$modroot/one/src/internal" "$modroot/one/src/sub" \
    "$modroot/cache/modules/example.com/lib/three/v1.0.0/src" "$modroot/cache/modules/example.com/lib/four/v2.0.0/src"
printf 'schema = 1\nmodule = "example.com/me/app"\n\n[dependencies]\n"example.com/lib/one" = "v0.1.0"\n"example.com/lib/three" = "v1.0.0"\n\n[replacements."example.com/lib/one"]\npath = "../one"\n' > "$modroot/app/module.toml"
printf 'return "app"\n' > "$modroot/app/src/init.lua"
printf 'return "util"\n' > "$modroot/app/src/util.lua"
printf 'return "deep"\n' > "$modroot/app/src/util/deep.lua"
printf 'schema = 1\nmodule = "example.com/lib/one"\n[dependencies]\n"example.com/lib/four" = "v2.0.0"\n' > "$modroot/one/module.toml"
printf 'return "one"\n' > "$modroot/one/src/init.lua"
printf 'return "secret"\n' > "$modroot/one/src/internal/init.lua"
printf 'return "sub"\n' > "$modroot/one/src/sub/init.lua"
printf 'schema = 1\nmodule = "example.com/lib/two"\n' > "$modroot/app/vendor/example.com/lib/two/module.toml"
printf 'return "two"\n' > "$modroot/app/vendor/example.com/lib/two/src/init.lua"
printf 'schema = 1\nmodule = "example.com/lib/three"\n' > "$modroot/cache/modules/example.com/lib/three/v1.0.0/module.toml"
printf 'return "three"\n' > "$modroot/cache/modules/example.com/lib/three/v1.0.0/src/init.lua"
printf 'schema = 1\nmodule = "example.com/lib/four"\n' > "$modroot/cache/modules/example.com/lib/four/v2.0.0/module.toml"
printf 'return "four"\n' > "$modroot/cache/modules/example.com/lib/four/v2.0.0/src/init.lua"

status=0
for t in $targets; do
    log="$tmp/$t.log"
    rundir="$root"
    [ "$t" = modules ] && rundir="$modroot/app"
    if (cd "$rundir" && PROLUA_CACHE="$modroot/cache" timeout 1200 "$prolua" run "$root/test/fuzz/fuzz.lua" "$t" "$seed" "$cases" "$log" "${seeds[@]}") > "$tmp/$t.out" 2>&1; then
        echo "ok   $t: $cases cases from seed $seed"
    else
        rc=$?
        case_no=$(cat "$log" 2>/dev/null)
        echo "CRASH $t: exit $rc at case ${case_no:-?} (seed $seed); reproduce with: $prolua run test/fuzz/fuzz.lua $t $((seed + ${case_no:-1} - 1)) 1 /dev/null <seeds>"
        grep -m3 -E "panic|Segmentation|error:" "$tmp/$t.out" | sed 's/^/    /'
        cp "$tmp/$t.out" "$root/test/fuzz/crashes/$t-$seed-${case_no:-0}.txt"
        status=1
    fi
    # The binary loader is not compared: the reference does not validate
    # chunks, so what it loads or rejects, and with which message, differs;
    # the module searcher does not exist in the reference at all
    if [ -n "${FUZZ_DIFF:-}" ] && [ "$t" != binary ] && [ "$t" != chunk ] && [ "$t" != modules ]; then
        # the script's own path in messages is cut by LUA_IDSIZE, 60 here and 512 in the installed reference
        "$prolua" run "$root/test/fuzz/fuzz.lua" "$t" "$seed" "$cases" "$log" print "${seeds[@]}" 2>&1 | sed -E 's#[^ ]*fuzz\.lua:#fuzz.lua:#g' > "$tmp/$t.pro"
        "$lua" "$root/test/fuzz/fuzz.lua" "$t" "$seed" "$cases" "$log" print "${seeds[@]}" 2>&1 | sed -E 's#[^ ]*fuzz\.lua:#fuzz.lua:#g' > "$tmp/$t.ref"
        if diff --text -q "$tmp/$t.ref" "$tmp/$t.pro" >/dev/null; then
            echo "same $t: outcomes identical to the reference"
        else
            echo "DIFF $t: $(diff --text "$tmp/$t.ref" "$tmp/$t.pro" | grep -c '^<') of $cases cases differ from the reference"
            diff --text "$tmp/$t.ref" "$tmp/$t.pro" | head -12 | cut -c1-160 | sed 's/^/    /'
            status=1
        fi
    fi
done
exit $status
