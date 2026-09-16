// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.
//! Module sources (docs/project/package-manager.md §52, Phase 2): where a
//! module's code is fetched from, and the fetch itself through the `git`
//! command. Forge paths resolve without DNS: `github.com`, `gitlab.com` and
//! `codeberg.org` are built in, and `PROLUA_SOURCES` (`host=url-prefix;...`)
//! names a mirror or a private forge for any host. DNS discovery of a
//! publisher's own host (`_prolua` TXT records) is not implemented yet, and
//! a module on such a host says so.

const std = @import("std");
const manifest = @import("manifest.zig");

pub const Repo = struct {
    /// The clone URL
    url: []const u8,
    /// The module's directory inside the repository ("" for the root); a
    /// module in a subdirectory is tagged `<subdir>/<version>`
    subdir: []const u8,
};

const forges = [_][]const u8{ "github.com", "gitlab.com", "codeberg.org" };

/// The repository holding `module`, or null when its host has no known
/// source; strings live in `arena`
pub fn repoFor(arena: std.mem.Allocator, module: []const u8, environ: *const std.process.Environ.Map) !?Repo {
    var it = std.mem.splitScalar(u8, module, '/');
    const host = it.next() orelse return null;
    const owner = it.next() orelse return null;
    const repo = it.next() orelse return null;
    const subdir = it.rest();

    var base: ?[]const u8 = null;
    if (environ.get("PROLUA_SOURCES")) |sources| {
        var entries = std.mem.splitScalar(u8, sources, ';');
        while (entries.next()) |entry| {
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, entry[0..eq], " "), host)) base = std.mem.trim(u8, entry[eq + 1 ..], " ");
        }
    }
    if (base == null) {
        for (forges) |f| if (std.mem.eql(u8, f, host)) {
            base = try std.fmt.allocPrint(arena, "https://{s}", .{host});
        };
    }
    const b = base orelse return null;
    return .{
        .url = try std.fmt.allocPrint(arena, "{s}/{s}/{s}.git", .{ std.mem.trimEnd(u8, b, "/"), owner, repo }),
        .subdir = subdir,
    };
}

pub const FetchError = error{ GitFailed, GitMissing, NoModuleInSubdir } || std.mem.Allocator.Error || anyerror;

/// A remote that stops answering is an error, not a hang: a shallow clone
/// of one tag has ten minutes, a tag listing one
const clone_timeout_s = 600;
const list_timeout_s = 60;

