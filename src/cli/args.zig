// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! The command-line grammar: `prolua [command] [options]` with the commands
//! `run` and `init`, `--version` and `--help`, and the REPL when there is
//! no command (docs/project/project.md Part 3.2). Usage errors print their
//! message here and return `error.Usage`; the caller exits with 2.

const std = @import("std");
const prolua = @import("prolua");
const stdio = prolua.stdio;
const main = @import("main.zig");
const bench = @import("bench.zig");
const add = @import("add.zig");
const install = @import("install.zig");
const eval = @import("eval.zig");

/// A `-e` chunk or a `-l` library, in command-line order
pub const Eval = struct {
    kind: enum { eval, lib },
    text: []const u8,
};

pub const RunOptions = struct {
    evals: []const Eval = &.{},
    warn: bool = false,
    no_env: bool = false,
    interactive: bool = false,
    /// The target as written: a file, a directory or `-`; null when absent
    target: ?[]const u8 = null,
    /// Its position in argv (argv.len when absent): everything before it is
    /// the interpreter and its options, for the negative indices of `arg`
    target_index: usize,
    /// Everything after the target: `arg[1..]`
    args: []const []const u8 = &.{},
};

pub const Command = union(enum) {
    /// No arguments at all
    repl,
    version,
    /// `--help`, or `<command> --help` (the command's name)
    help: ?[]const u8,
    run: RunOptions,
    /// `init [module path]`
    init: ?[]const u8,
    /// `disasm <file>...`
    disasm: []const []const u8,
    /// `bench [flags] [name...]`
    bench: bench.Options,
    /// `test [name...]`
    run_tests: []const []const u8,
    /// `add <module>[@version] [--path dir]`
    add: add.Options,
    /// `tree`
    tree,
    /// `install [--frozen]`
    install: install.Options,
    /// `remove <module>`
    remove: []const u8,
    /// `update [module...]`
    update: []const []const u8,
    /// `vendor`
    vendor,
    /// `verify`
    verify,
    /// `why <module>`
    why: []const u8,
    /// `clean`
    clean,
    /// `eval [--print] <code> [args...]`
    eval: eval.Options,
};

pub const ParseError = error{ Usage, OutOfMemory };

pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) ParseError!Command {
    if (argv.len <= 1) return .repl;
    const cmd = argv[1];
    if (eql(cmd, "--version") or eql(cmd, "-v")) return .version;
    if (eql(cmd, "--help") or eql(cmd, "-h") or eql(cmd, "help")) {
        return .{ .help = if (argv.len > 2) argv[2] else null };
    }
    if (eql(cmd, "run")) return parseRun(allocator, argv);
    if (eql(cmd, "init")) return parseInit(argv);
    if (eql(cmd, "disasm")) return parseDisasm(argv);
    if (eql(cmd, "bench")) return parseBench(argv);
    if (eql(cmd, "test")) return parseTest(argv);
    if (eql(cmd, "add")) return parseAdd(argv);
    if (eql(cmd, "tree")) return parseTree(argv);
    if (eql(cmd, "install")) return parseInstall(argv);
    if (eql(cmd, "remove")) return parseRemove(argv);
    if (eql(cmd, "update")) return parseUpdate(argv);
    if (eql(cmd, "vendor")) return parseVendor(argv);
    if (eql(cmd, "verify")) return parseVerify(argv);
    if (eql(cmd, "why")) return parseWhy(argv);
    if (eql(cmd, "clean")) return parseClean(argv);
    if (eql(cmd, "eval")) return parseEval(argv);
    if (cmd.len > 0 and cmd[0] == '-') {
        return usageError("unknown option '{s}'", .{cmd}, null);
    }
    const looks_like_a_file = std.mem.indexOfScalar(u8, cmd, '.') != null or std.mem.indexOfScalar(u8, cmd, '/') != null;
    if (looks_like_a_file) {
        return usageError("unknown command '{s}' (to run a script: prolua run {s})", .{ cmd, cmd }, null);
    }
    return usageError("unknown command '{s}'", .{cmd}, null);
}

