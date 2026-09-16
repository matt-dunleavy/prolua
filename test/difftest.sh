#!/usr/bin/env bash
# Differential test: run each script under both the reference Lua 5.4 and
# Prolua, and report where the two disagree.
#
# Expected output is whatever the reference interpreter prints, so these tests
# do not encode anyone's belief about what Lua does -- only what it actually
# does. Scripts live in test/diff/.
#
#   test/difftest.sh              run every script in test/diff
#   test/difftest.sh foo.lua ...  run only the named scripts
#
# Set LUA to point at a different reference binary.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# PROLUA names a different binary (the ReleaseSafe lane of `zig build test-all`)
prolua="${PROLUA:-$root/zig-out/bin/prolua}"
lua="${LUA:-lua}"

if ! command -v "$lua" >/dev/null 2>&1; then
    echo "no reference interpreter '$lua' on PATH; skipping differential tests"
    exit 0
fi
if [ ! -x "$prolua" ]; then
    echo "prolua not built at $prolua (run 'zig build')" >&2
    exit 1
fi
# PROLUA_WRAPPER="valgrind -q --error-exitcode=99" runs prolua under a memory
# checker: its complaints land in the output and fail the script.
# DIFF_TIMEOUT is the seconds per script (default 30).
# shellcheck disable=SC2206
wrapper=(${PROLUA_WRAPPER:-})
if [ "${#wrapper[@]}" -gt 0 ] && ! command -v "${wrapper[0]}" >/dev/null 2>&1; then
    echo "wrapper '${wrapper[0]}' not found; skipping"
    exit 0
fi
per_script="${DIFF_TIMEOUT:-30}"

# Scripts whose output is known to differ for a tracked reason. Each entry
# names the item in docs/project/project.md that would close the gap; nothing
# belongs here without one.
declare -A known_diff=(
)

if [ "$#" -gt 0 ]; then
    scripts=("$@")
else
    # test/diff holds scripts written for this harness; test/lua54 is the
    # 27-file corpus. testdata/ is a copy of the official suite and is run
    # by puctest.sh, not as standalone scripts here.
    mapfile -t scripts < <(find "$root/test/diff" "$root/test/lua54" -name '*.lua' ! -path '*/testdata/*' | sort)
fi

pass=0
fail=0
known=0
failed_names=()

# Output is compared through files rather than shell variables: some scripts
# print NUL bytes (utf8.charpattern), which command substitution silently drops.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for script in "${scripts[@]}"; do
    name="$(basename "$script")"

    # Both interpreters prefix uncaught errors with their own name; strip it so
    # the comparison is about behaviour rather than argv[0]
    # Run from the script's directory under its bare name, so chunk names
    # (and the messages that quote them) do not depend on where the tree
    # lives or on the size of the reference's chunk-id buffer
    dir="$(dirname "$script")"
    (cd "$dir" && timeout 30 "$lua" "$name" 2>&1) | sed 's/^lua: //' > "$tmp/expected"
    (cd "$dir" && timeout "$per_script" "${wrapper[@]}" "$prolua" run "$name" 2>&1) | sed 's/^prolua: //' > "$tmp/actual"

    if cmp -s "$tmp/expected" "$tmp/actual"; then
        pass=$((pass + 1))
        # A script that starts matching should stop being excused
        if [ -n "${known_diff[$name]+set}" ]; then
            echo "=== NOTE: $name now matches; remove it from known_diff"
        fi
    elif [ -n "${known_diff[$name]+set}" ]; then
        known=$((known + 1))
    else
        fail=$((fail + 1))
        failed_names+=("$name")
        echo "=== DIFF: $name"
        diff "$tmp/expected" "$tmp/actual" | head -30 | sed 's/^/    /'
    fi
done

echo
echo "differential: $pass passed, $fail failed, $known known-different (reference: $("$lua" -v 2>&1))"
if [ "$known" -gt 0 ]; then
    echo "known differences (see docs/project/project.md):"
    for n in "${!known_diff[@]}"; do echo "    $n: ${known_diff[$n]}"; done
fi
if [ "$fail" -gt 0 ]; then
    echo "failing: ${failed_names[*]}"
    exit 1
fi
