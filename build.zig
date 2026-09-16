// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

const std = @import("std");

// Build graph for Prolua.
//
// Test layout: every leaf module gets its own test root so that a compile
// error in one module (Zig compiles all `test` blocks reachable from a root
// into a single binary) cannot hide the results of the others.
//
//   zig build test          leaf-module suites (expected green)
//   zig build test-runtime  runtime suite rooted at src/runtime_tests.zig
//   zig build test-unit     leaf + runtime; `-Dtest-filter=` for IDE CodeLens
//   zig build test-all      unit suites plus differential and CLI harnesses
//   zig build test-<name>   one module's suite, e.g. `zig build test-lex`
//
// Each root only runs its own module's tests via a name filter, so the lexer
// tests are not repeated inside the parser binary.
const leaf_test_roots = [_]struct { name: []const u8, path: []const u8 }{
    .{ .name = "hash", .path = "src/utils/hash.zig" },
    .{ .name = "buffer", .path = "src/utils/buffer.zig" },
    .{ .name = "stdio", .path = "src/utils/stdio.zig" },
    .{ .name = "opcode", .path = "src/opcode.zig" },
    .{ .name = "lex", .path = "src/lex.zig" },
    .{ .name = "ast", .path = "src/ast.zig" },
    .{ .name = "parser", .path = "src/parser.zig" },
    .{ .name = "value", .path = "src/value.zig" },
    .{ .name = "proto", .path = "src/proto.zig" },
    .{ .name = "numeral", .path = "src/numeral.zig" },
};

