#!/usr/bin/env bash
# Command-line tests: each invocation of prolua is run in a scratch directory
# and its combined stdout and stderr plus "exit=<status>" is compared with the
# expectation written below it. There is no reference interpreter any more:
# the interface is prolua's own (docs/project/project.md Part 3), so its
# behaviour is pinned here, case by case.
#
#   test/cli/clitest.sh              run every case
#   PROLUA=path test/cli/clitest.sh  test another binary
#   CLITEST_SHOW=1 ...               print the actual output of every case
#   PROLUA_WRAPPER="valgrind -q --error-exitcode=99" ...
#                                    run every invocation under a wrapper (a
#                                    memory checker); its complaints land in
#                                    the output and fail the case
#   CLITEST_TIMEOUT=120 ...          seconds per invocation (default 20)
# A case may set PRE="cmd args" to run its invocation under a prefix of its
# own (test/cli/limitmem.sh for a memory limit), and BIN=path to run another
# binary: the memory cases use the ReleaseSafe build named by PROLUA_SAFE
# when the build passes one (the Debug build's checking allocator makes
# millions of allocations take minutes).
#
# Output is normalized before comparison: the binary's absolute path (which
# reaches scripts through arg) becomes "prolua", and version numbers become
# "<version>".

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
prolua="$(realpath -m "${PROLUA:-$root/zig-out/bin/prolua}")"

if [ ! -x "$prolua" ]; then
    echo "prolua not built at $prolua (run 'zig build')" >&2
    exit 1
fi
# shellcheck disable=SC2206
wrapper=(${PROLUA_WRAPPER:-})
if [ "${#wrapper[@]}" -gt 0 ] && ! command -v "${wrapper[0]}" >/dev/null 2>&1; then
    echo "wrapper '${wrapper[0]}' not found; skipping"
    exit 0
fi
per_case="${CLITEST_TIMEOUT:-20}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
mkdir home
export HOME="$work/home"

pass=0
fail=0
failed=()

normalize() {
    sed -e "s#$prolua#prolua#g" \
        -e 's/^Prolua [0-9][0-9.]*$/Prolua <version>/' \
        -e 's/^prolua = ">=[0-9][0-9.]*"$/prolua = ">=<version>"/' \
        -e "s#$work#<work>#g" \
        -e 's/ *[0-9][0-9]*\.[0-9][0-9]*s/ T/g' \
        -e 's/ *[0-9][0-9]*\.[0-9][0-9]*x/ R/g' \
        -e 's/\b0x[0-9a-f]*/ADDR/g' \
        -e 's/h1:[A-Za-z0-9+\/=][A-Za-z0-9+\/=]*/h1:HASH/g'
}

