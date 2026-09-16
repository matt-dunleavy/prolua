#!/usr/bin/env bash
# Run the official Lua 5.4.8 test suite (test/puc, from lua.org/tests) under
# prolua, one file at a time, and report each against the expectation list.
#
# The suite is run the way its own `all.lua` runs it in portable, soft mode
# (`_port` skips platform-specific checks, `_soft` shrinks the heavy loops),
# but file by file so one failure does not hide the rest. Files listed in
# `expected_pass` must exit 0; the others are reported but do not fail the
# run, and a file that starts passing is called out so the list gets updated.
#
#   test/puctest.sh              run every file
#   test/puctest.sh calls.lua    run only the named files
#   PROLUA=path test/puctest.sh  run another binary (a ReleaseSafe build, say)

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# PROLUA names a different binary, e.g. a ReleaseSafe or ReleaseFast build
prolua="${PROLUA:-$root/zig-out/bin/prolua}"
suite="$root/test/puc"

if [ ! -x "$prolua" ]; then
    echo "prolua not built at $prolua (run 'zig build')" >&2
    exit 1
fi
# PROLUA_WRAPPER="valgrind -q --error-exitcode=99" runs the suite under a
# memory checker (hours); PUC_TIMEOUT is the seconds per file (default 300)
# shellcheck disable=SC2206
wrapper=(${PROLUA_WRAPPER:-})
if [ "${#wrapper[@]}" -gt 0 ] && ! command -v "${wrapper[0]}" >/dev/null 2>&1; then
    echo "wrapper '${wrapper[0]}' not found; skipping"
    exit 0
fi
per_file="${PUC_TIMEOUT:-300}"
if [ ! -d "$suite" ]; then
    echo "official test suite not found at $suite" >&2
    exit 1
fi

# Files prolua passes today. Keep this in step with docs/project/project.md.
expected_pass=(
    api.lua attrib.lua big.lua bitwise.lua bwcoercion.lua calls.lua
    closure.lua code.lua constructs.lua coroutine.lua cstack.lua db.lua
    errors.lua events.lua files.lua gc.lua gengc.lua goto.lua literals.lua
    locals.lua math.lua nextvar.lua pm.lua sort.lua strings.lua tpack.lua
    tracegc.lua utf8.lua vararg.lua verybig.lua
)

# Never run: all.lua/main.lua drive the suite, heavy.lua allocates until it
# is killed, and the `T` (ltests) checks need the reference's debug build.
skip=(all.lua main.lua heavy.lua)

declare -A want
for f in "${expected_pass[@]}"; do want[$f]=1; done
declare -A skipset
for f in "${skip[@]}"; do skipset[$f]=1; done

cd "$suite"
if [ "$#" -gt 0 ]; then
    files=("$@")
else
    mapfile -t files < <(ls *.lua | sort)
fi

pass=0
fail=0
unexpected=()
newly=()
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for f in "${files[@]}"; do
    [ -n "${skipset[$f]+set}" ] && continue
    if timeout "$per_file" "${wrapper[@]}" "$prolua" run -e '_port=true _soft=true' "$f" >"$tmp" 2>&1; then
        pass=$((pass + 1))
        if [ -z "${want[$f]+set}" ]; then
            newly+=("$f")
            echo "=== NOTE: $f now passes; add it to expected_pass"
        else
            echo "ok   $f"
        fi
    else
        if [ -n "${want[$f]+set}" ]; then
            fail=$((fail + 1))
            unexpected+=("$f")
            echo "=== FAIL: $f (expected to pass)"
        else
            echo "fail $f (known)"
        fi
        grep -v '^\s' "$tmp" | grep -v '^[0-9]*$' | head -3 | sed 's/^/    /'
    fi
done

echo
echo "official suite: $pass passed, $fail unexpected failures, ${#newly[@]} newly passing"
if [ "$fail" -gt 0 ]; then
    echo "unexpected: ${unexpected[*]}"
    exit 1
fi
