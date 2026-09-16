#!/usr/bin/env bash
# Real programs as a correctness corpus.
#
# Pure-Lua projects with their own test suites, each run under the reference
# interpreter and under prolua from the same directory with the same
# arguments; stdout, stderr and the exit status must agree after the
# normalisation below (program names, timings, table addresses). The
# projects are cloned at pinned commits into .cache/corpus the first time
# (network needed), and Fennel is bootstrapped with the reference.
#
#   zig build test-corpus            # ReleaseSafe binary (the Debug allocator
#                                    # makes these runs about 30x slower)
#   PROLUA=path test/corpus/corpustest.sh
#
# Add a project as one line in the table: name, repository, commit, the
# directory to run in, LUA_PATH for the run, a preparation command run once
# after cloning (with the reference on PATH as `lua`), and the arguments
# given to the interpreter.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cache="$root/.cache/corpus"
prolua="$(realpath -m "${PROLUA:-$root/zig-out/bin/prolua-safe}")"
lua="${LUA:-lua}"

if ! command -v "$lua" >/dev/null 2>&1; then
    echo "no reference interpreter '$lua' on PATH; skipping the corpus"
    exit 0
fi
if [ ! -x "$prolua" ]; then
    echo "prolua not built at $prolua (run 'zig build test-corpus')" >&2
    exit 1
fi
mkdir -p "$cache"

# Paths are explicit (no ";;"): the two interpreters' default paths name
# different directories, and the "no file" lines of a failed require would
# differ for that reason alone. LUA_CPATH is "./?.so" for the same reason.
# The last column is a filter both outputs pass through before comparison,
# for a suite whose output varies between two runs of the reference itself
# (serpent prints tables in `pairs` order, which the reference's per-run
# string-hash seed changes): the verdict lines are what is compared.
#  name       repository                  commit   dir    LUA_PATH                                   prepare                           arguments                                                             filter
projects=(
    "json.lua  |rxi/json.lua              |dbf4b2d |test  |./?.lua                                   |                                  |test.lua                                                              |cat"
    "dkjson    |LuaDist/dkjson            |e72ba0c |.     |./?.lua                                   |                                  |jsontest.lua                                                          |grep -v 'mixed table encoded'"
    "serpent   |pkulchenko/serpent        |139fc18 |.     |src/?.lua;./?.lua                         |                                  |t/test.lua                                                            |tail -2"
    "luaunit   |bluebird75/luaunit        |9678c93 |.     |./?.lua                                   |                                  |run_unit_tests.lua                                                    |cat"
    "lunajson  |grafi-tt/lunajson         |e3a9666 |.     |src/?.lua;util/?.lua;test/?.lua;./?.lua   |                                  |test/test.lua                                                         |cat"
    "LuaMinify |stravant/LuaMinify        |cce8f5b |.     |./?.lua                                   |                                  |-e math.randomseed(1) CommandLineMinify.lua ParseLua.lua /dev/stdout |cat"
    "Fennel    |bakpakin/Fennel           |d370f8d |.     |?.lua                                     |make test LUA=lua >/dev/null 2>&1 |test/init.lua                                                         |cat"
    "tl        |teal-language/tl          |cba0657 |.     |./?.lua                                   |                                  |tl.lua check tl.tl                                                    |cat"
)

# Trim surrounding blanks (not through xargs, whose echo would eat a leading -e)
trim() {
    local v="$*"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

# Strip what legitimately differs between two runs
normalize() {
    sed -E -e 's#^(lua|prolua|[^ :]*/prolua[^ :]*|[^ :]*/lua[^ :]*): #lua: #' \
           -e 's/0x[0-9a-f]+/0xADDR/g' \
           -e 's/[0-9]+\.[0-9]+ (seconds|second\(s\))/N \1/g' \
           -e 's/approximately [0-9]+ second/approximately N second/g'
}

fetch() {
    local name=$1 repo=$2 commit=$3 dir="$cache/$1"
    if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)" = "$commit" ]; then return 0; fi
    rm -rf "$dir"
    git init -q "$dir" &&
        git -C "$dir" fetch -q --depth 1 "https://github.com/$repo" "$commit" 2>/dev/null &&
        git -C "$dir" checkout -q FETCH_HEAD || {
        # a short hash cannot be fetched directly everywhere: fall back to a full clone
        rm -rf "$dir"
        git clone -q "https://github.com/$repo" "$dir" && git -C "$dir" checkout -q "$commit"
    }
}

pass=0
fail=0
skip=0
for line in "${projects[@]}"; do
    IFS='|' read -r name repo commit dir lpath prepare args filter <<< "$line"
    name=$(trim "$name")
    if [ -n "${CORPUS_ONLY:-}" ] && [ "$name" != "$CORPUS_ONLY" ]; then continue; fi
    repo=$(trim "$repo"); commit=$(trim "$commit")
    dir=$(trim "$dir"); lpath=$(trim "$lpath"); prepare=$(trim "$prepare"); args=$(trim "$args"); filter=$(trim "$filter")
    if ! fetch "$name" "$repo" "$commit"; then
        echo "skip $name (could not fetch $repo@$commit)"
        skip=$((skip + 1))
        continue
    fi
    if [ -n "$prepare" ] && [ ! -f "$cache/$name/.prepared" ]; then
        (cd "$cache/$name" && bash -c "$prepare") && touch "$cache/$name/.prepared" || {
            echo "skip $name (preparation failed: $prepare)"
            skip=$((skip + 1))
            continue
        }
    fi
    rundir="$cache/$name/$dir"
    # shellcheck disable=SC2086
    ref=$(cd "$rundir" && LUA_PATH="$lpath" LUA_CPATH="./?.so" timeout 600 "$lua" $args 2>&1; echo "exit=$?")
    # shellcheck disable=SC2086
    out=$(cd "$rundir" && LUA_PATH="$lpath" LUA_CPATH="./?.so" timeout 600 "$prolua" run $args 2>&1; echo "exit=$?")
    if [ -n "${CORPUS_VERBOSE:-}" ]; then
        echo "--- $name under $lua:"; echo "$ref" | head -5; echo "..."; echo "$ref" | tail -3
    fi
    if [ "$(echo "$ref" | normalize | bash -c "$filter")" = "$(echo "$out" | normalize | bash -c "$filter")" ]; then
        echo "ok   $name ($(echo "$ref" | tail -1), $(echo "$ref" | wc -l) lines)"
        pass=$((pass + 1))
    else
        echo "FAIL $name"
        diff <(echo "$ref" | normalize) <(echo "$out" | normalize) | head -20 | sed 's/^/    /'
        fail=$((fail + 1))
    fi
done
echo
echo "corpus: $pass passed, $fail failed, $skip skipped (reference: $("$lua" -v 2>&1))"
[ "$fail" -eq 0 ]