# expect NAME [args...] <<'EOF' ... EOF
# The expectation is read from standard input; the invocation's own standard
# input is the file named by IN (default: nothing), and its working directory
# is DIR (default: the scratch directory).
expect() {
    local name="$1"
    shift
    local expected actual input="${IN:-/dev/null}" dir="${DIR:-$work}"
    expected="$(cat)"
    # shellcheck disable=SC2206
    local pre=(${PRE:-})
    local bin="${BIN:-$prolua}"
    actual="$( { cd "$dir" && timeout "$per_case" "${pre[@]}" "${wrapper[@]}" "$bin" "$@" 2>&1 <"$input"; echo "exit=$?"; } | normalize | sed -e "s#$bin#prolua#g")"
    if [ -n "${CLITEST_SHOW:-}" ]; then
        echo "=== $name"; echo "$actual"
    fi
    if [ "$expected" == "$actual" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        failed+=("$name")
        echo "=== FAIL: $name"
        diff <(echo "$expected") <(echo "$actual") | head -20 | sed 's/^/    /'
    fi
}

# --- fixtures ---------------------------------------------------------------
printf 'print(#arg, arg[0], arg[1], arg[2], arg[-1], arg[-2], arg[-3], ...)\n' > args.lua
printf 'local function f() error("top") end\nf()\n' > err.lua
printf 'error({code = 1})\n' > errtab.lua
printf 'error(setmetatable({}, {__tostring = function() return "custom" end}))\n' > errts.lua
printf 'error(42)\n' > errnum.lua
printf 'os.exit(3)\n' > exit3.lua
printf 'os.exit(false)\n' > exitf.lua
printf 'os.exit(true)\n' > exitt.lua
printf 'return 1, 2\n' > ret.lua
printf 'x = \n' > syntax.lua
printf 'warn("hello ", "world")\nwarn("@on")\nwarn("now on")\nwarn("@off")\nwarn("off again")\n' > warn.lua
printf 'local M = {} M.v = 42 return M\n' > mymod.lua
printf 'print("init file")\n' > initf.lua
printf 'local t = nil\nreturn t.x\n' > runtime.lua
printf 'print(select(2, xpcall(function() local t = nil; return t.x end, debug.traceback)))\n' > tb.lua
printf 'print("piped", 1 + 1, ...)\n' > stdin_script.lua
printf 'x=1\nx+1\nfunction f()\nreturn 2, "s"\nend\nf()\nerror("e")\nnil\nprint("p")\n1 +\n2\n=x\nlocal a <const> = 3; a = 4\n"unfinished\n\n{1,2,\n3}\nfor i = 1, 2 do\nprint(i)\nend\nreturn 1, 2\n' > repl_session.txt
printf '1+1' > repl_no_newline.txt

# --- the usage texts, for the cases that print them ------------------------
general_usage=$(cat <<'EOF'
Usage: prolua [command] [options]

Commands:
  run [flags] <target> [args...]   run a .lua file, a project directory, or - (stdin)
  eval [--print] <code> [args...]  run code given on the command line
  init [module path]               create a project in this directory
  disasm <file>...                 list the bytecode of each file (luac -l -l -p format)
  bench [flags] [name...]          time benchmark scripts against the reference lua
  test [name...]                   run the project's tests (tests/*_test.lua)
  add <module>[@ver] [--path dir]  declare a dependency in module.toml and install it
  remove <module>                  drop a dependency and install
  update [module...]               move dependencies to their latest release and install
  install [--frozen]               fetch the dependencies into the cache, write module.sum
  vendor                           copy the dependencies into vendor/ and use them from there
  verify                           check cached and vendored modules against module.sum
  tree                             show the dependency graph and where each module is
  why <module>                     show every chain of dependencies that brings a module in
  clean                            remove the module cache

Options:
  -v, --version                    print the version
  -h, --help                       print this help; `prolua <command> --help` for a command's

With no command, prolua starts the REPL on a terminal and runs standard input otherwise.
EOF
)
run_usage=$(cat <<'EOF'
Usage: prolua run [flags] <target> [args...]

<target> is a .lua file, a project directory (its src/main.lua runs), or -
for standard input. Inside a project, <target> may be omitted and the
project's src/main.lua runs. Everything after <target> becomes arg[1],
arg[2], ... in the script; <target> is arg[0].

Flags (before the target):
  -e, --eval <code>           run <code> before the target (repeatable, in order)
  -l, --lib <name[=global]>   require <name> into a global (repeatable)
  -i, --interactive           enter the REPL after the target
  -W, --warn                  turn warnings on
  -E, --no-env                ignore LUA_INIT, LUA_PATH and LUA_CPATH
  --                          end of flags; the next word is the target
EOF
)
disasm_usage=$(cat <<'EOF'
Usage: prolua disasm <file>...

Compiles each file (source or precompiled) and lists its functions in
the format of `luac -l -l -p`: header, instructions, constants, locals
and upvalues. `--` ends the flags, for a file whose name starts with -.
EOF
)
bench_usage=$(cat <<'EOF'
Usage: prolua bench [flags] [name...]

Runs each <name>.lua of the benchmark directory (every script when no
name is given) as a whole process under this interpreter and under the
reference lua, and prints the best time of the runs and the ratio.

Flags:
  --dir <directory>   the scripts (default: test/bench)
  --runs <n>          runs per script, best one counts (default: 3)
  --lua <path>        the reference interpreter (default: lua on PATH)
  --no-lua            time this interpreter alone
EOF
)
test_usage=$(cat <<'EOF'
Usage: prolua test [name...]

Runs the project's tests: every tests/<name>_test.lua, or those named.
Each file runs in its own state, with this project's modules resolving
and tests/ on package.path for shared helpers; it passes when it
returns without an error. Exit status 1 when any file failed.
EOF
)
add_usage=$(cat <<'EOF'
Usage: prolua add <module>[@<version>|@latest] [--path <dir>]

Declares <module> in [dependencies] of this project's module.toml at
<version> (vMAJOR.MINOR.PATCH), or at the highest release its source
has a tag for (@latest, the default), then runs install. With --path,
the checkout at <dir> provides the module (its module.toml must name
it), is recorded as [replacements."<module>"] path = "...", and
supplies the default version.
EOF
)
remove_usage=$(cat <<'EOF'
Usage: prolua remove <module>

Drops <module> from [dependencies] of this project's module.toml and
runs install, so [indirectDependencies] and module.sum shrink to what
the graph still needs. A [replacements] entry for it is kept.
EOF
)
update_usage=$(cat <<'EOF'
Usage: prolua update [module...]

Moves every direct dependency (or the named ones) to the highest
release its source has a tag for, then runs install. Replaced and
vendored modules have no source to ask and are left as they are.
EOF
)
tree_usage=$(cat <<'EOF'
Usage: prolua tree

Prints this project's dependency graph: each module's declared
dependencies with their versions and where each is placed (a
replacement, vendor/, the cache), marking modules nothing places as
missing. Exit status 1 when any is missing.
EOF
)
install_usage=$(cat <<'EOF'
Usage: prolua install [--frozen]

Makes every module this project depends on available: walks the graph
from module.toml selecting the highest version anyone asks for, fetches
into the cache (through git) what no replacement or vendor/ provides,
checks each cached tree against module.sum and records new ones, then
writes [indirectDependencies] and bumps a direct dependency whose
selected version rose. Sources: github.com, gitlab.com, codeberg.org,
and PROLUA_SOURCES=host=url-prefix[;...] for others.

  --frozen   fail instead of changing module.toml or module.sum (for CI)
EOF
)
vendor_usage=$(cat <<'EOF'
Usage: prolua vendor

Copies every module this project depends on into vendor/<module path>/
and writes vendor/modules.toml, resolving and fetching as install does
first. From then on modules load from vendor/ only, and changing the
dependencies without running prolua vendor again is an error.
EOF
)
verify_usage=$(cat <<'EOF'
Usage: prolua verify

Hashes every module.sum entry that is in the cache and every module in
vendor/ again and compares them with what module.sum and
vendor/modules.toml record; also checks that vendor/ matches the
current module.toml and module.sum. Exit status 1 on any mismatch.
EOF
)
why_usage=$(cat <<'EOF'
Usage: prolua why <module>

Prints every chain of declared dependencies from this project down to
<module>, one tree per chain, so a module in the graph can be traced
to the direct dependency that brings it in. Exit status 1 when the
module is not in the graph.
EOF
)
clean_usage=$(cat <<'EOF'
Usage: prolua clean

Removes the module cache ($PROLUA_CACHE, $XDG_CACHE_HOME/prolua or
~/.cache/prolua, its modules/ directory); the next install or run
fetches again. A project's vendor/ is not touched.
EOF
)
eval_usage=$(cat <<'EOF'
Usage: prolua eval [--print] <code> [args...]

Runs <code> as a Lua chunk, with this project's modules resolving when
the working directory is in one. Everything after <code> is arg[1],
arg[2], ... With --print (-p), <code> is an expression list and its
values are printed. `--` ends the flags, for code starting with -.
EOF
)
init_usage=$(cat <<'EOF'
Usage: prolua init [module path]

Creates module.toml and src/main.lua in the current directory. The module
path is the argument when given, otherwise the directory's name. A path
whose first component is a DNS name (github.com/matt-dunleavy/http) is a
namespace path; a bare name (myapp) is a local module.
EOF
)

# --- the top level ----------------------------------------------------------
expect "version" --version <<'EOF'
Prolua <version>
Copyright (C) 2024-2026 Matt Dunleavy
exit=0
EOF
expect "version short" -v <<'EOF'
Prolua <version>
Copyright (C) 2024-2026 Matt Dunleavy
exit=0
EOF
expect "help" --help <<EOF
$general_usage
exit=0
EOF
expect "help for a command" help run <<EOF
$run_usage
exit=0
EOF
expect "unknown command" frobnicate <<EOF
prolua: unknown command 'frobnicate'
$general_usage
exit=2
EOF
expect "a script without run gets a hint" args.lua <<EOF
prolua: unknown command 'args.lua' (to run a script: prolua run args.lua)
$general_usage
exit=2
EOF
expect "old option without run" -e 'print(1)' <<EOF
prolua: unknown option '-e'
$general_usage
exit=2
EOF
IN=stdin_script.lua expect "no command, piped input runs as a script" <<'EOF'
piped	2
exit=0
EOF

# --- run: flags -------------------------------------------------------------
expect "e" run -e 'print(1 + 1)' <<'EOF'
2
exit=0
EOF
expect "e twice, in order" run -e 'x = 5' --eval 'print(x)' <<'EOF'
5
exit=0
EOF
expect "e error" run -e 'error("x")' <<'EOF'
prolua: (command line):1: x
stack traceback:
	[C]: in function 'error'
	(command line):1: in main chunk
	[C]: in ?
exit=1
EOF
expect "e syntax" run -e 'x =' <<'EOF'
prolua: (command line):1: unexpected symbol near <eof>
exit=1
EOF
expect "e needs an argument" run -e <<EOF
prolua: '-e' needs an argument
$run_usage
exit=2
EOF
expect "unknown flag" run --bogus args.lua <<EOF
prolua: unknown flag '--bogus' for run
$run_usage
exit=2
EOF
expect "l module" run -l mymod -e 'print(mymod.v)' <<'EOF'
42
exit=0
EOF
expect "l module renamed" run -l m=mymod -e 'print(m.v)' <<'EOF'
42
exit=0
EOF
expect "l missing module" run -l nosuchmod -e 'print("not reached")' <<'EOF'
prolua: module 'nosuchmod' not found:
	no field package.preload['nosuchmod']
	no file '/usr/local/share/lua/5.4/nosuchmod.lua'
	no file '/usr/local/share/lua/5.4/nosuchmod/init.lua'
	no file '/usr/local/lib/lua/5.4/nosuchmod.lua'
	no file '/usr/local/lib/lua/5.4/nosuchmod/init.lua'
	no file './nosuchmod.lua'
	no file './nosuchmod/init.lua'
	no file ''
stack traceback:
	[C]: in function 'require'
	[C]: in ?
exit=1
EOF
expect "W enables warn" run -W warn.lua <<'EOF'
Lua warning: hello world
Lua warning: now on
exit=0
EOF
expect "warn default off" run warn.lua <<'EOF'
Lua warning: now on
exit=0
EOF
expect "nothing to run" run <<'EOF'
prolua: nothing to run: give a .lua file, a project directory, or run inside a project (prolua run --help)
exit=2
EOF

# --- run: scripts and the arg table -----------------------------------------
expect "script args" run args.lua a b <<'EOF'
2	args.lua	a	b	run	prolua	nil	a	b
exit=0
EOF
expect "flags before the script land at negative indices" run -e 'y = 1' args.lua a <<'EOF'
1	args.lua	a	nil	y = 1	-e	run	a
exit=0
EOF
expect "double dash then script" run -- args.lua -x <<'EOF'
1	args.lua	-x	nil	--	run	prolua	-x
exit=0
EOF
expect "script return values ignored" run ret.lua <<'EOF'
exit=0
EOF
expect "missing script" run nope.lua <<'EOF'
prolua: cannot open nope.lua: FileNotFound
exit=1
EOF
expect "syntax error in script" run syntax.lua <<'EOF'
prolua: syntax.lua:2: unexpected symbol near <eof>
exit=1
EOF
expect "uncaught error traceback" run err.lua <<'EOF'
prolua: err.lua:1: top
stack traceback:
	[C]: in function 'error'
	err.lua:1: in local 'f'
	err.lua:2: in main chunk
	[C]: in ?
exit=1
EOF
expect "runtime error traceback" run runtime.lua <<'EOF'
prolua: runtime.lua:2: attempt to index a nil value (local 't')
stack traceback:
	runtime.lua:2: in main chunk
	[C]: in ?
exit=1
EOF
expect "error object table" run errtab.lua <<'EOF'
prolua: (error object is a table value)
stack traceback:
	[C]: in function 'error'
	errtab.lua:1: in main chunk
	[C]: in ?
exit=1
EOF
expect "error object with __tostring" run errts.lua <<'EOF'
prolua: custom
exit=1
EOF
expect "error object number" run errnum.lua <<'EOF'
prolua: 42
stack traceback:
	[C]: in function 'error'
	errnum.lua:1: in main chunk
	[C]: in ?
exit=1
EOF
expect "traceback from xpcall" run tb.lua <<'EOF'
tb.lua:1: attempt to index a nil value (local 't')
stack traceback:
	tb.lua:1: in function <tb.lua:1>
	[C]: in function 'xpcall'
	tb.lua:1: in main chunk
	[C]: in ?
exit=0
EOF
expect "os.exit code" run exit3.lua <<'EOF'
exit=3
EOF
expect "os.exit false" run exitf.lua <<'EOF'
exit=1
EOF
expect "os.exit true" run exitt.lua <<'EOF'
exit=0
EOF
expect "os.exit flushes open files" run -e 'io.open("flushed.txt", "w"):write("kept") os.exit(0)' <<'EOF'
exit=0
EOF
expect "and the file is complete" run -e 'print(io.open("flushed.txt"):read("a"))' <<'EOF'
kept
exit=0
EOF

# --- eval -------------------------------------------------------------------
expect "eval runs code" eval 'print("hi", ...)' a b <<'EOF'
hi	a	b
exit=0
EOF
expect "eval --print prints an expression list" eval -p '1 + 1, "two", nil' <<'EOF'
2	two	nil
exit=0
EOF
expect "eval --print of a statement" eval -p 'x = 1' <<'EOF'
prolua: (command line):1: <eof> expected near '='
exit=1
EOF
expect "eval error" eval 'error("boom")' <<'EOF'
prolua: (command line):1: boom
stack traceback:
	[C]: in function 'error'
	(command line):1: in main chunk
	[C]: in ?
exit=1
EOF
expect "eval's arg table" eval 'print(arg[0], arg[-1], arg[-2], arg[1])' z <<'EOF'
(command line)	eval	prolua	z
exit=0
EOF
expect "eval with code starting with a dash" eval -p -- '-1' <<'EOF'
-1
exit=0
EOF
expect "eval needs code" eval <<EOF
prolua: eval needs the code to run
$eval_usage
exit=2
EOF

# --- run: stdin -------------------------------------------------------------
IN=stdin_script.lua expect "dash is stdin" run - <<'EOF'
piped	2
exit=0
EOF
IN=stdin_script.lua expect "dash with args" run - x y <<'EOF'
piped	2	x	y
exit=0
EOF

# --- Ctrl-C ------------------------------------------------------------------
# A first interrupt stops the running chunk with an error at its next
# instruction; a second one, while it runs again, ends the process
if [ "$(uname -s)" != Windows_NT ]; then
    interrupt_case() {
        local name="$1" code="$2" expected="$3" signals="$4"
        local actual out rc
        # exec, so the signal reaches the interpreter itself; a watchdog for a run that ignores it
        ( cd "$work" && exec "$prolua" run -e "$code" - </dev/null ) >"$work/int.out" 2>&1 &
        local pid=$!
        ( sleep 20; kill -KILL "$pid" 2>/dev/null ) &
        local watchdog=$!
        sleep 0.5
        local i
        for ((i = 0; i < signals; i++)); do kill -INT "$pid"; sleep 0.3; done
        wait "$pid"; rc=$?
        kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
        actual="$( { cat "$work/int.out"; echo "exit=$rc"; } | normalize)"
        if [ "$expected" == "$actual" ]; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1)); failed+=("$name"); echo "=== FAIL: $name"
            diff <(echo "$expected") <(echo "$actual") | head -20 | sed 's/^/    /'
        fi
    }
    interrupt_case "Ctrl-C interrupts a running chunk" 'while true do end' 'prolua: interrupted!