/// Clone `repo` at `version` into `dest` (created; its parent must exist
/// or be creatable), without the `.git` directory. On failure `dest` is
/// not left behind, and `diagnostic` holds git's own words.
pub fn fetch(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, repo: Repo, version: []const u8, dest: []const u8, diagnostic: *[]const u8) FetchError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tag = if (repo.subdir.len > 0) try std.fmt.allocPrint(arena, "{s}/{s}", .{ repo.subdir, version }) else version;
    const tmp = try std.fmt.allocPrint(arena, "{s}.fetch-{d}", .{ dest, std.Io.Clock.awake.now(io).nanoseconds });
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(dest)) |parent| cwd.createDirPath(io, parent) catch |err| {
        diagnostic.* = try std.fmt.allocPrint(allocator, "cannot create {s}: {s}", .{ parent, @errorName(err) });
        return error.GitFailed;
    };
    // clones an interrupted earlier run left beside the destination go first
    manifest.removeStale(io, allocator, dest, ".fetch-");
    errdefer cwd.deleteTree(io, tmp) catch {};

    // git must never stop to ask for credentials: a private module is an error, not a prompt
    var env = try environ.clone(allocator);
    defer env.deinit();
    try env.put("GIT_TERMINAL_PROMPT", "0");

    const result = std.process.run(allocator, io, .{
        // core.symlinks=false: a symbolic link in the repository becomes a
        // plain file holding its target text, so a fetched tree can point
        // nowhere outside itself and every byte of it is hashed
        .argv = &.{ "git", "clone", "--quiet", "--depth", "1", "--branch", tag, "--config", "advice.detachedHead=false", "--config", "core.symlinks=false", repo.url, tmp },
        .environ_map = &env,
        .stderr_limit = .limited(64 * 1024),
        .stdout_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(clone_timeout_s), .clock = .awake } },
    }) catch |err| {
        diagnostic.* = switch (err) {
            error.FileNotFound => "git is not installed or not on PATH",
            error.Timeout => "timed out after " ++ std.fmt.comptimePrint("{d}", .{clone_timeout_s}) ++ " seconds",
            else => @errorName(err),
        };
        return if (err == error.FileNotFound) error.GitMissing else error.GitFailed;
    };
    defer allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) {
        // git's message, first line, is the diagnostic; the caller frees it
        const text = std.mem.trim(u8, result.stderr, " \r\n\t");
        const first = if (std.mem.indexOfScalar(u8, text, '\n')) |nl| text[0..nl] else text;
        diagnostic.* = try allocator.dupe(u8, first);
        allocator.free(result.stderr);
        return error.GitFailed;
    }
    allocator.free(result.stderr);

    cwd.deleteTree(io, try std.fs.path.join(arena, &.{ tmp, ".git" })) catch {};
    if (repo.subdir.len > 0) {
        const inner = try std.fs.path.join(arena, &.{ tmp, repo.subdir });
        _ = cwd.statFile(io, try std.fs.path.join(arena, &.{ inner, "module.toml" }), .{}) catch {
            diagnostic.* = try std.fmt.allocPrint(allocator, "the repository has no module.toml under {s} at tag {s}", .{ repo.subdir, tag });
            return error.NoModuleInSubdir;
        };
        moveInto(io, inner, dest) catch |err| {
            diagnostic.* = try std.fmt.allocPrint(allocator, "cannot move the clone into {s}: {s}", .{ dest, @errorName(err) });
            return error.GitFailed;
        };
        cwd.deleteTree(io, tmp) catch {};
    } else {
        moveInto(io, tmp, dest) catch |err| {
            diagnostic.* = try std.fmt.allocPrint(allocator, "cannot move the clone into {s}: {s}", .{ dest, @errorName(err) });
            return error.GitFailed;
        };
    }
}

/// Rename `from` to `dest`; when `dest` appeared meanwhile (another install
/// fetched the same version), theirs is kept and `from` discarded
fn moveInto(io: std.Io, from: []const u8, dest: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    std.Io.Dir.rename(cwd, from, cwd, dest, io) catch |err| switch (err) {
        // a directory already there: rename refuses to replace a non-empty one
        error.DirNotEmpty, error.IsDir => {
            cwd.deleteTree(io, from) catch {};
            return;
        },
        else => return err,
    };
}

/// The versions `repo` has tags for (`vX.Y.Z...`, or `<subdir>/vX.Y.Z...`
/// for a subdirectory module), from `git ls-remote --tags`, in the order
/// git lists them; strings live in `arena`
pub fn listVersions(arena: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, repo: Repo, diagnostic: *[]const u8) FetchError![]const []const u8 {
    var env = try environ.clone(arena);
    defer env.deinit();
    try env.put("GIT_TERMINAL_PROMPT", "0");
    const result = std.process.run(arena, io, .{
        .argv = &.{ "git", "ls-remote", "--tags", "--refs", repo.url },
        .environ_map = &env,
        .stderr_limit = .limited(64 * 1024),
        .stdout_limit = .limited(16 * 1024 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(list_timeout_s), .clock = .awake } },
    }) catch |err| {
        diagnostic.* = switch (err) {
            error.FileNotFound => "git is not installed or not on PATH",
            error.Timeout => "timed out after " ++ std.fmt.comptimePrint("{d}", .{list_timeout_s}) ++ " seconds",
            else => @errorName(err),
        };
        return if (err == error.FileNotFound) error.GitMissing else error.GitFailed;
    };
    if (result.term != .exited or result.term.exited != 0) {
        const text = std.mem.trim(u8, result.stderr, " \r\n\t");
        diagnostic.* = if (std.mem.indexOfScalar(u8, text, '\n')) |nl| text[0..nl] else text;
        return error.GitFailed;
    }
    const prefix = if (repo.subdir.len > 0) try std.fmt.allocPrint(arena, "refs/tags/{s}/", .{repo.subdir}) else "refs/tags/";
    var versions: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const ref = std.mem.trim(u8, line[tab + 1 ..], " \r");
        if (!std.mem.startsWith(u8, ref, prefix)) continue;
        const tag = ref[prefix.len..];
        if (tag.len < 2 or tag[0] != 'v') continue;
        _ = std.SemanticVersion.parse(tag[1..]) catch continue;
        try versions.append(arena, tag);
    }
    return versions.toOwnedSlice(arena);
}