fn parseRun(allocator: std.mem.Allocator, argv: []const []const u8) ParseError!Command {
    var opts = RunOptions{ .target_index = argv.len };
    var evals: std.ArrayList(Eval) = .empty;
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (eql(a, "--")) {
            // end of flags: the next word, if any, is the target
            if (i + 1 < argv.len) {
                opts.target = argv[i + 1];
                opts.target_index = i + 1;
                opts.args = argv[i + 2 ..];
            }
            break;
        }
        if (a.len < 2 or a[0] != '-') {
            // the target (a file, a directory, or "-" for stdin)
            opts.target = a;
            opts.target_index = i;
            opts.args = argv[i + 1 ..];
            break;
        }
        if (eql(a, "-h") or eql(a, "--help")) return .{ .help = "run" };
        if (eql(a, "-W") or eql(a, "--warn")) {
            opts.warn = true;
        } else if (eql(a, "-E") or eql(a, "--no-env")) {
            opts.no_env = true;
        } else if (eql(a, "-i") or eql(a, "--interactive")) {
            opts.interactive = true;
        } else if (eql(a, "-e") or eql(a, "--eval") or eql(a, "-l") or eql(a, "--lib")) {
            if (i + 1 >= argv.len) return usageError("'{s}' needs an argument", .{a}, "run");
            i += 1;
            try evals.append(allocator, .{ .kind = if (a[1] == 'e' or eql(a, "--eval")) .eval else .lib, .text = argv[i] });
        } else if (std.mem.startsWith(u8, a, "--eval=")) {
            try evals.append(allocator, .{ .kind = .eval, .text = a["--eval=".len..] });
        } else if (std.mem.startsWith(u8, a, "--lib=")) {
            try evals.append(allocator, .{ .kind = .lib, .text = a["--lib=".len..] });
        } else {
            return usageError("unknown flag '{s}' for run", .{a}, "run");
        }
    }
    opts.evals = try evals.toOwnedSlice(allocator);
    return .{ .run = opts };
}

fn parseInit(argv: []const []const u8) ParseError!Command {
    if (argv.len > 2 and (eql(argv[2], "-h") or eql(argv[2], "--help"))) return .{ .help = "init" };
    if (argv.len > 3) return usageError("init takes at most one argument, the module path", .{}, "init");
    if (argv.len == 3 and argv[2].len > 0 and argv[2][0] == '-') return usageError("unknown flag '{s}' for init", .{argv[2]}, "init");
    return .{ .init = if (argv.len == 3) argv[2] else null };
}

fn parseDisasm(argv: []const []const u8) ParseError!Command {
    if (argv.len > 2 and (eql(argv[2], "-h") or eql(argv[2], "--help"))) return .{ .help = "disasm" };
    var i: usize = 2;
    var files: []const []const u8 = argv[2..];
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (eql(a, "--")) {
            files = argv[i + 1 ..];
            break;
        }
        if (a.len > 1 and a[0] == '-') return usageError("unknown flag '{s}' for disasm", .{a}, "disasm");
    }
    if (files.len == 0) return usageError("disasm needs at least one file", .{}, "disasm");
    return .{ .disasm = files };
}

fn parseAdd(argv: []const []const u8) ParseError!Command {
    var opts = add.Options{ .spec = "" };
    var have_spec = false;
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (eql(a, "-h") or eql(a, "--help")) return .{ .help = "add" };
        if (eql(a, "--path")) {
            if (i + 1 >= argv.len) return usageError("'--path' needs a directory", .{}, "add");
            i += 1;
            opts.path = argv[i];
        } else if (std.mem.startsWith(u8, a, "--path=")) {
            opts.path = a["--path=".len..];
        } else if (a.len > 1 and a[0] == '-') {
            return usageError("unknown flag '{s}' for add", .{a}, "add");
        } else if (have_spec) {
            return usageError("add takes one module; got '{s}' and '{s}'", .{ opts.spec, a }, "add");
        } else {
            opts.spec = a;
            have_spec = true;
        }
    }
    if (!have_spec) return usageError("add needs a module path", .{}, "add");
    return .{ .add = opts };
}