stack traceback:
	(command line):1: in main chunk
	[C]: in ?
exit=1' 1
    interrupt_case "a chunk may catch the interruption; a second Ctrl-C ends the process" 'while true do local ok, e = pcall(function() while true do end end) io.stderr:write("caught ", e, "\n") end' 'caught interrupted!
exit=130' 2
fi

# --- running out of memory --------------------------------------------------
# Under an address-space limit (not under a memory checker, which needs the
# space itself): a failed allocation is a catchable "not enough memory",
# the message survives the moment there is no memory to make one, and
# garbage is collected before the failure is reported at all
if [ -z "${PROLUA_WRAPPER:-}" ] && [ "$(uname -s)" = Linux ]; then
    limit="bash $root/test/cli/limitmem.sh 120000"   # 120 MB: the Debug build must fail within seconds
    membin="${PROLUA_SAFE:-$prolua}"
    PRE="$limit" BIN="$membin" expect "a memory error inside xpcall does not run the handler, as in the reference" run -e 'collectgarbage("stop") local t = {} print(xpcall(function() for i = 1, 1e9 do t[i] = {i} end end, function(e) return "handler: " .. tostring(e) end))' - <<'EOF'
false	not enough memory
exit=0
EOF
    PRE="$limit" BIN="$membin" expect "running out while filling a table: caught, reported, the work kept" run -e 'local t = {} local ok, e = pcall(function() for i = 1, 1e9 do t[i] = {i} end end) print(ok, e, #t > 0)' - <<'EOF'
false	not enough memory	true
exit=0
EOF
    PRE="$limit" BIN="$membin" expect "an uncaught memory error is reported by name" run -e 'local t = {} for i = 1, 1e9 do t[i] = {i} end' - <<'EOF'
prolua: not enough memory
exit=1
EOF
    if [ -n "${PROLUA_SAFE:-}" ]; then
        # only on a malloc-backed build: the Debug allocator keeps freed pages, so the loop never gets its memory back
        PRE="$limit" BIN="$membin" expect "garbage is collected before an allocation fails, even with the collector stopped" run -e 'collectgarbage("stop") for i = 1, 2e6 do local t = { i, i, i, i, i, i, i, i } end print("done", collectgarbage("count") < 100 * 1024)' - <<'EOF'
done	true
exit=0
EOF
    fi
fi

# --- run: the environment ---------------------------------------------------
LUA_INIT='print("init")' expect "LUA_INIT string" run -e 'print("e")' <<'EOF'
init
e
exit=0
EOF
LUA_INIT='@initf.lua' expect "LUA_INIT file" run -e 'print("e")' <<'EOF'
init file
e
exit=0
EOF
LUA_INIT='print("init")' expect "no-env ignores LUA_INIT" run --no-env -e 'print("e")' <<'EOF'
e
exit=0
EOF
LUA_INIT='print("init")' expect "E ignores LUA_INIT" run -E -e 'print("e")' <<'EOF'
e
exit=0
EOF

# --- run: projects ----------------------------------------------------------
mkdir -p proj/src proj/deep/er
printf 'schema = 1\nmodule = "example.com/proj"\n' > proj/module.toml
printf 'print("main of", #arg, arg[0]:match("[^/]*/[^/]*/[^/]*$"), ...)\n' > proj/src/main.lua
expect "run a project directory" run proj a <<'EOF'
main of	1	proj/src/main.lua	a
exit=0
EOF
DIR="$work/proj" expect "run inside a project" run <<'EOF'
main of	0	proj/src/main.lua
exit=0
EOF
DIR="$work/proj/deep/er" expect "run inside a project, walking up" run <<'EOF'
main of	0	proj/src/main.lua
exit=0
EOF
DIR="$work/proj" expect "a file inside a project is just a file" run ../args.lua <<'EOF'
0	../args.lua	nil	nil	run	prolua	nil
exit=0
EOF
mkdir nomanifest
expect "a directory without a manifest" run nomanifest <<'EOF'
prolua: no module.toml in nomanifest
exit=1
EOF
mkdir -p badproj
printf 'schema = 1\nmodule = 3\n' > badproj/module.toml
expect "a bad manifest" run badproj <<'EOF'
badproj/module.toml: 'module' must be a string
exit=1
EOF
mkdir -p noentry
printf 'schema = 1\nmodule = "noentry"\n' > noentry/module.toml
expect "a project without src/main.lua" run noentry <<'EOF'
prolua: noentry has no src/main.lua, the entry point of a program (prolua run <file.lua> runs a file)
exit=1
EOF
mkdir -p lib/src
printf 'schema = 1\nmodule = "github.com/matt-dunleavy/lib"\n' > lib/module.toml
printf 'return {}\n' > lib/src/init.lua
expect "a library is not a program" run lib <<'EOF'
prolua: github.com/matt-dunleavy/lib is a library, not a program: it has src/init.lua and no src/main.lua to run (prolua run <file.lua> runs a file)
exit=1
EOF
DIR="$work/lib" expect "run inside a library" run <<'EOF'
prolua: github.com/matt-dunleavy/lib is a library, not a program: it has src/init.lua and no src/main.lua to run (prolua run <file.lua> runs a file)
exit=1
EOF
DIR="$work/lib" expect "a file inside a library still runs" run src/init.lua <<'EOF'
exit=0
EOF

# --- the module searcher ----------------------------------------------------
# The fixtures under mods/ are shared by the searcher, tree, add, vendor,
# verify, why and clean groups, in that order, and some cases change them
# (add writes addapp's manifest; vendor creates addapp/vendor; verify
# tampers and restores). A case that needs a state must come after the
# case that makes it; a group that must destroy state works on a copy
# (clean uses mods/cache2).

# A main module `app` with its own subpackage, a replacement to a sibling
# checkout `one` (which has an internal package and its own dependency),
# a vendored module `two`, and modules `three` and `four` in a cache named
# by PROLUA_CACHE.
mkdir -p mods/app/src/util mods/app/vendor/example.com/lib/two/src mods/one/src/internal mods/one/src/sub \
    mods/cache/modules/example.com/lib/three/v1.0.0/src mods/cache/modules/example.com/lib/four/v2.0.0/src
cat > mods/app/module.toml <<'TOML'
schema = 1
module = "example.com/me/app"

[dependencies]
"example.com/lib/one" = "v0.1.0"
"example.com/lib/three" = "v1.0.0"
"example.com/lib/five" = "v9.9.9"

[replacements."example.com/lib/one"]
path = "../one"
TOML
printf 'return { name = "util" }\n' > mods/app/src/util.lua
printf 'return { name = "util.deep" }\n' > mods/app/src/util/deep.lua
printf 'schema = 1\nmodule = "example.com/lib/one"\n[dependencies]\n"example.com/lib/four" = "v2.0.0"\n' > mods/one/module.toml
printf 'local i = require "example.com/lib/one/internal"\nlocal four = require "example.com/lib/four"\nreturn { name = "one", secret = i.secret, four = four.name, sub = require("example.com/lib/one/sub").name }\n' > mods/one/src/init.lua
printf 'return { secret = 42 }\n' > mods/one/src/internal/init.lua
printf 'return { name = "one.sub" }\n' > mods/one/src/sub/init.lua
printf 'schema = 1\nmodule = "example.com/lib/two"\n' > mods/app/vendor/example.com/lib/two/module.toml
printf 'return { name = "two" }\n' > mods/app/vendor/example.com/lib/two/src/init.lua
printf 'schema = 1\nmodule = "example.com/lib/three"\n' > mods/cache/modules/example.com/lib/three/v1.0.0/module.toml
printf 'return { name = "three" }\n' > mods/cache/modules/example.com/lib/three/v1.0.0/src/init.lua
printf 'schema = 1\nmodule = "example.com/lib/four"\n' > mods/cache/modules/example.com/lib/four/v2.0.0/module.toml
printf 'return { name = "four" }\n' > mods/cache/modules/example.com/lib/four/v2.0.0/src/init.lua
cat > mods/app/src/main.lua <<'LUA'
local util = require "example.com/me/app/util"
local deep = require "example.com/me/app/util/deep"
local one = require "example.com/lib/one"
local two = require "example.com/lib/two"
local three = require "example.com/lib/three"
print(util.name, deep.name, one.name, one.secret, one.four, one.sub, two.name, three.name)
print(package.loaded["example.com/lib/one"] == one)
LUA
export PROLUA_CACHE="$work/mods/cache"
DIR="$work/mods/app" expect "module paths resolve: own package, replacement, vendor, cache, transitive" run <<'EOF'
util	util.deep	one	42	four	one.sub	two	three
true
exit=0
EOF
expect "the same from outside, by directory" run mods/app <<'EOF'
util	util.deep	one	42	four	one.sub	two	three
true
exit=0
EOF
expect "a file's project is the one above it" run mods/app/src/main.lua <<'EOF'
util	util.deep	one	42	four	one.sub	two	three
true
exit=0
EOF
DIR="$work/mods/app" expect "internal refused, message" run -e 'local ok, e = pcall(require, "example.com/lib/one/internal") print(ok) print(e:match("\n\t(.example.-require it)"))' - <<'EOF'
false
'example.com/lib/one/internal' is internal to module example.com/lib/one: only its own files may require it
exit=0
EOF
DIR="$work/mods/app" expect "an undeclared module" run -e 'local ok, e = pcall(require, "example.com/lib/none") print(e:match("\n\t(no module.-)\n\tno file"))' - <<'EOF'
no module provides 'example.com/lib/none'
	(main module example.com/me/app at <work>/mods/app: no [replacements] entry, not in vendor/)
exit=0
EOF
DIR="$work/mods/app" expect "a declared module missing from the cache" run -e 'local ok, e = pcall(require, "example.com/lib/five") print(e:match("\n\t(no module.-)\n\tno file"))' - <<'EOF'
no module provides 'example.com/lib/five'
	(main module example.com/me/app at <work>/mods/app: no [replacements] entry, not in vendor/, example.com/lib/five v9.9.9 is declared but not in the cache at <work>/mods/cache/modules/example.com/lib/five/v9.9.9 (run prolua install; or vendor it, or point [replacements."example.com/lib/five"] path = "..." at a checkout))
