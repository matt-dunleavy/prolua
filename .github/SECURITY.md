# Security Policy

## Reporting a vulnerability

Do not report security vulnerabilities through public GitHub issues.

Email <mdunleavy@excedra.com> with:

- a description of the vulnerability and the component it affects (the
  interpreter, a standard library, the command line, the module system);
- steps to reproduce, ideally a script or a manifest and the command that
  triggers it;
- the impact as you understand it, and any mitigation you have found.

You will get an acknowledgement within three business days and an
assessment, with an expected timeline, within seven. Please keep the
report private until a fix is released; you will be credited in the
release notes unless you ask otherwise.

## Supported versions

Fixes go into the current minor version. Prolua is pre-1.0, and there is
no backport policy for older minor versions.

## What counts

Prolua runs untrusted input in three places, and a report on any of them
is in scope:

- **Lua source and bytecode.** A crash, memory error or hang in the
  lexer, parser, code generator, bytecode loader, virtual machine or a
  standard library on any input. Note that Lua itself does not promise
  to reject malicious bytecode; a `load` of untrusted binary chunks is
  unsafe in every Lua implementation, and Prolua's loader is fuzzed but
  makes no stronger guarantee.
- **The module system.** A manifest, `module.sum`, `vendor/modules.toml`
  or fetched repository that makes `prolua` read or write outside the
  project directory and the module cache, run a program other than
  `git`, or accept a tree whose hash does not match the recorded one.
- **The command line.** An argument or environment that makes a command
  behave in a way its `--help` does not describe.

Out of scope: the behaviour of the reference Lua interpreter, the
standard libraries' documented access to the file system and to `os` and
`io` (a Lua program can do what its user can do), and the Lua programs
that a user chooses to run.

## How the tree is checked

The command-line and official suites run under valgrind, the unit tests
run under a leak-checking allocator, and a mutation fuzzer covers source,
bytecode, patterns, `format`, `pack`, numerals, `utf8` and module paths.
`README.md` lists the suites and their last verified results.