fn parseInstall(argv: []const []const u8) ParseError!Command {
    var opts = install.Options{};
    for (argv[2..]) |a| {
        if (eql(a, "-h") or eql(a, "--help")) return .{ .help = "install" };
        if (eql(a, "--frozen")) {
            opts.frozen = true;
        } else if (a.len > 1 and a[0] == '-') {
            return usageError("unknown flag '{s}' for install", .{a}, "install");
        } else {
            return usageError("install takes no arguments", .{}, "install");
        }
    }
    return .{ .install = opts };
}

fn parseRemove(argv: []const []const u8) ParseError!Command {
    if (argv.len > 2 and (eql(argv[2], "-h") or eql(argv[2], "--help"))) return .{ .help = "remove" };
    if (argv.len != 3) return usageError("remove takes one module path", .{}, "remove");
    if (argv[2].len > 1 and argv[2][0] == '-') return usageError("unknown flag '{s}' for remove", .{argv[2]}, "remove");
    return .{ .remove = argv[2] };
}

fn parseUpdate(argv: []const []const u8) ParseError!Command {
    if (argv.len > 2 and (eql(argv[2], "-h") or eql(argv[2], "--help"))) return .{ .help = "update" };
    for (argv[2..]) |a| {
        if (a.len > 1 and a[0] == '-') return usageError("unknown flag '{s}' for update", .{a}, "update");
    }
    return .{ .update = argv[2..] };
}

fn parseVendor(argv: []const []const u8) ParseError!Command {
    if (argv.len > 2 and (eql(argv[2], "-h") or eql(argv[2], "--help"))) return .{ .help = "vendor" };
    if (argv.len > 2) return usageError("vendor takes no arguments", .{}, "vendor");
    return .vendor;
}

fn parseVerify(argv: []const []const u8) ParseError!Command {
    if (argv.len > 2 and (eql(argv[2], "-h") or eql(argv[2], "--help"))) return .{ .help = "verify" };
    if (argv.len > 2) return usageError("verify takes no arguments", .{}, "verify");
    return .verify;
}

fn parseWhy(argv: []const []const u8) ParseError!Command {
    if (argv.len > 2 and (eql(argv[2], "-h") or eql(argv[2], "--help"))) return .{ .help = "why" };
    if (argv.len != 3) return usageError("why takes one module path", .{}, "why");
    if (argv[2].len > 1 and argv[2][0] == '-') return usageError("unknown flag '{s}' for why", .{argv[2]}, "why");
    return .{ .why = argv[2] };
}

fn parseClean(argv: []const []const u8) ParseError!Command {
    if (argv.len > 2 and (eql(argv[2], "-h") or eql(argv[2], "--help"))) return .{ .help = "clean" };
    if (argv.len > 2) return usageError("clean takes no arguments", .{}, "clean");
    return .clean;
}

fn parseEval(argv: []const []const u8) ParseError!Command {
    var opts = eval.Options{ .code = "" };
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (eql(a, "--")) {
            i += 1;
            break;
        }
        if (a.len < 2 or a[0] != '-') break;
        if (eql(a, "-h") or eql(a, "--help")) return .{ .help = "eval" };
        if (eql(a, "-p") or eql(a, "--print")) {
            opts.print = true;
        } else {
            return usageError("unknown flag '{s}' for eval", .{a}, "eval");
        }
    }
    if (i >= argv.len) return usageError("eval needs the code to run", .{}, "eval");
    opts.code = argv[i];
    opts.before = argv[0..i];
    opts.args = argv[i + 1 ..];
    return .{ .eval = opts };
}

fn parseTree(argv: []const []const u8) ParseError!Command {
    if (argv.len > 2 and (eql(argv[2], "-h") or eql(argv[2], "--help"))) return .{ .help = "tree" };
    if (argv.len > 2) return usageError("tree takes no arguments", .{}, "tree");
    return .tree;
}

