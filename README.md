![](docs/logo.png)

[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)[![ci](https://github.com/matt-dunleavy/rustline/actions/workflows/ci.yml/badge.svg)](https://github.com/matt-dunleavy/prolua/actions/workflows/ci.yml)[![Discord](https://img.shields.io/badge/discord-chat-green?logo=discord)](https://discord.gg/dFXhpQcQ7u)[![Twitter](https://img.shields.io/twitter/url/https/twitter.com/cloudposse.svg?style=social&label=Follow%20%40matthewdunleavy)](https://twitter.com/matthewdunleavy)

Prolua is a complete Lua-inspired runtime and toolchain built to deliver modern applications at scale. Prolua aims to provide the whole environment: `prolua init` makes a project, `prolua add` brings in a library from any Git forge and pins it by content hash, `prolua test` runs the tests, `prolua run` runs the program, and `prolua vendor` makes the repository self-contained for the build machine. There is nothing to install beside it and no service it depends on.

> [!IMPORTANT]
>
> This is a very early release of the Prolua runtime and toolchain. It should not be used for production purposes as many of the components may change or break without advance notice.

The baseline language is Lua 5.4, and the support is verified rather than simply asserted: every observable behaviour is compared byte for byte with the reference implementation, Lua 5.4.8, the official test suite passes, and real projects such as Fennel and the Teal compiler run their own test suites under Prolua with the reference's output. Existing Lua code runs as is.

| | |
| --- | --- |
| Version | 0.1.0 (`prolua --version`) |
| Language | Lua 5.4, matched byte for byte against Lua 5.4.8 |
| Implementation | Zig 0.16.0, links libc, no other dependencies; a single binary |
| Platforms | Linux (every suite), macOS (unit, differential and command-line suites in CI), Windows (build, unit tests and a smoke run in CI); cross-compiles for `x86_64-windows-gnu`, `aarch64-macos`, `x86_64-linux-musl` and `aarch64-linux-gnu` |
| License | MIT |

## What you get

- **A modern CLI - with everything built in ** `run`, `eval`, `init`, `test`, `disasm`, `bench` and nine dependency commands, each with `--help`. The classic interpreter flags keep their meaning under
  `run`, so scripts, `LUA_PATH`, `LUA_INIT` and the `arg` table work as they always have.
- **Projects.** A directory with a `module.toml` and a `src/main.lua` is a program. `prolua run .` runs it, `prolua test` runs its `tests/*_test.lua` in isolated states, and `require "github.com/owner/lib"` resolves through the manifest.
- **A package manager without a registry.** A module is named by the repository that publishes it and fetched with `git` from GitHub, GitLab, Codeberg or your own forge. Versions are chosen by minimum version selection, every tree is pinned in `module.sum` by a content hash, `install --frozen` makes CI reproducible and `vendor` makes the repository self-contained. `tree`, `why` and `verify` explain and audit the result.
- **Developer tools built in.** A REPL with Ctrl-C that returns to the prompt, `eval -p` for one-liners, a bytecode disassembler in the`luac -l -l -p` format and a benchmark runner that times scripts against the reference interpreter.
- **Lua 5.4 support - the whole language and the whole library.** All 83 opcodes, every metamethod including `__close` and `__gc`, `<const>` and `<close>` variables, integer and float subtypes with the reference's coercion rules, `goto`, coroutines with `close` and yields across `pcall`, the incremental and the generational collector with weak tables, ephemerons and finalizers, `string.pack`, `utf8`, `io.popen`, `string.dump` and `load`, the debug library and hooks, and error messages with the reference's wording and variable names.
- **Fast.** A ReleaseFast build runs the twelve `test/bench` scripts between 0.60× and 1.19× the C interpreter's time: faster on sorting, numeric loops, coroutines and n-body, and within 3% on binary trees, fannkuch, tables, recursive calls and closures. Values are 8-byte NaN boxes, table nodes are 24 bytes, dispatch is a labeled switch, and every change is measured against the reference.
- **Hardened.** A mutation fuzzer over nine targets, the command-line and official suites under valgrind, unit tests under a leak-checking allocator, and a module system that validates every path it turns into a file name, clones without symbolic links, hooks or submodules, writes every file atomically and times out on a dead remote.
- **Embeddable.** Prolua is a Zig package first. `src/prolua.zig` exposes a `lua_*`-shaped API with Zig errors and slices; the command line is built on it like any other embedder.

## Quick start

```
zig build -Doptimize=ReleaseFast     # zig-out/bin/prolua
sudo scripts/install.sh              # into /usr/local/bin

mkdir hello && cd hello
prolua init github.com/you/hello     # module.toml and src/main.lua
prolua add github.com/matt-dunleavy/json  # fetch the latest release, write module.toml and module.sum
prolua run                           # runs src/main.lua
prolua test                          # runs tests/*_test.lua once you have written one
```

Inside `src/main.lua`:

```lua
local json = require "github.com/matt-dunleavy/json"
print(json.encode { hello = "world" })
```

Outside a project, `prolua run script.lua`, `prolua eval -p '1 + 1'` and the bare `prolua` REPL work as any Lua does, and `require "name"` goes through `package.path` as before.

## The command line

```
prolua run script.lua [args...]   # a file; args become arg[1..]
prolua run .                      # a project directory: its src/main.lua
prolua run                        # inside a project, the same
prolua run -e 'print(1)' -        # -e/--eval, -l/--lib, -i, -W, -E, -- before the target; - is stdin
prolua eval [-p] 'code' [args...] # code from the command line; -p prints an expression's values
prolua init [github.com/you/app]  # module.toml and src/main.lua in the working directory
prolua test [name...]             # the project's tests/*_test.lua, each in its own state
prolua disasm file.lua            # bytecode listing in luac -l -l -p format
prolua bench [fib loops]          # time test/bench scripts against the reference lua
prolua add <module>[@v1.0.0|@latest] [--path ../checkout]   # declare a dependency and install it
prolua remove <module>            # drop a dependency and install
prolua update [module...]         # move dependencies to their latest release and install
prolua install [--frozen]         # fetch dependencies into the cache, write module.sum
prolua vendor                     # copy the dependencies into vendor/ and load them from there
prolua verify                     # check cached and vendored modules against module.sum
prolua tree                       # the dependency graph and where each module is placed
prolua why <module>               # every chain of dependencies that brings a module in
prolua clean                      # remove the module cache
prolua                            # the REPL on a terminal; runs standard input otherwise
prolua --version, prolua --help, prolua <command> --help
```

`prolua script.lua` without `run` is an error with a hint. Under `run` the classic options keep their meaning (`-e`, `-l`, `-i`, `-W`, `-E`, `--`, `-` for stdin, the `arg` table, `LUA_INIT`, `LUA_PATH`). Ctrl-C interrupts a running chunk and returns to the prompt. Exit status 2 marks a usage error.

## Projects and modules

A project is a directory with a `module.toml`, written by `init`:

```toml
schema = 1
module = "github.com/you/hello"
version = "v0.1.0"
prolua = ">=0.1.0"

[dependencies]
"github.com/matt-dunleavy/json" = "v0.1.0"
```

A module is named by its import path, `<host>/<owner>/<repo>[/<dir>]`, and a package inside it is a further path: `require "github.com/you/lib/client"` loads `src/client.lua` or `src/client/init.lua` from the `lib` module. A package with an `internal` component loads only from files inside its own module.

`require` places a module, in order: the project itself; the module the requiring file lives in; a `[replacements]` entry pointing at a local checkout or another module; `vendor/`; and the cache. The cache is `$PROLUA_CACHE`, else `$XDG_CACHE_HOME/prolua`, else `~/.cache/prolua`. Every failure is a line in `require`'s report that says what was consulted and what to do.

`prolua install` walks the graph from the manifest with **minimum version selection** (the highest version any module asks for wins, as in Go), clones each missing module at its `vMAJOR.MINOR.PATCH` tag from `github.com`, `gitlab.com`, `codeberg.org` or a forge named in `PROLUA_SOURCES`, hashes the tree (`h1:`, the same dirhash Go uses) and records it in `module.sum`. A tree that does not hash to its recorded value is refused and nothing is written. `[indirectDependencies]` is maintained for you, so the main manifest alone decides every version.

- **Reproducible in CI:** `prolua install --frozen` fails, writing nothing, if `module.toml` or `module.sum` would change.
- **Self-contained in the repository:** `prolua vendor` copies every selected module into `vendor/` with a fingerprint of the manifest; from then on modules come from `vendor/` and nowhere else, and a `vendor/` that no longer matches `module.toml` stops `run` with a message that says to run `vendor` again.
- **Explainable:** `prolua tree` shows every module and where it was placed; `prolua why <module>` shows every chain that brings it in; `prolua verify` re-hashes everything on disk against `module.sum`.
- **Local development:** `prolua add <module> --path ../checkout` writes a `[replacements]` entry, and the checkout's own dependencies are installed too.
- **Safe by construction:** every module path a manifest, sum file or vendor record carries is validated before it becomes a directory, a tag or a URL; clones run with symbolic links disabled and never initialize submodules or run hooks; every file the module system writes goes through a temporary file and a rename; a hung remote is an error, not a hang.

## Lua 5.4 support

Prolua runs Lua 5.4 as the reference implements it and that is tested rather than asserted:

| Suite | What it checks |
| --- | --- |
| `test/diff` + `test/lua54` (55 scripts) | Output compared byte for byte with Lua 5.4.8: values, `tostring`, `string.format`, error messages and tracebacks, `string.dump` round-trips, both collector modes, `io` and `os`, `popen`, `warn`, the limits |
| `test/puc` (the official Lua 5.4.8 suite) | 30 of 30 runnable files in portable mode (`all`, `main` and `heavy` drive the suite or allocate until killed and are never run) |
| `test/corpus` (8 real projects) | json.lua, dkjson, serpent, luaunit, lunajson, LuaMinify, Fennel and tl at pinned commits, their own tests under both interpreters; output and exit status must match |
| `test/cli` (209 cases) | The command line, projects, every dependency command against a `file://` forge, read-only directories, symbolic links, Ctrl-C |
| `test/fuzz` (9 targets) | Mutation fuzzing of source, the binary loader (byte-level and structural), patterns, `format`, `pack`, numerals, `utf8` and module paths, on the ReleaseSafe build, with outcomes diffed against the reference where it has the feature |

Where the two disagree the reference wins, and the differential suite's `known_diff` table is empty. The command line and the module system are Prolua's own design and have no reference; their expectations are pinned in the tree.

## Test results, verified on 2026-09-12

Every row was run on this date on Linux against the installed Lua 5.4.8, with Zig 0.16.0:

| Suite | Command | Result |
| --- | --- | --- |
| Unit tests (leaf modules, runtime, command line) | `zig build test-unit` | 267 of 267 pass |
| Differential, Debug build | `zig build test-diff` | 55 pass, 0 fail, 0 known-different |
| Differential, ReleaseSafe build | `zig build test-diff-safe` | 55 pass, 0 fail |
| Command line | `zig build test-cli` | 209 pass, 0 fail |
| Official Lua 5.4.8 suite | `zig build test-puc` | 30 pass, 0 unexpected failures |
| Real-program corpus | `zig build test-corpus` | 8 of 8 projects match the reference |
| Fuzzing, 2000 cases per target | `zig build fuzz -- all 2000 1` | 9 of 9 targets, no crash |
| Command line under valgrind | `zig build test-cli-valgrind` | 205 pass, 0 fail, no memory errors, no definite leaks (the memory-limit cases are not run under it) |
| Official suite under valgrind | `zig build test-puc-valgrind` | 30 pass, no memory errors |

The same suites run in CI on every push (`.github/workflows/ci.yml`), plus the macOS and Windows jobs and the four cross-compiles.

## Performance

`prolua bench` times each script in `test/bench` as a whole process under Prolua and under the reference interpreter, best of three runs. Measured on 2026-09-12 with `zig build bench -Doptimize=ReleaseFast` against the installed Lua 5.4.8:

| Script | prolua | lua | ratio |
| --- | --- | --- | --- |
| binarytrees | 0.449 s | 0.443 s | 1.01× |
| closures | 0.494 s | 0.479 s | 1.03× |
| coroutines | 0.158 s | 0.192 s | 0.82× |
| fannkuch | 1.734 s | 1.716 s | 1.01× |
| fib | 0.055 s | 0.054 s | 1.01× |
| json | 0.521 s | 0.455 s | 1.15× |
| loops | 0.375 s | 0.521 s | 0.72× |
| nbody | 0.612 s | 0.686 s | 0.89× |
| sort | 0.250 s | 0.418 s | 0.60× |
| spectralnorm | 0.517 s | 0.435 s | 1.19× |
| strings | 0.247 s | 0.208 s | 1.19× |
| tables | 0.673 s | 0.674 s | 1.00× |

## Embedding

Prolua is a Zig package first. `src/prolua.zig` is the library root and `prolua.api` follows the C API's shape (`pushInteger`, `getGlobal`, `pcall`, `checkString`, ...) with Zig errors in place of `longjmp` and slices in place of `const char *`:

```zig
const L = try LuaState.init(gpa, null);
defer L.deinit();
try prolua.lib.openLibs(L);
try api.pushCFunction(L, add);
try api.setGlobal(L, "add");
```

`docs/embedding.md` is the guide and `examples/embed.zig` its program (`zig build example`). The command line in `src/cli/` is built on the same module. How the interpreter, the command line and the module system fit together is [`docs/architecture.md`](docs/architecture.md).

## Build and test

```
zig build                              # zig-out/bin/prolua, Debug
zig build -Doptimize=ReleaseFast       # the build to measure or ship
zig build test-all                     # unit tests, differential scripts on two builds, command-line cases
zig build test-puc                     # the official Lua 5.4.8 suite
zig build test-corpus                  # real projects' test suites (network the first time)
zig build fuzz -- [target] [cases]     # mutation fuzzing on the ReleaseSafe build
zig build test-cli-valgrind            # the command-line suite under valgrind (minutes)
zig build bench -Doptimize=ReleaseFast # test/bench under prolua and lua
zig build example                      # the embedding example
zig build docs                         # API docs into zig-out/docs
```

The differential and corpus suites need a `lua` 5.4.8 on `PATH` (or `LUA=...`); Ubuntu's package is 5.4.6 and the harnesses compare bytes, so CI builds the reference from the tarball. `make` wraps the same steps.

> [!WARNING]
>
> The Debug build cannot compile tail calls. Zig's self-hosted x86_64 backend, which Debug uses, rejects it outright, while release builds go through LLVM and honour it. A threaded VM would need Debug builds on LLVM. For numerous reasons, you should always use `make build release`.

## Roadmap

Prolua is pre-1.0 and the interface may still move. What the specification describes and the tree does not yet have:

- DNS discovery of a publisher's own host, HTTPS archive sources and signed releases; forges and `PROLUA_SOURCES` stand in.
- The `import` statement; `require` with a module path is the form.
- Ctrl-C on Windows, and `io.popen` on Windows has never been exercised.
- A user guide for the module system; this page and the specification are what exists.

## Contributing

There are many ways to contribute to the Prolua project.

- [Submit bugs](https://github.com/matt-dunleavy/prolua/issues) and help us verify fixes as they are checked in.
- Review the [source code changes](https://github.com/matt-dunleavy/prolua/pulls).
- [Contribute bug fixes](https://github.com/matt-dunleavy/prolua/blob/main/CONTRIBUTING.md) or improve the codebase

## License

Prolua is licensed under the MIT License. See LICENSE for more information.

## Get in touch

Contact Matt at [mdunleavy@excedra.com](mailto:mdunleavy@excedra.com).

Join the official [Prolua Discord Community](https://discord.gg/dFXhpQcQ7u).