// Modules that reach state.zig and below. `test-runtime` already covers them
// as a group, so these only add a per-module `test-<name>` target for working
// on one of them in isolation.
//
// lib/*.zig is absent: rooting a test there puts src/lib/ at the module
// path, which places `@import("../api.zig")` outside it. Those tests run
// through `test-runtime` / `test-unit` / `test-<libname>`.
const runtime_test_roots = [_]struct { name: []const u8, path: []const u8 }{
    .{ .name = "state", .path = "src/state.zig" },
    .{ .name = "stack", .path = "src/stack.zig" },
    .{ .name = "closure", .path = "src/closure.zig" },
    .{ .name = "string", .path = "src/string.zig" },
    .{ .name = "table", .path = "src/table.zig" },
    .{ .name = "gc", .path = "src/gc.zig" },
    .{ .name = "codegen", .path = "src/codegen.zig" },
    .{ .name = "vm", .path = "src/vm.zig" },
    .{ .name = "api", .path = "src/api.zig" },
    .{ .name = "debug", .path = "src/debug.zig" },
    .{ .name = "coroutine", .path = "src/coroutine.zig" },
    .{ .name = "dump", .path = "src/dump.zig" },
    .{ .name = "undump", .path = "src/undump.zig" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // === Library module ===
    // The interpreter as a library: `@import("prolua")` for the command
    // line and the tools here and, through
    // `b.dependency("prolua", ...).module("prolua")`, for embedders (see
    // docs/embedding.md). state.zig's default allocator is
    // std.heap.c_allocator. In release builds the frame pointer is worth
    // more as a general register to the interpreter loop (perf still
    // unwinds through DWARF).
    const prolua_mod = b.addModule("prolua", .{
        .root_source_file = b.path("src/prolua.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .omit_frame_pointer = optimize != .Debug,
    });

    // === Executable ===
    // src/cli/ is the command line; it reaches the interpreter only through
    // the `prolua` module, like the tools, so the library is compiled once.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .omit_frame_pointer = optimize != .Debug,
        .imports = &.{.{ .name = "prolua", .module = prolua_mod }},
    });

    const exe = b.addExecutable(.{
        .name = "prolua",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the interpreter");
    run_step.dependOn(&run_cmd.step);

    // `zig build disasm -- file.lua` is `prolua disasm file.lua`
    const disasm_cmd = b.addRunArtifact(exe);
    disasm_cmd.addArg("disasm");
    disasm_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| disasm_cmd.addArgs(args);
    const disasm_step = b.step("disasm", "List the bytecode of the given files (prolua disasm, luac -l -l -p format)");
    disasm_step.dependOn(&disasm_cmd.step);

    // `zig build bench [-- fib loops]` is `prolua bench --dir test/bench ...`
    const bench_cmd = b.addRunArtifact(exe);
    bench_cmd.step.dependOn(b.getInstallStep());
    bench_cmd.addArg("bench");
    bench_cmd.addArg("--dir");
    bench_cmd.addDirectoryArg(b.path("test/bench"));
    if (b.args) |args| bench_cmd.addArgs(args);
    bench_cmd.has_side_effects = true;
    const bench_step = b.step("bench", "Time the scripts in test/bench under prolua and the reference lua (prolua bench)");
    bench_step.dependOn(&bench_cmd.step);

    // === Example ===
    // examples/embed.zig is the embedding guide's program; `zig build example`
    // builds and runs it against the library module
    const example = b.addExecutable(.{
        .name = "embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/embed.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "prolua", .module = prolua_mod }},
        }),
    });
    const example_cmd = b.addRunArtifact(example);
    const example_step = b.step("example", "Build and run examples/embed.zig against the library");
    example_step.dependOn(&example_cmd.step);

    // === Documentation ===
    const docs_install = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&docs_install.step);

    // === Tests ===
    // Files under src/lib/ cannot be `zig test` roots: that makes src/lib/ the
    // module path, so `@import("../api.zig")` is rejected. Their tests live in
    // the runtime suite (`src/runtime_tests.zig`, rooted at src/). The Zig
    // extension's CodeLens still wants a single filtered step, so `test-unit`
    // is leaf + runtime and honours `-Dtest-filter=`.
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose names contain this substring");
    const user_filters: []const []const u8 = if (test_filter) |f| b.dupeStrings(&.{f}) else &.{};

    const test_step = b.step("test", "Run the leaf-module unit tests");
    const test_runtime_step = b.step("test-runtime", "Run the runtime unit tests (rooted at src/runtime_tests.zig)");
    const test_unit_step = b.step("test-unit", "Run leaf and runtime unit tests (for IDE CodeLens)");
    const test_all_step = b.step("test-all", "Run every unit test suite");

    inline for (leaf_test_roots) |root| {
        const mod = b.createModule(.{
            .root_source_file = b.path(root.path),
            .target = target,
            .optimize = optimize,
            // value.zig and proto.zig reach state.zig, whose default allocator
            // wants libc; link it everywhere so the suites stay uniform.
            .link_libc = true,
        });
        const t = b.addTest(.{
            .name = "test_" ++ root.name,
            .root_module = mod,
            // Test names are "<module>.test.<name>"; only run this module's own
            // unless the caller passed -Dtest-filter=.
            .filters = if (user_filters.len != 0) user_filters else &.{root.name ++ ".test."},
        });
        const run_t = b.addRunArtifact(t);
        const step = b.step("test-" ++ root.name, "Run the " ++ root.name ++ " unit tests");
        step.dependOn(&run_t.step);
        test_step.dependOn(&run_t.step);
        test_unit_step.dependOn(&run_t.step);
        test_all_step.dependOn(&run_t.step);
    }

    inline for (runtime_test_roots) |root| {
        const mod = b.createModule(.{
            .root_source_file = b.path(root.path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const t = b.addTest(.{
            .name = "test_" ++ root.name,
            .root_module = mod,
            .filters = if (user_filters.len != 0) user_filters else &.{root.name ++ ".test."},
        });
        const run_t = b.addRunArtifact(t);
        const step = b.step("test-" ++ root.name, "Run the " ++ root.name ++ " unit tests");
        step.dependOn(&run_t.step);
    }

    const runtime_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const runtime_tests = b.addTest(.{
        .name = "test_runtime",
        .root_module = runtime_mod,
        .filters = user_filters,
    });
    const run_runtime_tests = b.addRunArtifact(runtime_tests);
    test_runtime_step.dependOn(&run_runtime_tests.step);
    test_unit_step.dependOn(&run_runtime_tests.step);
    test_all_step.dependOn(&run_runtime_tests.step);

    // The command line's own unit tests (src/cli/), which see the interpreter
    // through the `prolua` module like the program does
    const cli_tests = b.addTest(.{
        .name = "test_cli_unit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "prolua", .module = prolua_mod }},
        }),
        .filters = user_filters,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const cli_unit_step = b.step("test-cli-unit", "Run the command line's unit tests (src/cli/)");
    cli_unit_step.dependOn(&run_cli_tests.step);
    test_unit_step.dependOn(&run_cli_tests.step);
    test_all_step.dependOn(&run_cli_tests.step);

    // src/lib/*.zig cannot be test roots (see comment above). Expose them as
    // filtered runs of the runtime suite so `zig build test-iolib` works.
    const lib_test_names = [_][]const u8{
        "auxlib", "iolib", "mathlib", "oslib", "stringlib", "utf8lib",
    };
    for (lib_test_names) |name| {
        const t = b.addTest(.{
            .name = b.fmt("test_{s}", .{name}),
            .root_module = runtime_mod,
            .filters = if (user_filters.len != 0) user_filters else &.{b.fmt("{s}.test.", .{name})},
        });
        const run_t = b.addRunArtifact(t);
        const step = b.step(b.fmt("test-{s}", .{name}), b.fmt("Run the {s} unit tests", .{name}));
        step.dependOn(&run_t.step);
    }

    // === Differential tests ===
    // Runs each script in test/diff under both the reference `lua` and the
    // built interpreter and compares the output, so the expectations are the
    // reference implementation's actual behaviour rather than a transcription
    // of it. Skips itself when no reference interpreter is installed.
    const diff_run = b.addSystemCommand(&.{"bash"});
    diff_run.addFileArg(b.path("test/difftest.sh"));
    diff_run.step.dependOn(b.getInstallStep());
    // The script shells out to the interpreter, which the build graph cannot
    // see, so it must not be cached on its inputs
    diff_run.has_side_effects = true;

    const diff_step = b.step("test-diff", "Compare output against the reference Lua interpreter");
    diff_step.dependOn(&diff_run.step);
    test_all_step.dependOn(&diff_run.step);

    // === Differential tests on a ReleaseSafe build ===
    // The safety-checked release build (bounds, overflow, `unreachable`)
    // runs the same scripts: it catches what Debug's allocator and layout
    // can hide and what ReleaseFast cannot report. Built and installed as
    // `prolua-safe` only for this step.
    const prolua_safe_mod = b.createModule(.{
        .root_source_file = b.path("src/prolua.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
        .omit_frame_pointer = true,
    });
    const safe_exe = b.addExecutable(.{
        .name = "prolua-safe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            .omit_frame_pointer = true,
            .imports = &.{.{ .name = "prolua", .module = prolua_safe_mod }},
        }),
    });
    const safe_install = b.addInstallArtifact(safe_exe, .{});
    const diff_safe = b.addSystemCommand(&.{"bash"});
    diff_safe.addFileArg(b.path("test/difftest.sh"));
    diff_safe.setEnvironmentVariable("PROLUA", b.getInstallPath(.bin, "prolua-safe"));
    diff_safe.step.dependOn(&safe_install.step);
    diff_safe.has_side_effects = true;
    // The command-line suite under valgrind, on the ReleaseSafe build (which
    // links libc and so allocates through malloc, where valgrind sees every
    // byte): reads of freed memory, uninitialised values, invalid frees, and
    // definitely-lost blocks at exit. Not part of test-all: minutes.
    const cli_valgrind = b.addSystemCommand(&.{"bash"});
    cli_valgrind.addFileArg(b.path("test/cli/clitest.sh"));
    cli_valgrind.setEnvironmentVariable("PROLUA", b.getInstallPath(.bin, "prolua-safe"));
    cli_valgrind.setEnvironmentVariable("PROLUA_WRAPPER", "valgrind -q --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite");
    cli_valgrind.setEnvironmentVariable("CLITEST_TIMEOUT", "300");
    cli_valgrind.step.dependOn(&safe_install.step);
    cli_valgrind.has_side_effects = true;
    const cli_valgrind_step = b.step("test-cli-valgrind", "Command-line suite under valgrind on the ReleaseSafe build (minutes)");
    cli_valgrind_step.dependOn(&cli_valgrind.step);

    // The differential scripts and the official suite under valgrind, on
    // the same ReleaseSafe build: the interpreter's own memory safety, which
    // the command-line cases touch only lightly. About a minute each;
    // neither is in test-all.
    const diff_valgrind = b.addSystemCommand(&.{"bash"});
    diff_valgrind.addFileArg(b.path("test/difftest.sh"));
    diff_valgrind.setEnvironmentVariable("PROLUA", b.getInstallPath(.bin, "prolua-safe"));
    diff_valgrind.setEnvironmentVariable("PROLUA_WRAPPER", "valgrind -q --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite");
    diff_valgrind.setEnvironmentVariable("DIFF_TIMEOUT", "600");
    diff_valgrind.step.dependOn(&safe_install.step);
    diff_valgrind.has_side_effects = true;
    const diff_valgrind_step = b.step("test-diff-valgrind", "Differential scripts under valgrind on the ReleaseSafe build (minutes)");
    diff_valgrind_step.dependOn(&diff_valgrind.step);

    const puc_valgrind = b.addSystemCommand(&.{"bash"});
    puc_valgrind.addFileArg(b.path("test/puctest.sh"));
    puc_valgrind.setEnvironmentVariable("PROLUA", b.getInstallPath(.bin, "prolua-safe"));
    puc_valgrind.setEnvironmentVariable("PROLUA_WRAPPER", "valgrind -q --error-exitcode=99");
    puc_valgrind.setEnvironmentVariable("PUC_TIMEOUT", "3600");
    puc_valgrind.step.dependOn(&safe_install.step);
    puc_valgrind.has_side_effects = true;
    const puc_valgrind_step = b.step("test-puc-valgrind", "Official suite under valgrind on the ReleaseSafe build (about a minute)");
    puc_valgrind_step.dependOn(&puc_valgrind.step);

    const diff_safe_step = b.step("test-diff-safe", "Differential tests on a ReleaseSafe build");
    diff_safe_step.dependOn(&diff_safe.step);
    test_all_step.dependOn(&diff_safe.step);

    // === Real-program corpus ===
    // Pure-Lua projects with their own test suites, run under the reference
    // and under the ReleaseSafe build with the output compared. Clones the
    // projects into .cache/corpus the first time (network), so it is not
    // part of `test-all`.
    const corpus_run = b.addSystemCommand(&.{"bash"});
    corpus_run.addFileArg(b.path("test/corpus/corpustest.sh"));
    corpus_run.setEnvironmentVariable("PROLUA", b.getInstallPath(.bin, "prolua-safe"));
    corpus_run.step.dependOn(&safe_install.step);
    corpus_run.has_side_effects = true;
    const corpus_step = b.step("test-corpus", "Run real pure-Lua projects' test suites under prolua and the reference");
    corpus_step.dependOn(&corpus_run.step);

    // === Fuzzing ===
    // Mutation fuzzing of the front end, the loader and the byte-oriented
    // libraries on the ReleaseSafe build (test/fuzz/fuzz.sh). Arguments
    // after `--` are the target, the case count and the seed.
    const fuzz_run = b.addSystemCommand(&.{"bash"});
    fuzz_run.addFileArg(b.path("test/fuzz/fuzz.sh"));
    if (b.args) |args| fuzz_run.addArgs(args);
    fuzz_run.setEnvironmentVariable("PROLUA", b.getInstallPath(.bin, "prolua-safe"));
    fuzz_run.step.dependOn(&safe_install.step);
    fuzz_run.has_side_effects = true;
    const fuzz_step = b.step("fuzz", "Mutation-fuzz the lexer, parser, loader and string library on a ReleaseSafe build");
    fuzz_step.dependOn(&fuzz_run.step);

    // === Command-line tests ===
    // `prolua run` and `prolua init`, the `arg` table, stdin, the REPL and
    // exit codes, each invocation compared with the expectation pinned in
    // the script (the interface is prolua's own; there is no reference).
    const cli_run = b.addSystemCommand(&.{"bash"});
    cli_run.addFileArg(b.path("test/cli/clitest.sh"));
    cli_run.step.dependOn(b.getInstallStep());
    // the memory cases run on the ReleaseSafe build (built below), whose
    // allocator gives memory back
    cli_run.setEnvironmentVariable("PROLUA_SAFE", b.getInstallPath(.bin, "prolua-safe"));
    cli_run.step.dependOn(&safe_install.step);
    cli_run.has_side_effects = true;
    const cli_step = b.step("test-cli", "Test the command line (test/cli/clitest.sh)");
    cli_step.dependOn(&cli_run.step);
    test_all_step.dependOn(&cli_run.step);

    // === Official test suite ===
    // Runs the Lua 5.4.8 test suite in test/puc under prolua and reports each
    // file against the list of files known to pass. Not part of `test-all`:
    // it takes minutes and its failures are tracked in docs/project/project.md.
    const puc_run = b.addSystemCommand(&.{"bash"});
    puc_run.addFileArg(b.path("test/puctest.sh"));
    puc_run.step.dependOn(b.getInstallStep());
    puc_run.has_side_effects = true;
    const puc_step = b.step("test-puc", "Run the official Lua 5.4.8 test suite under prolua");
    puc_step.dependOn(&puc_run.step);
}