fn parseTest(argv: []const []const u8) ParseError!Command {
    if (argv.len > 2 and (eql(argv[2], "-h") or eql(argv[2], "--help"))) return .{ .help = "test" };
    for (argv[2..]) |a| {
        if (a.len > 1 and a[0] == '-') return usageError("unknown flag '{s}' for test", .{a}, "test");
    }
    return .{ .run_tests = argv[2..] };
}

fn parseBench(argv: []const []const u8) ParseError!Command {
    var opts = bench.Options{};
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (eql(a, "--")) {
            opts.names = argv[i + 1 ..];
            return .{ .bench = opts };
        }
        if (a.len < 2 or a[0] != '-') break;
        if (eql(a, "-h") or eql(a, "--help")) return .{ .help = "bench" };
        if (eql(a, "--no-lua")) {
            opts.no_lua = true;
        } else if (eql(a, "--dir") or eql(a, "--runs") or eql(a, "--lua")) {
            if (i + 1 >= argv.len) return usageError("'{s}' needs an argument", .{a}, "bench");
            i += 1;
            if (eql(a, "--dir")) {
                opts.dir = argv[i];
            } else if (eql(a, "--lua")) {
                opts.lua = argv[i];
            } else {
                opts.runs = std.fmt.parseInt(u32, argv[i], 10) catch 0;
                if (opts.runs == 0) return usageError("'--runs' needs a positive number, not '{s}'", .{argv[i]}, "bench");
            }
        } else {
            return usageError("unknown flag '{s}' for bench", .{a}, "bench");
        }
    }
    opts.names = argv[i..];
    return .{ .bench = opts };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Report a usage error on stderr, with the usage of `command` after it
fn usageError(comptime fmt: []const u8, args: anytype, command: ?[]const u8) ParseError {
    if (!@import("builtin").is_test) {
        stdio.eprint("{s}: " ++ fmt ++ "\n", .{main.default_progname} ++ args);
        printUsageTo(true, command);
    }
    return error.Usage;
}

/// `--help`: the general usage, or a command's
pub fn printHelp(command: ?[]const u8) void {
    printUsageTo(false, command);
}

fn printUsageTo(to_stderr: bool, command: ?[]const u8) void {
    const text: []const u8 = if (command) |c|
        (if (eql(c, "run")) run_usage else if (eql(c, "init")) init_usage else if (eql(c, "disasm")) disasm_usage else if (eql(c, "bench")) bench_usage else if (eql(c, "test")) test_usage else if (eql(c, "add")) add_usage else if (eql(c, "tree")) tree_usage else if (eql(c, "install")) install_usage else if (eql(c, "remove")) remove_usage else if (eql(c, "update")) update_usage else if (eql(c, "vendor")) vendor_usage else if (eql(c, "verify")) verify_usage else if (eql(c, "why")) why_usage else if (eql(c, "clean")) clean_usage else if (eql(c, "eval")) eval_usage else general_usage)
    else
        general_usage;
    if (to_stderr) stdio.eprint("{s}", .{text}) else stdio.print("{s}", .{text});
}

const general_usage =
    \\Usage: prolua [command] [options]
    \\
    \\Commands:
    \\  run [flags] <target> [args...]   run a .lua file, a project directory, or - (stdin)
    \\  eval [--print] <code> [args...]  run code given on the command line
    \\  init [module path]               create a project in this directory
    \\  disasm <file>...                 list the bytecode of each file (luac -l -l -p format)
    \\  bench [flags] [name...]          time benchmark scripts against the reference lua
    \\  test [name...]                   run the project's tests (tests/*_test.lua)
    \\  add <module>[@ver] [--path dir]  declare a dependency in module.toml and install it
    \\  remove <module>                  drop a dependency and install
    \\  update [module...]               move dependencies to their latest release and install
    \\  install [--frozen]               fetch the dependencies into the cache, write module.sum
    \\  vendor                           copy the dependencies into vendor/ and use them from there
    \\  verify                           check cached and vendored modules against module.sum
    \\  tree                             show the dependency graph and where each module is
    \\  why <module>                     show every chain of dependencies that brings a module in
    \\  clean                            remove the module cache
    \\
    \\Options:
    \\  -v, --version                    print the version
    \\  -h, --help                       print this help; `prolua <command> --help` for a command's
    \\
    \\With no command, prolua starts the REPL on a terminal and runs standard input otherwise.
    \\