/// The highest release among `versions`, or the highest pre-release when
/// there is no release; null when there is nothing (`@latest`)
pub fn latest(versions: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_v: std.SemanticVersion = undefined;
    for (versions) |v| {
        const sv = std.SemanticVersion.parse(v[1..]) catch continue;
        if (best) |_| {
            const best_is_release = best_v.pre == null;
            const this_is_release = sv.pre == null;
            if (best_is_release and !this_is_release) continue;
            if (!best_is_release and this_is_release) {
                best = v;
                best_v = sv;
                continue;
            }
            if (std.SemanticVersion.order(sv, best_v) == .gt) {
                best = v;
                best_v = sv;
            }
        } else {
            best = v;
            best_v = sv;
        }
    }
    return best;
}

test "latest" {
    try std.testing.expectEqualStrings("v1.10.0", latest(&.{ "v1.9.0", "v1.10.0", "v1.2.0" }).?);
    try std.testing.expectEqualStrings("v1.0.0", latest(&.{ "v1.1.0-rc.1", "v1.0.0" }).?);
    try std.testing.expectEqualStrings("v1.1.0-rc.2", latest(&.{ "v1.1.0-rc.1", "v1.1.0-rc.2" }).?);
    try std.testing.expect(latest(&.{}) == null);
}

test "forge repositories" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try repoFor(arena, "github.com/matt-dunleavy/http", &env)).?;
    try std.testing.expectEqualStrings("https://github.com/matt-dunleavy/http.git", r.url);
    try std.testing.expectEqualStrings("", r.subdir);
    const s = (try repoFor(arena, "gitlab.com/a/b/tools/x", &env)).?;
    try std.testing.expectEqualStrings("https://gitlab.com/a/b.git", s.url);
    try std.testing.expectEqualStrings("tools/x", s.subdir);
    try std.testing.expect((try repoFor(arena, "example.com/a/b", &env)) == null);
    try env.put("PROLUA_SOURCES", "example.com=file:///srv/git/; other.org=https://mirror.other.org/git");
    const e = (try repoFor(arena, "example.com/a/b", &env)).?;
    try std.testing.expectEqualStrings("file:///srv/git/a/b.git", e.url);
    const o = (try repoFor(arena, "other.org/x/y", &env)).?;
    try std.testing.expectEqualStrings("https://mirror.other.org/git/x/y.git", o.url);
}

test "repoFor never crashes on odd paths and source lists" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PROLUA_SOURCES", ";=;a.b=;=x;host.test=https://h/;host.test");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = [_][]const u8{ "", "/", "//", "a", "a/b", "a/b/", "github.com", "github.com/x", "github.com/x/y/z/w", "host.test/o/r", "a.b/c/d" };
    for (paths) |p| {
        const r = try repoFor(arena, p, &env);
        if (r) |repo| try std.testing.expect(std.mem.endsWith(u8, repo.url, ".git"));
    }
    try std.testing.expectEqualStrings("https://h/o/r.git", (try repoFor(arena, "host.test/o/r", &env)).?.url);
}
