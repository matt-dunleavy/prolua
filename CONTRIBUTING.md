# Contributing to Prolua

Thank you for your interest in contributing.

The goal of Prolua is to give Lua developers everything they need to
deliver robust applications that scale: one cohesive platform for
writing, managing, building, testing and shipping production software,
without having to construct the development environment first.

There are many ways to contribute, from the core implementation to the
documentation. Open an issue to discuss an idea, or a pull request for
something small and self-contained.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to help

- Report bugs and behaviour that differs from Lua 5.4 (see
  [SUPPORT.md](.github/SUPPORT.md))
- Add tests, especially differential scripts that compare against the
  reference interpreter and command-line cases for the project model
- Fix gaps in the compiler, VM, API, standard libraries or module system
- Improve documentation and error messages
- Review pull requests

Security vulnerabilities must not be reported in public issues. Follow
[SECURITY.md](.github/SECURITY.md).

## Development setup

You need:

- [Zig](https://ziglang.org/) 0.16.x (this tree targets Zig 0.16)
- A C toolchain (the runtime links libc)
- Git
- Optional: a Lua 5.4.8 interpreter on `PATH` named `lua`, for the
  differential and corpus suites (set `LUA=...` if yours is named
  differently; the harnesses compare bytes, so the exact version matters)
- Optional: valgrind, for the memory-checking lanes

Clone and build:

```sh
git clone https://github.com/matt-dunleavy/prolua.git
cd prolua
zig build
```

The debug binary is `zig-out/bin/prolua`. `zig build -Doptimize=ReleaseFast`
is the build to measure or ship.

## Tests

Run the suites that match what you changed:

```sh
zig build test-all          # unit tests, differential scripts on two builds, command-line cases
zig build test-puc          # the official Lua 5.4.8 suite: VM, tables, GC, codegen, libraries
zig build test-corpus       # real projects' test suites: libraries and the loader
zig build test-cli-valgrind # the command-line suite under valgrind: src/cli/ and src/module/
zig build fuzz -- [target]  # mutation fuzzing on the ReleaseSafe build
zig build test-<module>     # one module, e.g. test-lex, test-codegen, test-iolib
```

`make` wraps the same steps. `README.md` describes every suite and
`docs/project/project.md` says which to run for which kind of change.

New behaviour should come with a test. Prefer:

1. a `test "..."` block in the module you changed;
2. a script under `test/diff/` when the oracle is "whatever Lua 5.4.8
   prints";
3. a case in `test/cli/clitest.sh` for the command line and the module
   system, which have no reference and carry their expected output in
   the script.

Do not add a script to the differential suite's known-difference list
without a tracked item in `docs/project/project.md` explaining why it
still disagrees with the reference interpreter.

## Two rules that matter most

**The language is Lua 5.4 as the reference implements it.** Everything a
script can observe (values, libraries, error messages, `arg`, `LUA_PATH`,
the bytecode format) is compared against Lua 5.4.8 byte for byte. If the
reference and Prolua disagree, Prolua is wrong unless the difference is
already documented. Where Lua's behaviour is subtle, port the C file's
algorithm rather than inventing one.

**The tooling is Prolua's own.** The command line, the project model and
the package manager have no reference to compare with. Their design is in
`docs/project/package-manager.md` and `docs/project/project.md` Part 3;
a change to them should keep the documented behaviour or update the
document with it, and be pinned by command-line cases.

## Coding conventions

- Format Zig with `zig fmt` (`make fmt`); check with `make fmt-check`.
- Four-space indent, UTF-8, LF line endings (see `.editorconfig`).
- Match the style of the file you are editing: names, error handling,
  comment density.
- New `.zig` files start with the same MIT copyright header as their
  neighbours.
- Do not reformat unrelated code or mix large refactors with behavioural
  fixes.
- [`docs/architecture.md`](docs/architecture.md) is the map of the
  interpreter, the command line and the module system.
- `docs/project/project.md` records the house conventions that are not
  obvious from the code (arena-owned strings, `@fieldParentPtr` casts,
  the NaN-box interface, stdio through `utils/stdio.zig`). Read its
  "House conventions" section before touching the runtime.

This project reimplements Lua's design. It is not a copy of the official
C sources. Do not paste PUC-Rio Lua source into this tree. Credit for
the language belongs in [NOTICE](NOTICE) and [ATTRIBUTION.md](ATTRIBUTION.md).

## Pull requests

1. Open an issue first for substantial changes so the approach can be
   discussed.
2. Create a branch from the default branch.
3. Keep the change focused. One problem per pull request.
4. Run `zig fmt` and the relevant suites locally.
5. Describe *why* the change is needed, what behaviour it matches or
   introduces, and how you tested it.
6. Update `CHANGELOG.md` under "Unreleased", and the docs or tests, when
   user-visible behaviour changes.

Maintainers may ask for a reproducing script, a differential or
command-line case, or a smaller split of the diff.

## Bug reports and feature ideas

Use [GitHub issues](https://github.com/matt-dunleavy/prolua/issues).

Bug reports should include the Prolua version, the Zig version, the OS,
a short reproducer, and expected versus actual results. If official Lua
5.4 does something different, include that output.

Feature requests for the language itself are out of scope: Prolua runs
Lua 5.4 as the manual defines it. Requests for the command line, the
project model, the module system and the embedding API are welcome.

## License

Contributions are accepted under the [MIT License](LICENSE) that
covers this repository. You must have the right to submit the work under
that license.

Lua is Copyright © 1994–2026 Lua.org, PUC-Rio. Prolua is an independent
implementation. See [NOTICE](NOTICE) for the required attribution.

## Questions

Matt Dunleavy
<mdunleavy@excedra.com>