;

const run_usage =
    \\Usage: prolua run [flags] <target> [args...]
    \\
    \\<target> is a .lua file, a project directory (its src/main.lua runs), or -
    \\for standard input. Inside a project, <target> may be omitted and the
    \\project's src/main.lua runs. Everything after <target> becomes arg[1],
    \\arg[2], ... in the script; <target> is arg[0].
    \\
    \\Flags (before the target):
    \\  -e, --eval <code>           run <code> before the target (repeatable, in order)
    \\  -l, --lib <name[=global]>   require <name> into a global (repeatable)
    \\  -i, --interactive           enter the REPL after the target
    \\  -W, --warn                  turn warnings on
    \\  -E, --no-env                ignore LUA_INIT, LUA_PATH and LUA_CPATH
    \\  --                          end of flags; the next word is the target
    \\
;

const init_usage =
    \\Usage: prolua init [module path]
    \\
    \\Creates module.toml and src/main.lua in the current directory. The module
    \\path is the argument when given, otherwise the directory's name. A path
    \\whose first component is a DNS name (github.com/matt-dunleavy/http) is a
    \\namespace path; a bare name (myapp) is a local module.
    \\
;

const disasm_usage =
    \\Usage: prolua disasm <file>...
    \\
    \\Compiles each file (source or precompiled) and lists its functions in
    \\the format of `luac -l -l -p`: header, instructions, constants, locals
    \\and upvalues. `--` ends the flags, for a file whose name starts with -.
    \\
;

const bench_usage =
    \\Usage: prolua bench [flags] [name...]
    \\
    \\Runs each <name>.lua of the benchmark directory (every script when no
    \\name is given) as a whole process under this interpreter and under the
    \\reference lua, and prints the best time of the runs and the ratio.
    \\
    \\Flags:
    \\  --dir <directory>   the scripts (default: test/bench)
    \\  --runs <n>          runs per script, best one counts (default: 3)
    \\  --lua <path>        the reference interpreter (default: lua on PATH)
    \\  --no-lua            time this interpreter alone
    \\
;

const add_usage =
    \\Usage: prolua add <module>[@<version>|@latest] [--path <dir>]
    \\
    \\Declares <module> in [dependencies] of this project's module.toml at
    \\<version> (vMAJOR.MINOR.PATCH), or at the highest release its source
    \\has a tag for (@latest, the default), then runs install. With --path,
    \\the checkout at <dir> provides the module (its module.toml must name
    \\it), is recorded as [replacements."<module>"] path = "...", and
    \\supplies the default version.
    \\
;

const remove_usage =
    \\Usage: prolua remove <module>
    \\
    \\Drops <module> from [dependencies] of this project's module.toml and
    \\runs install, so [indirectDependencies] and module.sum shrink to what
    \\the graph still needs. A [replacements] entry for it is kept.
    \\
;

const update_usage =
    \\Usage: prolua update [module...]
    \\
    \\Moves every direct dependency (or the named ones) to the highest
    \\release its source has a tag for, then runs install. Replaced and
    \\vendored modules have no source to ask and are left as they are.
    \\
;

const install_usage =
    \\Usage: prolua install [--frozen]
    \\
    \\Makes every module this project depends on available: walks the graph
    \\from module.toml selecting the highest version anyone asks for, fetches
    \\into the cache (through git) what no replacement or vendor/ provides,
    \\checks each cached tree against module.sum and records new ones, then
    \\writes [indirectDependencies] and bumps a direct dependency whose
    \\selected version rose. Sources: github.com, gitlab.com, codeberg.org,
    \\and PROLUA_SOURCES=host=url-prefix[;...] for others.
    \\
    \\  --frozen   fail instead of changing module.toml or module.sum (for CI)
    \\