exit=0
EOF
DIR="$work/mods/app" expect "a module without the package" run -e 'local ok, e = pcall(require, "example.com/lib/two/nope") print(e:match("\n\t(module example.-nope%.lua.)"))' - <<'EOF'
module example.com/lib/two at <work>/mods/app/vendor/example.com/lib/two has no package 'nope'
	no file '<work>/mods/app/vendor/example.com/lib/two/src/nope/init.lua'
	no file '<work>/mods/app/vendor/example.com/lib/two/src/nope.lua'
exit=0
EOF
DIR="$work/mods/app" expect "an invalid module path" run -e 'local ok, e = pcall(require, "example.com/Bad") print(e:match("\n\t(invalid.-)\n\tno file"))' - <<'EOF'
invalid module path 'example.com/Bad': components may only contain a-z, 0-9 and '-' (the first may contain '.')
exit=0
EOF
expect "outside a project" run -e 'local ok, e = pcall(require, "example.com/lib/one") print(e:match("\n\t(no module.-)\n\tno file"))' <<'EOF'
no module provides 'example.com/lib/one'
	(not inside a project: no module.toml in <work> or above it; prolua init creates one)
exit=0
EOF
printf 'local M = {} M.v = 42 return M\n' > mods/app/mymod.lua
DIR="$work/mods/app" expect "plain names still use package.path" run -e 'print(require("mymod").v)' - <<'EOF'
42
exit=0
EOF
printf 'print(require("example.com/lib/three").name)\n' > mods/piped.lua
DIR="$work/mods/app" IN="$work/mods/piped.lua" expect "piped input with no command resolves through the working directory's project" <<'EOF'
three
exit=0
EOF
DIR="$work/mods/one" expect "-e inside a library runs the eval alone" run -e 'print(require("example.com/lib/one").name)' <<'EOF'
one
exit=0
EOF
unset PROLUA_CACHE

# --- test -------------------------------------------------------------------
# The module fixture `app` gains tests: one passing (through the searcher
# and a shared helper), one failing, one that leaks a global that the next
# file must not see.
mkdir -p mods/app/tests
printf 'local T = {}\nfunction T.eq(a, b, what) if a ~= b then error(what .. ": got " .. tostring(a) .. ", want " .. tostring(b), 2) end end\nreturn T\n' > mods/app/tests/helper.lua
printf 'local T = require "helper"\nlocal one = require "example.com/lib/one"\nT.eq(one.four, "four", "transitive")\nT.eq(require("example.com/me/app/util").name, "util", "own package")\nprint("arg[0] is", arg[0])\nleaked = true\n' > mods/app/tests/one_test.lua
printf 'local T = require "helper"\nT.eq(leaked, nil, "fresh state")\nT.eq(1 + 1, 3, "arithmetic")\n' > mods/app/tests/two_test.lua
printf 'print("not a test: no _test suffix")\n' > mods/app/tests/notes.lua
export PROLUA_CACHE="$work/mods/cache"
DIR="$work/mods/app" expect "test runs each file in its own state and reports" test <<'EOF'
arg[0] is	tests/one_test.lua
ok    tests/one_test.lua
FAIL  tests/two_test.lua
      tests/two_test.lua:3: arithmetic: got 2, want 3
      stack traceback:
      	[C]: in function 'error'
      	tests/helper.lua:2: in function 'helper.eq'
      	tests/two_test.lua:3: in main chunk
1 passed, 1 failed
exit=1
EOF
DIR="$work/mods/app" expect "test by name" test one <<'EOF'
arg[0] is	tests/one_test.lua
ok    tests/one_test.lua
1 passed, 0 failed
exit=0
EOF
DIR="$work/mods/app/src" expect "test from a subdirectory names the root" test one <<'EOF'
arg[0] is	<work>/mods/app/tests/one_test.lua
ok    <work>/mods/app/tests/one_test.lua
1 passed, 0 failed
exit=0
EOF
DIR="$work/mods/app" expect "test of an unknown name" test three <<'EOF'
prolua: no test three: tests/three_test.lua does not exist
exit=1
EOF
DIR="$work/mods/one" expect "a project without tests" test <<'EOF'
prolua: no tests: . has no tests/ directory (tests are tests/<name>_test.lua)
exit=1
EOF
mkdir -p mods/app/vendor/example.com/lib/two/tests
DIR="$work/mods/app/vendor/example.com/lib/two" expect "a tests directory without test files" test <<'EOF'
prolua: no tests: tests has no *_test.lua files
exit=1
EOF
expect "test outside a project" test <<'EOF'
prolua: not inside a project: no module.toml in <work> or above it (prolua init creates one)
exit=1
EOF
expect "test takes no flags" test -v <<EOF
prolua: unknown flag '-v' for test
$test_usage
exit=2
EOF
expect "test help" test --help <<EOF
$test_usage
exit=0
EOF
unset PROLUA_CACHE

DIR="$work/mods/app" PROLUA_CACHE="$work/mods/cache" expect "eval resolves the project's modules" eval -p 'require("example.com/lib/three").name' <<'EOF'
three
exit=0
EOF

