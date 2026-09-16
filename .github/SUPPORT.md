# Support

This page explains where to get help, how to report problems, and what this project does and does not cover.

> [!IMPORTANT]
>
> Get answers to your questions and hang out with our growing community on the new [Discord Server](https://discord.gg/dFXhpQcQ7u).

Prolua is a Lua 5.4 runtime with a project model, a test runner and a package manager, written in Zig. It is not the official Lua implementation and is not affiliated with Lua.org or PUC-Rio.

## Where to get help

| Kind of question | Where to go |
| --- | --- |
| Bug, crash, or incorrect Lua 5.4 behaviour | [Open a GitHub issue](https://github.com/matt-dunleavy/prolua/issues) |
| Build, usage, or “how do I…?” question | [Open a GitHub issue](https://github.com/matt-dunleavy/prolua/issues) and mark it as a question, or email the address below |
| Security vulnerability | Follow [SECURITY.md](SECURITY.md). Do not file a public issue. |
| Language design, the official Lua runtime, or the Lua manual | [lua.org](https://www.lua.org/) and the [Lua 5.4 reference manual](https://www.lua.org/manual/5.4/) |
| Conduct or community concerns | [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) |

## Reporting a bug

Before opening an issue, search existing issues to see whether the problem
is already known.

A useful report includes:

- The Prolua version (`prolua --version`)
- The Zig version used to build (`zig version`)
- Operating system and CPU architecture
- A short Lua script or command that reproduces the problem
- What you expected (especially if the reference Lua 5.4 interpreter
  disagrees), what happened, and any stderr output

If the script runs under the official `lua` binary, say so and include that output. Differences from Lua 5.4 are treated as bugs unless they are already documented.

## Asking a question

For usage and build questions, open an issue with:

- What you are trying to do
- The command you ran
- The full error message, if any

Please do not use the issue tracker for security reports or for questions about official Lua that are already answered in the Lua manual.

## Direct contact

Matt Dunleavy
<mdunleavy@excedra.com>

Use this address for support that should not be public, including security reports (see [SECURITY.md](SECURITY.md)). Ordinary bugs and questions are better as GitHub issues so other users can find them.

## What we support

- Building and running `prolua` from this repository
- Lua 5.4 language compatibility, as verified against the reference
  interpreter by the test suites in the tree
- The command line, the project model, the module system, the REPL and
  the standard libraries shipped here

The project is pre-1.0 and the command line and module system may still change between minor versions. Check [CHANGELOG.md](../CHANGELOG.md) before assuming a gap is unintentional.

## What we do not support

- The official Lua interpreter, compiler, or C API from Lua.org
- Modified or unofficial forks of this repository
- Third-party packages, bindings, or embeddings we do not maintain
- Guaranteed compatibility with any Lua versions
- Private consulting or guaranteed response times

## Contributing a fix

If you already have a patch, see [CONTRIBUTING.md](../CONTRIBUTING.md). Pull requests that include a reproducing script and a test are the fastest path to a fix.