;

const vendor_usage =
    \\Usage: prolua vendor
    \\
    \\Copies every module this project depends on into vendor/<module path>/
    \\and writes vendor/modules.toml, resolving and fetching as install does
    \\first. From then on modules load from vendor/ only, and changing the
    \\dependencies without running prolua vendor again is an error.
    \\
;

const verify_usage =
    \\Usage: prolua verify
    \\
    \\Hashes every module.sum entry that is in the cache and every module in
    \\vendor/ again and compares them with what module.sum and
    \\vendor/modules.toml record; also checks that vendor/ matches the
    \\current module.toml and module.sum. Exit status 1 on any mismatch.
    \\
;

const why_usage =
    \\Usage: prolua why <module>
    \\
    \\Prints every chain of declared dependencies from this project down to
    \\<module>, one tree per chain, so a module in the graph can be traced
    \\to the direct dependency that brings it in. Exit status 1 when the
    \\module is not in the graph.
    \\
;

const clean_usage =
    \\Usage: prolua clean
    \\
    \\Removes the module cache ($PROLUA_CACHE, $XDG_CACHE_HOME/prolua or
    \\~/.cache/prolua, its modules/ directory); the next install or run
    \\fetches again. A project's vendor/ is not touched.
    \\
;

const eval_usage =
    \\Usage: prolua eval [--print] <code> [args...]
    \\
    \\Runs <code> as a Lua chunk, with this project's modules resolving when
    \\the working directory is in one. Everything after <code> is arg[1],
    \\arg[2], ... With --print (-p), <code> is an expression list and its
    \\values are printed. `--` ends the flags, for code starting with -.
    \\
;

const tree_usage =
    \\Usage: prolua tree
    \\
    \\Prints this project's dependency graph: each module's declared
    \\dependencies with their versions and where each is placed (a
    \\replacement, vendor/, the cache), marking modules nothing places as
    \\missing. Exit status 1 when any is missing.
    \\
;

const test_usage =
    \\Usage: prolua test [name...]
    \\
    \\Runs the project's tests: every tests/<name>_test.lua, or those named.
    \\Each file runs in its own state, with this project's modules resolving
    \\and tests/ on package.path for shared helpers; it passes when it
    \\returns without an error. Exit status 1 when any file failed.
    \\
;