# --- tree and add -----------------------------------------------------------
export PROLUA_CACHE="$work/mods/cache"
DIR="$work/mods/app" expect "tree shows placement, transitive reach and missing modules" tree <<'EOF'
example.com/me/app - (.)
├── example.com/lib/one v0.1.0 (replaced by ../one)
│   └── example.com/lib/four v2.0.0 (cache, via this requirer: not in the project's [indirectDependencies])
├── example.com/lib/three v1.0.0 (cache)
└── example.com/lib/five v9.9.9 (missing)
1 missing: declared but nothing places them (run prolua install; or vendor, or [replacements] to a checkout)
exit=1
EOF
mkdir -p mods/addapp
DIR="$work/mods/addapp" expect "add: a project to add to" init example.com/me/addapp <<'EOF'
initialized module example.com/me/addapp
  module.toml
  src/main.lua
exit=0
EOF
DIR="$work/mods/addapp" expect "add with a checkout, then install through it" add example.com/lib/one@v0.1.0 --path ../one <<'EOF'
module.toml: added example.com/lib/one v0.1.0
  replaced by the checkout at ../one
replaced example.com/lib/one -> ../one
cached example.com/lib/four v2.0.0
module.toml: [indirectDependencies] 1 module
2 modules in the graph, 0 fetched; module.sum: 1 entry
exit=0
EOF
DIR="$work/mods/addapp" expect "add from the cache" add example.com/lib/three@v1.0.0 <<'EOF'
module.toml: added example.com/lib/three v1.0.0
cached example.com/lib/three v1.0.0
replaced example.com/lib/one -> ../one
cached example.com/lib/four v2.0.0
3 modules in the graph, 0 fetched; module.sum: 2 entries
exit=0
EOF
DIR="$work/mods/addapp" expect "add changes a version" add example.com/lib/one@v0.2.0 --path ../one <<'EOF'
module.toml: example.com/lib/one v0.1.0 -> v0.2.0
  replaced by the checkout at ../one
cached example.com/lib/three v1.0.0
replaced example.com/lib/one -> ../one
cached example.com/lib/four v2.0.0
3 modules in the graph, 0 fetched; module.sum: 2 entries
exit=0
EOF
DIR="$work/mods/addapp" expect "the manifest after add" run -e 'io.write(io.open("module.toml"):read("a"))' - <<'EOF'
schema = 1
module = "example.com/me/addapp"
version = "v0.1.0"
prolua = ">=<version>"

[dependencies]
"example.com/lib/one" = "v0.2.0"
"example.com/lib/three" = "v1.0.0"

[replacements."example.com/lib/one"]
path = "../one"

[indirectDependencies]
"example.com/lib/four" = "v2.0.0"
exit=0
EOF
DIR="$work/mods/addapp" expect "tree after add" tree <<'EOF'
example.com/me/addapp v0.1.0 (.)
├── example.com/lib/one v0.2.0 (replaced by ../one)
│   └── example.com/lib/four v2.0.0 (cache)
└── example.com/lib/three v1.0.0 (cache)
exit=0
EOF
DIR="$work/mods/addapp/src" expect "add from a subdirectory records the path from the root" add example.com/lib/two@v0.1.0 --path ../../app/vendor/example.com/lib/two <<'EOF'
module.toml: added example.com/lib/two v0.1.0
  replaced by the checkout at ../app/vendor/example.com/lib/two
replaced example.com/lib/two -> ../app/vendor/example.com/lib/two
cached example.com/lib/three v1.0.0
replaced example.com/lib/one -> ../one
cached example.com/lib/four v2.0.0
4 modules in the graph, 0 fetched; module.sum: 2 entries
exit=0
EOF
DIR="$work/mods/addapp" expect "add of a module with no source" add example.com/lib/six <<'EOF'
prolua: example.com/lib/six: no source for host 'example.com' (github.com, gitlab.com and codeberg.org are built in; PROLUA_SOURCES=host=url names another; DNS discovery is not implemented yet); give --path <checkout> or vendor it
exit=1
EOF
DIR="$work/mods/addapp" expect "add with a checkout of another module" add example.com/lib/six@v1.0.0 --path ../one <<'EOF'
prolua: ../one/module.toml declares module example.com/lib/one, not example.com/lib/six
exit=1
EOF
DIR="$work/mods/addapp" expect "add with a path that is not a module" add example.com/lib/six@v1.0.0 --path ../cache <<'EOF'
prolua: ../cache has no valid module.toml: --path names a module's checkout
exit=1
EOF
DIR="$work/mods/addapp" expect "add of a checkout without a version" add example.com/lib/one --path ../one <<'EOF'
prolua: ../one/module.toml has no version: give one, as in example.com/lib/one@v0.1.0
exit=1
EOF
DIR="$work/mods/addapp" expect "add of the project itself" add example.com/me/addapp@v1.0.0 <<'EOF'
prolua: example.com/me/addapp is this project's own module
exit=1
EOF
DIR="$work/mods/addapp" expect "add of a plain name" add json@v1.0.0 <<'EOF'
prolua: 'json' is not a module path: the first component is a host, as in github.com/matt-dunleavy/json
exit=1
EOF
DIR="$work/mods/addapp" expect "add with a bad version" add example.com/lib/one@1.0 <<'EOF'
prolua: '1.0' is not a version: vMAJOR.MINOR.PATCH, or latest, as in example.com/lib/one@v1.0.0
exit=1
EOF
expect "add outside a project" add example.com/lib/one@v1.0.0 <<'EOF'
prolua: not inside a project: no module.toml in <work> or above it (prolua init creates one)
exit=1
EOF
expect "tree outside a project" tree <<'EOF'
prolua: not inside a project: no module.toml in <work> or above it (prolua init creates one)
exit=1
EOF
expect "add needs a module" add <<EOF
prolua: add needs a module path
$add_usage
exit=2
EOF
expect "tree takes no arguments" tree x <<EOF
prolua: tree takes no arguments
$tree_usage
exit=2
EOF
unset PROLUA_CACHE

# --- install ----------------------------------------------------------------
# A local forge: two module repositories under example.com, reached through
# PROLUA_SOURCES; `two` has two tagged versions and `one` requires the
# higher one. Needs git; skipped without it.
expect "install outside a project" install <<'EOF'
prolua: not inside a project: no module.toml in <work> or above it (prolua init creates one)
exit=1
EOF
expect "install takes no arguments" install x <<EOF
prolua: install takes no arguments
$install_usage
exit=2
EOF
if command -v git >/dev/null 2>&1; then
    gitc() { git -c user.name=t -c user.email=t@t "$@"; }
    mkdir -p forge/lib/two.git/src forge/lib/one.git/src inst/app/src inst/cache
    ( cd forge/lib/two.git \
      && printf 'schema = 1\nmodule = "example.com/lib/two"\nversion = "v0.1.0"\n' > module.toml \
      && printf 'return { name = "two", v = 3 }\n' > src/init.lua \
      && git init -q && git add -A && gitc commit -qm v0.1.0 && git tag v0.1.0 \
      && sed -i 's/v0.1.0/v0.4.0/' module.toml && printf 'return { name = "two", v = 4 }\n' > src/init.lua \
      && git add -A && gitc commit -qm v0.4.0 && git tag v0.4.0 )
    ( cd forge/lib/one.git \
      && printf 'schema = 1\nmodule = "example.com/lib/one"\nversion = "v0.1.0"\n\n[dependencies]\n"example.com/lib/two" = "v0.4.0"\n' > module.toml \
      && printf 'local two = require "example.com/lib/two"\nreturn { name = "one", two = two.v }\n' > src/init.lua \
      && git init -q && git add -A && gitc commit -qm v0.1.0 && git tag v0.1.0 )
    printf 'schema = 1\nmodule = "example.com/me/inst"\n\n[dependencies]\n"example.com/lib/one" = "v0.1.0"\n' > inst/app/module.toml
    printf 'local one = require "example.com/lib/one"\nprint(one.name, one.two, require("example.com/lib/two").v)\n' > inst/app/src/main.lua
    export PROLUA_CACHE="$work/inst/cache" PROLUA_SOURCES="example.com=file://$work/forge"
    DIR="$work/inst/app" expect "install fetches the graph and records it" install <<'EOF'
fetched example.com/lib/one v0.1.0 (file://<work>/forge/lib/one.git)
fetched example.com/lib/two v0.4.0 (file://<work>/forge/lib/two.git)
module.toml: [indirectDependencies] 1 module
2 modules in the graph, 2 fetched; module.sum: 2 entries
exit=0
EOF
    DIR="$work/inst/app" expect "the manifest after install" run -e 'io.write(io.open("module.toml"):read("a"))' - <<'EOF'
schema = 1
module = "example.com/me/inst"

[dependencies]
"example.com/lib/one" = "v0.1.0"

[indirectDependencies]
"example.com/lib/two" = "v0.4.0"
exit=0
EOF
    DIR="$work/inst/app" expect "module.sum after install" run -e 'for l in io.lines("module.sum") do print((l:gsub(" h1:.*$", " h1:HASH"))) end' - <<'EOF'
example.com/lib/one v0.1.0 h1:HASH
example.com/lib/two v0.4.0 h1:HASH
exit=0
EOF
    DIR="$work/inst/app" expect "the installed modules resolve" run <<'EOF'
one	4	4
exit=0
EOF
    DIR="$work/inst/app" expect "tree after install" tree <<'EOF'
example.com/me/inst - (.)
└── example.com/lib/one v0.1.0 (cache)
    └── example.com/lib/two v0.4.0 (cache)
exit=0
EOF
    DIR="$work/inst/app" expect "install again fetches nothing" install <<'EOF'
cached example.com/lib/one v0.1.0
cached example.com/lib/two v0.4.0
2 modules in the graph, 0 fetched; module.sum: 2 entries
exit=0
EOF
    printf '"example.com/lib/two" = "v0.1.0"\n' >> inst/app/module.toml   # into [indirectDependencies]: a stale, lower entry
    sed -i 's/"example.com\/lib\/two" = "v0.4.0"/"example.com\/lib\/two" = "v0.1.0"/' inst/app/module.toml
    DIR="$work/inst/app" expect "install replaces a stale indirect version" install <<'EOF'
cached example.com/lib/one v0.1.0
cached example.com/lib/two v0.4.0
module.toml: [indirectDependencies] 1 module
2 modules in the graph, 0 fetched; module.sum: 2 entries
exit=0
EOF
    echo "-- tampered" >> inst/cache/modules/example.com/lib/two/v0.4.0/src/init.lua
    DIR="$work/inst/app" expect "install refuses a cached tree that does not match module.sum" install <<'EOF'
cached example.com/lib/one v0.1.0
cached example.com/lib/two v0.4.0
prolua: integrity: example.com/lib/two v0.4.0 in the cache (<work>/inst/cache/modules/example.com/lib/two/v0.4.0) does not match module.sum
	recorded h1:HASH
	found    h1:HASH
	delete the cached copy to fetch it again, or remove the line if the change is yours
prolua: 1 module could not be installed; module.toml and module.sum left unchanged
exit=1
EOF
    rm -rf inst/cache/modules/example.com/lib/two/v0.4.0
    DIR="$work/inst/app" expect "install fetches a deleted cached module again, and it matches" install <<'EOF'
cached example.com/lib/one v0.1.0
fetched example.com/lib/two v0.4.0 (file://<work>/forge/lib/two.git)
2 modules in the graph, 1 fetched; module.sum: 2 entries
exit=0
EOF
    printf 'schema = 1\nmodule = "example.com/me/inst"\n\n[dependencies]\n"example.com/lib/one" = "v0.1.0"\n\n[replacements."example.com/lib/two"]\nmodule = "example.com/lib/two"\nversion = "v0.1.0"\n' > inst/app/module.toml
    rm -f inst/app/module.sum
    DIR="$work/inst/app" expect "a module-form replacement pins the version install uses" install <<'EOF'
cached example.com/lib/one v0.1.0
fetched example.com/lib/two v0.1.0 (file://<work>/forge/lib/two.git)
module.toml: [indirectDependencies] 1 module
2 modules in the graph, 1 fetched; module.sum: 2 entries
exit=0
EOF
    DIR="$work/inst/app" expect "and the searcher loads the pinned version" run -e 'print(require("example.com/lib/two").v)' - <<'EOF'
3
exit=0
EOF
    DIR="$work/inst/app" expect "tree names the replacement" tree <<'EOF'
example.com/me/inst - (.)
└── example.com/lib/one v0.1.0 (cache)
    └── example.com/lib/two v0.4.0 (replaced by example.com/lib/two at <work>/inst/cache/modules/example.com/lib/two/v0.1.0) [v0.1.0 selected]
exit=0
EOF
    printf 'schema = 1\nmodule = "example.com/me/inst"\n\n[dependencies]\n"nowhere.test/x/y" = "v1.0.0"\n' > inst/app/module.toml
    DIR="$work/inst/app" expect "install with no source for a host" install <<'EOF'
prolua: nowhere.test/x/y: no source for host 'nowhere.test' (github.com, gitlab.com and codeberg.org are built in; PROLUA_SOURCES=host=url names another; DNS discovery is not implemented yet); vendor it or add [replacements."nowhere.test/x/y"] path = "..."
prolua: 1 module could not be installed; module.toml and module.sum left unchanged
exit=1
EOF

    # add fetching, @latest, update, remove, --frozen, on the same forge
    printf 'schema = 1\nmodule = "example.com/me/inst"\n' > inst/app/module.toml
    rm -f inst/app/module.sum
    DIR="$work/inst/app" expect "add takes a version that is already cached" add example.com/lib/two@v0.1.0 <<'EOF'
module.toml: added example.com/lib/two v0.1.0
cached example.com/lib/two v0.1.0
1 module in the graph, 0 fetched; module.sum: 1 entry
exit=0
EOF
    DIR="$work/inst/app" expect "add defaults to the latest release, and selection bumps" add example.com/lib/one <<'EOF'
example.com/lib/one: latest is v0.1.0 (1 version at file://<work>/forge/lib/one.git)
module.toml: added example.com/lib/one v0.1.0
cached example.com/lib/one v0.1.0
cached example.com/lib/two v0.4.0
bumped example.com/lib/two v0.1.0 -> v0.4.0 (required by example.com/lib/one)
2 modules in the graph, 0 fetched; module.sum: 2 entries
exit=0
EOF
    DIR="$work/inst/app" expect "update finds everything at its latest" update <<'EOF'
example.com/lib/two v0.4.0: latest
example.com/lib/one v0.1.0: latest
cached example.com/lib/one v0.1.0
cached example.com/lib/two v0.4.0
2 modules in the graph, 0 fetched; module.sum: 2 entries
exit=0
EOF
    sed -i 's/"example.com\/lib\/two" = "v0.4.0"/"example.com\/lib\/two" = "v0.1.0"/' inst/app/module.toml
    DIR="$work/inst/app" expect "update moves a dependency to its latest release" update example.com/lib/two <<'EOF'
example.com/lib/two v0.1.0 -> v0.4.0
cached example.com/lib/one v0.1.0
cached example.com/lib/two v0.4.0
2 modules in the graph, 0 fetched; module.sum: 2 entries
exit=0
EOF
    DIR="$work/inst/app" expect "remove drops a dependency and shrinks the sum" remove example.com/lib/one <<'EOF'
module.toml: removed example.com/lib/one
cached example.com/lib/two v0.4.0
1 module in the graph, 0 fetched; module.sum: 1 entry
exit=0
EOF
    DIR="$work/inst/app" expect "install --frozen passes when nothing would change" install --frozen <<'EOF'
cached example.com/lib/two v0.4.0
1 module in the graph, 0 fetched; module.toml and module.sum unchanged
exit=0
EOF
    printf '\n[indirectDependencies]\n"example.com/lib/one" = "v0.1.0"\n' >> inst/app/module.toml
    DIR="$work/inst/app" expect "install --frozen fails when the manifest would change" install --frozen <<'EOF'
cached example.com/lib/two v0.4.0
prolua: --frozen: install would change module.toml; run prolua install and commit the result
exit=1
EOF
    DIR="$work/inst/app" expect "remove of an indirect dependency" remove example.com/lib/one <<'EOF'
prolua: example.com/lib/one v0.1.0 is an indirect dependency, not one this project declares; remove the dependency that needs it
exit=1
EOF
    DIR="$work/inst/app" expect "remove of an unknown module" remove example.com/lib/zzz <<'EOF'
prolua: example.com/lib/zzz is not in [dependencies] of <work>/inst/app/module.toml
exit=1
EOF
    DIR="$work/inst/app" expect "update of an unknown module" update example.com/lib/zzz <<'EOF'
prolua: example.com/lib/zzz is not in [dependencies] of this project
exit=1
EOF
    DIR="$work/inst/app" expect "add with a bad version word" add example.com/lib/two@nope <<'EOF'
prolua: 'nope' is not a version: vMAJOR.MINOR.PATCH, or latest, as in example.com/lib/two@v1.0.0
exit=1
EOF
    unset PROLUA_CACHE PROLUA_SOURCES
else
    echo "(no git: install cases skipped)"
fi

# --- vendor -----------------------------------------------------------------
# addapp: one (replaced, at v0.2.0 in its checkout) with its cached
# dependency four, two (replaced), three (cached).
export PROLUA_CACHE="$work/mods/cache"
DIR="$work/mods/addapp" expect "vendor copies the graph and writes its manifest" vendor <<'EOF'
replaced example.com/lib/two -> ../app/vendor/example.com/lib/two
cached example.com/lib/three v1.0.0
replaced example.com/lib/one -> ../one
cached example.com/lib/four v2.0.0
vendored example.com/lib/one v0.2.0 (from its replacement)
vendored example.com/lib/three v1.0.0
vendored example.com/lib/two v0.1.0 (from its replacement)
vendored example.com/lib/four v2.0.0
4 modules in vendor/; vendor/modules.toml written
exit=0
EOF
DIR="$work/mods/addapp" expect "the vendor manifest" run -e 'io.write(io.open("vendor/modules.toml"):read("a"))' - <<'EOF'
# Written by prolua vendor; do not edit. Run prolua vendor after changing dependencies.
schema = 1
fingerprint = "h1:HASH"

[[modules]]
module = "example.com/lib/four"
version = "v2.0.0"
hash = "h1:HASH"

[[modules]]
module = "example.com/lib/one"
version = "v0.2.0"
hash = "h1:HASH"

[[modules]]
module = "example.com/lib/three"
version = "v1.0.0"
hash = "h1:HASH"

[[modules]]
module = "example.com/lib/two"
version = "v0.1.0"
hash = "h1:HASH"
exit=0
EOF
mkdir -p mods/emptycache
DIR="$work/mods/addapp" PROLUA_CACHE="$work/mods/emptycache" expect "vendor mode resolves from vendor/ alone" run -e 'local one = require "example.com/lib/one" print(one.name, one.four, one.secret, require("example.com/lib/three").name)' - <<'EOF'
one	four	42	three
exit=0
EOF
DIR="$work/mods/addapp" PROLUA_CACHE="$work/mods/emptycache" expect "tree in vendor mode" tree <<'EOF'
example.com/me/addapp v0.1.0 (.)
├── example.com/lib/one v0.2.0 (vendor/)
│   └── example.com/lib/four v2.0.0 (vendor/)
├── example.com/lib/three v1.0.0 (vendor/)
└── example.com/lib/two v0.1.0 (vendor/)
exit=0
EOF
DIR="$work/mods/addapp" expect "vendor mode refuses a module that is not vendored" run -e 'local ok, e = pcall(require, "example.com/lib/five") print(e:match("\n\t(no module.-)\n\tno file"))' - <<'EOF'
no module provides 'example.com/lib/five'
	(main module example.com/me/addapp at <work>/mods/addapp: not in vendor/ (vendor mode: vendor/modules.toml exists; run prolua vendor after changing dependencies))
exit=0
EOF
sed -i 's/"example.com\/lib\/three" = "v1.0.0"/"example.com\/lib\/three" = "v1.0.1"/' mods/addapp/module.toml
DIR="$work/mods/addapp" expect "a changed manifest makes vendor/ inconsistent" run -e 'print(1)' - <<'EOF'
prolua: vendor directory is inconsistent with module.toml

run:

    prolua vendor

exit=1
EOF
sed -i 's/"example.com\/lib\/three" = "v1.0.1"/"example.com\/lib\/three" = "v1.0.0"/' mods/addapp/module.toml
DIR="$work/mods/addapp" expect "restored, it is consistent again" run -e 'print(1)' - <<'EOF'
1
exit=0
EOF
DIR="$work/mods/app" expect "vendor with a module nothing places" vendor <<'EOF'
prolua: example.com/lib/five: no source for host 'example.com' (github.com, gitlab.com and codeberg.org are built in; PROLUA_SOURCES=host=url names another; DNS discovery is not implemented yet); vendor it or add [replacements."example.com/lib/five"] path = "..."
cached example.com/lib/three v1.0.0
replaced example.com/lib/one -> ../one
cached example.com/lib/four v2.0.0
prolua: 1 module could not be installed; module.toml and module.sum left unchanged
exit=1
EOF
# --- why --------------------------------------------------------------------
export PROLUA_CACHE="$work/mods/cache"
DIR="$work/mods/app" expect "why traces a transitive module" why example.com/lib/four <<'EOF'
example.com/me/app
└── example.com/lib/one
    └── example.com/lib/four
exit=0
EOF
DIR="$work/mods/app" expect "why for a direct dependency" why example.com/lib/three <<'EOF'
example.com/me/app
└── example.com/lib/three
exit=0
EOF
DIR="$work/mods/app" expect "why for a declared module nothing places" why example.com/lib/five <<'EOF'
example.com/me/app
└── example.com/lib/five (missing)
exit=0
EOF
DIR="$work/mods/app" expect "why for a module not in the graph" why example.com/lib/two <<'EOF'
prolua: example.com/lib/two is not in the dependency graph of example.com/me/app
exit=1
EOF
DIR="$work/mods/app" expect "why for the project itself" why example.com/me/app <<'EOF'
prolua: example.com/me/app is this project
exit=1
EOF
mkdir -p mods/whyapp/src
printf 'schema = 1\nmodule = "example.com/me/whyapp"\n\n[dependencies]\n"example.com/lib/one" = "v0.1.0"\n"example.com/lib/four" = "v2.0.0"\n\n[replacements."example.com/lib/one"]\npath = "../one"\n' > mods/whyapp/module.toml
DIR="$work/mods/whyapp" expect "why prints every chain" why example.com/lib/four <<'EOF'
example.com/me/whyapp
└── example.com/lib/one
    └── example.com/lib/four

example.com/me/whyapp
└── example.com/lib/four
exit=0
EOF
expect "why needs a module" why <<EOF
prolua: why takes one module path
$why_usage
exit=2
EOF

mkdir -p mods/addapp/tests
printf 'print("ran")\n' > mods/addapp/tests/a_test.lua
sed -i 's/"example.com\/lib\/three" = "v1.0.0"/"example.com\/lib\/three" = "v1.0.1"/' mods/addapp/module.toml
DIR="$work/mods/addapp" expect "prolua test also stops on an inconsistent vendor/" test <<'EOF'
prolua: vendor directory is inconsistent with module.toml

run:

    prolua vendor

exit=1
EOF
sed -i 's/"example.com\/lib\/three" = "v1.0.1"/"example.com\/lib\/three" = "v1.0.0"/' mods/addapp/module.toml
rm -rf mods/addapp/tests

# --- symbolic links ---------------------------------------------------------
# A replaced module with a link to a file (fine), a link out of its tree
# (not a package; vendor refuses it) and a dangling link
mkdir -p mods/linked/src mods/outside mods/linkapp/src
printf 'return "outside"\n' > mods/outside/x.lua
printf 'schema = 1\nmodule = "example.com/lib/linked"\n' > mods/linked/module.toml
printf 'return "linked"\n' > mods/linked/src/init.lua
ln -s init.lua mods/linked/src/alias.lua
ln -s ../../outside mods/linked/src/out
printf 'schema = 1\nmodule = "example.com/me/linkapp"\n\n[dependencies]\n"example.com/lib/linked" = "v0.1.0"\n\n[replacements."example.com/lib/linked"]\npath = "../linked"\n' > mods/linkapp/module.toml
DIR="$work/mods/linkapp" expect "a link to a file inside the module is that file" run -e 'print(require("example.com/lib/linked/alias"))' - <<'EOF'
linked
exit=0
EOF
DIR="$work/mods/linkapp" expect "a file reached through a link out of the module is not a package" run -e 'local ok, e = pcall(require, "example.com/lib/linked/out/x") print(e:match("\n\t(.example.-package of it)"))' - <<'EOF'
'example.com/lib/linked/out/x' resolves to <work>/mods/outside/x.lua, outside module example.com/lib/linked at <work>/mods/linkapp/../linked: a link out of a module is not a package of it
exit=0
EOF
DIR="$work/mods/linkapp" expect "vendor refuses a link out of a module and leaves no vendor/ behind" vendor <<'EOF'
replaced example.com/lib/linked -> ../linked
prolua: example.com/lib/linked: <work>/mods/linkapp/../linked/src/out is a symbolic link to a directory; a module's files must all lie inside it
exit=1
EOF
DIR="$work/mods/linkapp" expect "no vendor/ was left" run -e 'print(io.open("vendor/modules.toml") ~= nil, io.open("vendor") ~= nil)' - <<'EOF'
false	false
exit=0
EOF
rm mods/linked/src/out
ln -s nowhere mods/linked/src/gone
DIR="$work/mods/linkapp" expect "vendor refuses a dangling link" vendor <<'EOF'
replaced example.com/lib/linked -> ../linked
prolua: example.com/lib/linked: <work>/mods/linkapp/../linked/src/gone is a symbolic link to nothing; a module's files must all lie inside it
exit=1
EOF
rm mods/linked/src/gone
DIR="$work/mods/linkapp" expect "vendor copies a file link as the file" vendor <<'EOF'
replaced example.com/lib/linked -> ../linked
vendored example.com/lib/linked v0.1.0 (from its replacement)
1 module in vendor/; vendor/modules.toml written
exit=0
EOF
DIR="$work/mods/linkapp" expect "and the copy is a regular file that verifies" verify <<'EOF'
ok    vendor/ matches module.toml and module.sum
ok    example.com/lib/linked v0.1.0 (vendor)
1 verified, 0 mismatched, 0 not cached
exit=0
EOF

# --- when a write fails -----------------------------------------------------
# Read-only directories (skipped as root, who is never refused)
if [ "$(id -u)" != 0 ]; then
    mkdir -p mods/roapp/src mods/rocache
    printf 'schema = 1\nmodule = "example.com/me/roapp"\n\n[dependencies]\n"example.com/lib/three" = "v1.0.0"\n' > mods/roapp/module.toml
    printf 'print(1)\n' > mods/roapp/src/main.lua
    chmod 555 mods/roapp
    DIR="$work/mods/roapp" PROLUA_CACHE="$work/mods/cache" expect "install cannot write module.sum in a read-only project" install <<'EOF'
cached example.com/lib/three v1.0.0
prolua: cannot write <work>/mods/roapp/module.sum: AccessDenied
exit=1
EOF
    DIR="$work/mods/roapp" PROLUA_CACHE="$work/mods/cache" expect "add cannot write module.toml in a read-only project" add example.com/lib/four@v2.0.0 <<'EOF'
prolua: cannot write <work>/mods/roapp/module.toml: AccessDenied
exit=1
EOF
    DIR="$work/mods/roapp" PROLUA_CACHE="$work/mods/cache" expect "vendor cannot create vendor/ in a read-only project" vendor <<'EOF'
cached example.com/lib/three v1.0.0
prolua: cannot write <work>/mods/roapp/module.sum: AccessDenied
exit=1
EOF
    DIR="$work/mods/roapp" expect "init cannot write in a read-only directory" init example.com/me/other <<'EOF'
prolua: module.toml already exists in <work>/mods/roapp
exit=1
EOF
    chmod 755 mods/roapp
    chmod 555 mods/rocache
    printf 'schema = 1\nmodule = "example.com/me/roapp"\n\n[dependencies]\n"example.com/lib/three" = "v1.0.0"\n' > mods/roapp/module.toml
    DIR="$work/mods/roapp" PROLUA_CACHE="$work/mods/rocache" PROLUA_SOURCES="example.com=file://$work/forge" expect "install names the directory it cannot create in a read-only cache" install <<'EOF'
prolua: example.com/lib/three v1.0.0: fetch from file://<work>/forge/lib/three.git failed: cannot create <work>/mods/rocache/modules/example.com/lib/three: AccessDenied
prolua: 1 module could not be installed; module.toml and module.sum left unchanged
exit=1
EOF
    chmod 755 mods/rocache
    mkdir -p mods/rodir && chmod 555 mods/rodir
    DIR="$work/mods/rodir" expect "init in a read-only directory" init example.com/me/rodir <<'EOF'
prolua: cannot write <work>/mods/rodir/module.toml: AccessDenied
exit=1
EOF
    chmod 755 mods/rodir
fi

# --- malformed records ------------------------------------------------------
mkdir -p mods/badapp/src
printf 'schema = 1\nmodule = "example.com/me/badapp"\n\n[dependencies]\n"example.com/lib/three" = "1.0"\n' > mods/badapp/module.toml
printf 'print(1)\n' > mods/badapp/src/main.lua
DIR="$work/mods/badapp" expect "a dependency version that is not vX.Y.Z is refused with its line" run <<'EOF'
<work>/mods/badapp/module.toml:5: a dependency's version is vMAJOR.MINOR.PATCH, as in "v1.0.0"
exit=1
EOF
printf 'schema = 1\nmodule = "example.com/me/badapp"\n\n[dependencies]\n"example.com/lib/../../escaped" = "v1.0.0"\n' > mods/badapp/module.toml
DIR="$work/mods/badapp" expect "a dependency key that is not a module path cannot become a path" install <<'EOF'
<work>/mods/badapp/module.toml:5: components may only contain a-z, 0-9 and '-' (the first may contain '.')
exit=1
EOF
printf 'schema = 1\nmodule = "example.com/me/badapp"\n\n[dependencies]\n"example.com/lib/three" = "v1.0.0"\n' > mods/badapp/module.toml
printf 'example.com/lib/three v1.0.0 h1:AAAA\nexample.com/lib/three v1.0.0\n' > mods/badapp/module.sum
DIR="$work/mods/badapp" expect "a malformed module.sum line is named" verify <<'EOF'
prolua: <work>/mods/badapp/module.sum:2: malformed line (expected '<module> <version> h1:<hash>'); fix or delete the line
exit=1
EOF
printf 'example.com/lib/three v1.0.0 sha256:AAAA\n' > mods/badapp/module.sum
DIR="$work/mods/badapp" expect "a sum with an unknown hash kind is malformed" install <<'EOF'
prolua: <work>/mods/badapp/module.sum:1: malformed line (expected '<module> <version> h1:<hash>'); fix or delete the line
exit=1
EOF
rm mods/badapp/module.sum

# --- verify -----------------------------------------------------------------
# On a copy of addapp (with its vendor/), so the tampering below cannot
# reach the groups that follow
rm -rf mods/verifyapp && cp -r mods/addapp mods/verifyapp
DIR="$work/mods/verifyapp" expect "verify checks the cache and vendor/ against the records" verify <<'EOF'
ok    example.com/lib/four v2.0.0 (cache)
ok    example.com/lib/three v1.0.0 (cache)
ok    vendor/ matches module.toml and module.sum
ok    example.com/lib/four v2.0.0 (vendor, module.sum)
ok    example.com/lib/one v0.2.0 (vendor)
ok    example.com/lib/three v1.0.0 (vendor, module.sum)
ok    example.com/lib/two v0.1.0 (vendor)
6 verified, 0 mismatched, 0 not cached
exit=0
EOF
echo "-- changed" >> mods/verifyapp/vendor/example.com/lib/two/src/init.lua
echo "-- changed" >> mods/cache/modules/example.com/lib/three/v1.0.0/src/init.lua
DIR="$work/mods/verifyapp" expect "verify reports a changed cached tree and a changed vendored one" verify <<'EOF'
ok    example.com/lib/four v2.0.0 (cache)
FAIL  example.com/lib/three v1.0.0 (cache): <work>/mods/cache/modules/example.com/lib/three/v1.0.0
      recorded h1:HASH
      found    h1:HASH
ok    vendor/ matches module.toml and module.sum
ok    example.com/lib/four v2.0.0 (vendor, module.sum)
ok    example.com/lib/one v0.2.0 (vendor)
ok    example.com/lib/three v1.0.0 (vendor, module.sum)
FAIL  example.com/lib/two v0.1.0 (vendor): <work>/mods/verifyapp/vendor/example.com/lib/two
      recorded h1:HASH
      found    h1:HASH
4 verified, 2 mismatched, 0 not cached
exit=1
EOF
sed -i '$ d' mods/verifyapp/vendor/example.com/lib/two/src/init.lua
sed -i '$ d' mods/cache/modules/example.com/lib/three/v1.0.0/src/init.lua
sed -i 's/"example.com\/lib\/three" = "v1.0.0"/"example.com\/lib\/three" = "v1.0.1"/' mods/verifyapp/module.toml
DIR="$work/mods/verifyapp" expect "verify reports a vendor tree behind the manifest" verify <<'EOF'
ok    example.com/lib/four v2.0.0 (cache)
ok    example.com/lib/three v1.0.0 (cache)
FAIL  vendor/ is inconsistent with module.toml or module.sum: run prolua vendor
ok    example.com/lib/four v2.0.0 (vendor, module.sum)
ok    example.com/lib/one v0.2.0 (vendor)
ok    example.com/lib/three v1.0.0 (vendor, module.sum)
ok    example.com/lib/two v0.1.0 (vendor)
6 verified, 1 mismatched, 0 not cached
exit=1
EOF
sed -i 's/"example.com\/lib\/three" = "v1.0.1"/"example.com\/lib\/three" = "v1.0.0"/' mods/verifyapp/module.toml
rm -rf mods/cache/modules/example.com/lib/four
DIR="$work/mods/verifyapp" expect "verify skips a sum entry that is not cached" verify <<'EOF'
-     example.com/lib/four v2.0.0: not in the cache, nothing to verify
ok    example.com/lib/three v1.0.0 (cache)
ok    vendor/ matches module.toml and module.sum
ok    example.com/lib/four v2.0.0 (vendor, module.sum)
ok    example.com/lib/one v0.2.0 (vendor)
ok    example.com/lib/three v1.0.0 (vendor, module.sum)
ok    example.com/lib/two v0.1.0 (vendor)
5 verified, 0 mismatched, 1 not cached
exit=0
EOF
mkdir -p mods/cache/modules/example.com/lib/four/v2.0.0/src
printf 'schema = 1\nmodule = "example.com/lib/four"\n' > mods/cache/modules/example.com/lib/four/v2.0.0/module.toml
printf 'return { name = "four" }\n' > mods/cache/modules/example.com/lib/four/v2.0.0/src/init.lua
DIR="$work/mods/one" expect "verify with nothing recorded" verify <<'EOF'
nothing to verify: module.sum has no entries and there is no vendor/
exit=0
EOF
unset PROLUA_CACHE
# --- clean ------------------------------------------------------------------
cp -r mods/cache mods/cache2
PROLUA_CACHE="$work/mods/cache2" expect "clean removes the module cache" clean <<'EOF'
removed 2 module versions from <work>/mods/cache2/modules
exit=0
EOF
PROLUA_CACHE="$work/mods/cache2" expect "clean with nothing cached" clean <<'EOF'
nothing cached at <work>/mods/cache2/modules
exit=0
EOF
DIR="$work/mods/addapp" PROLUA_CACHE="$work/mods/cache2" expect "after clean, vendor/ still serves" run -e 'print(require("example.com/lib/three").name)' - <<'EOF'
three
exit=0
EOF
expect "clean takes no arguments" clean x <<EOF
prolua: clean takes no arguments
$clean_usage
exit=2
EOF

expect "verify outside a project" verify <<'EOF'
prolua: not inside a project: no module.toml in <work> or above it (prolua init creates one)
exit=1
EOF
expect "verify takes no arguments" verify x <<EOF
prolua: verify takes no arguments
$verify_usage
exit=2
EOF
expect "vendor outside a project" vendor <<'EOF'
prolua: not inside a project: no module.toml in <work> or above it (prolua init creates one)
exit=1
EOF
expect "vendor takes no arguments" vendor x <<EOF
prolua: vendor takes no arguments
$vendor_usage
exit=2
EOF

expect "remove outside a project" remove example.com/lib/one <<'EOF'
prolua: not inside a project: no module.toml in <work> or above it (prolua init creates one)
exit=1
EOF
expect "remove needs a module" remove <<EOF
prolua: remove takes one module path
$remove_usage
exit=2
EOF
expect "update outside a project" update <<'EOF'
prolua: not inside a project: no module.toml in <work> or above it (prolua init creates one)
exit=1
EOF
expect "install rejects an unknown flag" install --bogus <<EOF
prolua: unknown flag '--bogus' for install
$install_usage
exit=2
EOF

# --- init -------------------------------------------------------------------
mkdir -p init/myapp
DIR="$work/init/myapp" expect "init from the directory name" init <<'EOF'
initialized module myapp
  module.toml
  src/main.lua
a local module: without a namespace (<host>/<path>) it cannot be published
exit=0
EOF
DIR="$work/init/myapp" expect "init wrote a manifest run can use" run <<'EOF'
hello from myapp
exit=0
EOF
DIR="$work/init/myapp" expect "the manifest" run -e 'print(io.open("module.toml"):read("a"))' - <<'EOF'
schema = 1
module = "myapp"
version = "v0.1.0"
prolua = ">=<version>"

exit=0
EOF
DIR="$work/init/myapp" expect "init refuses a second time" init <<'EOF'
prolua: module.toml already exists in <work>/init/myapp
exit=1
EOF
mkdir -p init/ns
DIR="$work/init/ns" expect "init with a namespace path" init github.com/matt-dunleavy/http <<'EOF'
initialized module github.com/matt-dunleavy/http
  module.toml
  src/main.lua
exit=0
EOF
mkdir -p init/keep/src
printf 'print("kept")\n' > init/keep/src/main.lua
DIR="$work/init/keep" expect "init keeps an existing src/main.lua" init keep <<'EOF'
initialized module keep
  module.toml
a local module: without a namespace (<host>/<path>) it cannot be published
exit=0
EOF
DIR="$work/init/keep" expect "and runs it" run <<'EOF'
kept
exit=0
EOF
mkdir -p 'init/Bad Name'
DIR="$work/init/Bad Name" expect "init rejects the directory's name" init <<'EOF'
prolua: invalid module path 'Bad Name': components may only contain a-z, 0-9 and '-' (the first may contain '.')
  (the directory's name was used; give a path: prolua init <host>/<path>)
exit=1
EOF
mkdir -p init/x
DIR="$work/init/x" expect "init rejects a bad path" init github.com/-x <<'EOF'
prolua: invalid module path 'github.com/-x': a component may not start or end with '-'
exit=1
EOF
DIR="$work/init/x" expect "init takes one argument" init a b <<EOF
prolua: init takes at most one argument, the module path
$init_usage
exit=2
EOF

# --- disasm -----------------------------------------------------------------
printf 'local x <const> = 3\nlocal function f(a) return a + x end\nreturn f(1)\n' > d.lua
expect "disasm lists like luac -l -l -p" disasm d.lua <<'EOF'

main <d.lua:0,0> (7 instructions at ADDR)
0+ params, 3 slots, 1 upvalue, 1 local, 0 constants, 1 function
	1	[1]	VARARGPREP	0
	2	[2]	CLOSURE  	0 0	; ADDR
	3	[3]	MOVE     	1 0
	4	[3]	LOADI    	2 1
	5	[3]	TAILCALL 	1 2 1	; 1 in
	6	[3]	RETURN   	1 0 1	; all out
	7	[3]	RETURN   	1 1 1	; 0 out
constants (0) for ADDR:
locals (1) for ADDR:
	0	f	3	8
upvalues (1) for ADDR:
	0	_ENV	1	0

function <d.lua:2,2> (4 instructions at ADDR)
1 param, 2 slots, 0 upvalues, 1 local, 0 constants, 0 functions
	1	[2]	ADDI     	1 0 3
	2	[2]	MMBINI   	0 3 6 0	; __add
	3	[2]	RETURN1  	1
	4	[2]	RETURN0
constants (0) for ADDR:
locals (1) for ADDR:
	0	a	1	5
upvalues (0) for ADDR:
exit=0
EOF
expect "disasm of a precompiled chunk" run -e 'io.open("d.luac", "wb"):write(string.dump(loadfile("d.lua"), true))' -e 'os.exit(0)' <<'EOF'
exit=0
EOF
expect "disasm reads it" disasm d.luac <<'EOF'

main <?:0,0> (7 instructions at ADDR)
0+ params, 3 slots, 1 upvalue, 0 locals, 0 constants, 1 function
	1	[-]	VARARGPREP	0
	2	[-]	CLOSURE  	0 0	; ADDR
	3	[-]	MOVE     	1 0
	4	[-]	LOADI    	2 1
	5	[-]	TAILCALL 	1 2 1	; 1 in
	6	[-]	RETURN   	1 0 1	; all out
	7	[-]	RETURN   	1 1 1	; 0 out
constants (0) for ADDR:
locals (0) for ADDR:
upvalues (1) for ADDR:
	0	-	1	0

function <?:2,2> (4 instructions at ADDR)
1 param, 2 slots, 0 upvalues, 0 locals, 0 constants, 0 functions
	1	[-]	ADDI     	1 0 3
	2	[-]	MMBINI   	0 3 6 0	; __add
	3	[-]	RETURN1  	1
	4	[-]	RETURN0
constants (0) for ADDR:
locals (0) for ADDR:
upvalues (0) for ADDR:
exit=0
EOF
expect "disasm goes on after a missing file" disasm nope.lua syntax.lua <<'EOF'
prolua: cannot open nope.lua: No such file or directory
prolua: syntax.lua:2: unexpected symbol near <eof>
exit=1
EOF
expect "disasm needs a file" disasm <<EOF
prolua: disasm needs at least one file
$disasm_usage
exit=2
EOF
expect "disasm takes no flags" disasm -l d.lua <<EOF
prolua: unknown flag '-l' for disasm
$disasm_usage
exit=2
EOF
expect "disasm help" disasm --help <<EOF
$disasm_usage
exit=0
EOF

# --- bench ------------------------------------------------------------------
# Times are normalised to T and ratios to R; /bin/true stands in for the
# reference interpreter so the ratio column is exercised without one.
mkdir -p bdir
printf 'local s = 0 for i = 1, 1000 do s = s + i end\n' > bdir/tiny.lua
printf 'local s = 0 for i = 1, 10 do s = s + i end\n' > bdir/small.lua
printf 'error("no")\n' > bdir/broken.lua
expect "bench alone" bench --dir bdir --runs 1 --no-lua tiny <<'EOF'
script             prolua        lua    ratio
tiny T          -        -
exit=0
EOF
expect "bench every script, sorted, against a stand-in" bench --dir bdir --runs 1 --lua /bin/true small tiny <<'EOF'
script             prolua        lua    ratio
small T T R
tiny T T R
exit=0
EOF
expect "bench of a failing script" bench --dir bdir --runs 1 --no-lua broken <<'EOF'
script             prolua        lua    ratio
prolua: bdir/broken.lua:1: no
stack traceback:
	[C]: in function 'error'
	bdir/broken.lua:1: in main chunk
	[C]: in ?
prolua: bdir/broken.lua failed under prolua
exit=1
EOF
expect "bench of an unknown name" bench --dir bdir nope <<'EOF'
prolua: no script nope.lua in bdir
exit=1
EOF
expect "bench of a missing directory" bench --dir nodir <<'EOF'
prolua: cannot open benchmark directory nodir: FileNotFound
exit=1
EOF
expect "bench runs must be a number" bench --runs x <<EOF
prolua: '--runs' needs a positive number, not 'x'
$bench_usage
exit=2
EOF
expect "bench help" bench --help <<EOF
$bench_usage
exit=0
EOF

# --- the REPL through a pipe ------------------------------------------------
IN=repl_session.txt expect "repl session" run -i -e 'print("before")' <<'EOF'
before
> > 2
> >> >> > 2	s
> stdin:1: e
stack traceback:
	[C]: in function 'error'
	stdin:1: in main chunk
	[C]: in ?
> nil
> p
> stdin:1: unexpected symbol near '1'
> 2
> 1
> stdin:1: attempt to assign to const variable 'a'
> >> stdin:1: unfinished string near '"unfinished'
> stdin:1: unexpected symbol near '{'
> stdin:1: unexpected symbol near '3'
> >> >> 1
2
> 1	2
>
exit=0
EOF
IN=repl_no_newline.txt expect "repl without trailing newline" run -i <<'EOF'
> 2
>
exit=0
EOF

echo
echo "command line: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    echo "failing: ${failed[*]}"
    exit 1
fi