test "the grammar" {
    const a = std.testing.allocator;
    try std.testing.expect((try parse(a, &.{"prolua"})) == .repl);
    try std.testing.expect((try parse(a, &.{ "prolua", "--version" })) == .version);
    try std.testing.expect((try parse(a, &.{ "prolua", "-h" })) == .help);

    const r = try parse(a, &.{ "prolua", "run", "-e", "x=1", "--warn", "s.lua", "-e", "not-a-flag" });
    defer a.free(r.run.evals);
    try std.testing.expectEqualStrings("s.lua", r.run.target.?);
    try std.testing.expectEqual(@as(usize, 5), r.run.target_index);
    try std.testing.expectEqual(@as(usize, 2), r.run.args.len);
    try std.testing.expect(r.run.warn and r.run.evals.len == 1 and r.run.evals[0].kind == .eval);

    const stdin = try parse(a, &.{ "prolua", "run", "-" });
    try std.testing.expectEqualStrings("-", stdin.run.target.?);

    const dd = try parse(a, &.{ "prolua", "run", "--", "-weird.lua", "a" });
    try std.testing.expectEqualStrings("-weird.lua", dd.run.target.?);
    try std.testing.expectEqual(@as(usize, 1), dd.run.args.len);

    const none = try parse(a, &.{ "prolua", "run", "-E" });
    try std.testing.expect(none.run.target == null and none.run.no_env);
    try std.testing.expectEqual(@as(usize, 3), none.run.target_index);

    try std.testing.expectEqualStrings("github.com/x/y", (try parse(a, &.{ "prolua", "init", "github.com/x/y" })).init.?);
    try std.testing.expect((try parse(a, &.{ "prolua", "init" })).init == null);

    const d = try parse(a, &.{ "prolua", "disasm", "a.lua", "b.luac" });
    try std.testing.expectEqual(@as(usize, 2), d.disasm.len);
    try std.testing.expectEqualStrings("-x.lua", (try parse(a, &.{ "prolua", "disasm", "--", "-x.lua" })).disasm[0]);
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "disasm" }));
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "disasm", "-l", "a.lua" }));

    const bn = try parse(a, &.{ "prolua", "bench", "--runs", "5", "--dir", "d", "--no-lua", "fib", "loops" });
    try std.testing.expectEqual(@as(u32, 5), bn.bench.runs);
    try std.testing.expectEqualStrings("d", bn.bench.dir);
    try std.testing.expect(bn.bench.no_lua and bn.bench.names.len == 2);
    try std.testing.expectEqual(@as(usize, 0), (try parse(a, &.{ "prolua", "bench" })).bench.names.len);
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "bench", "--runs", "x" }));
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "bench", "--dir" }));
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "bench", "-q" }));

    try std.testing.expectEqual(@as(usize, 2), (try parse(a, &.{ "prolua", "test", "json", "uri" })).run_tests.len);
    try std.testing.expectEqual(@as(usize, 0), (try parse(a, &.{ "prolua", "test" })).run_tests.len);
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "test", "-v" }));

    const ad = try parse(a, &.{ "prolua", "add", "example.com/x/y@v1.0.0", "--path", "../y" });
    try std.testing.expectEqualStrings("example.com/x/y@v1.0.0", ad.add.spec);
    try std.testing.expectEqualStrings("../y", ad.add.path.?);
    try std.testing.expect((try parse(a, &.{ "prolua", "add", "example.com/x/y" })).add.path == null);
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "add" }));
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "add", "a", "b" }));
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "add", "x", "--path" }));
    try std.testing.expect((try parse(a, &.{ "prolua", "tree" })) == .tree);
    try std.testing.expect((try parse(a, &.{ "prolua", "vendor" })) == .vendor);
    try std.testing.expect((try parse(a, &.{ "prolua", "verify" })) == .verify);
    try std.testing.expect((try parse(a, &.{ "prolua", "clean" })) == .clean);
    const ev = try parse(a, &.{ "prolua", "eval", "-p", "1 + 1", "x", "y" });
    try std.testing.expect(ev.eval.print);
    try std.testing.expectEqualStrings("1 + 1", ev.eval.code);
    try std.testing.expectEqual(@as(usize, 2), ev.eval.args.len);
    try std.testing.expectEqual(@as(usize, 3), ev.eval.before.len);
    try std.testing.expectEqualStrings("-x", (try parse(a, &.{ "prolua", "eval", "--", "-x" })).eval.code);
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "eval" }));
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "eval", "--bogus", "1" }));
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "clean", "x" }));
    try std.testing.expectEqualStrings("example.com/x/y", (try parse(a, &.{ "prolua", "why", "example.com/x/y" })).why);
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "why" }));
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "verify", "x" }));
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "vendor", "x" }));
    try std.testing.expect(!(try parse(a, &.{ "prolua", "install" })).install.frozen);
    try std.testing.expect((try parse(a, &.{ "prolua", "install", "--frozen" })).install.frozen);
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "install", "x" }));
    try std.testing.expectEqualStrings("example.com/x/y", (try parse(a, &.{ "prolua", "remove", "example.com/x/y" })).remove);
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "remove" }));
    try std.testing.expectEqual(@as(usize, 1), (try parse(a, &.{ "prolua", "update", "example.com/x/y" })).update.len);
    try std.testing.expectEqual(@as(usize, 0), (try parse(a, &.{ "prolua", "update" })).update.len);
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "tree", "x" }));

    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "file.lua" }));
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "frobnicate" }));
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "run", "-e" }));
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "run", "--bogus", "x.lua" }));
    try std.testing.expectError(error.Usage, parse(a, &.{ "prolua", "init", "a", "b" }));
}
