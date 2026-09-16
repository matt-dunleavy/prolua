// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Module paths (docs/project/package-manager.md §17): `host/a/b`. Each
//! component is lowercase DNS-safe (`a-z`, `0-9`, `-`, neither first nor
//! last), at most 63 bytes; the first component may also contain dots, and
//! when it does the path is a namespace path, publishable under that DNS
//! name. A bare name (`myapp`) is a local module without an identity.

const std = @import("std");

pub const Error = error{
    Empty,
    EmptyComponent,
    BadCharacter,
    DashAtEdge,
    DotAtEdge,
    ComponentTooLong,
    PathTooLong,
};

/// A module path becomes part of directory names, URLs and tags: the cap
/// keeps all of them well under any system's limit
pub const MAX_LEN = 255;

/// What the rule is, for a message
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.Empty => "the path is empty",
        error.EmptyComponent => "a path component is empty (a leading, trailing or doubled '/')",
        error.BadCharacter => "components may only contain a-z, 0-9 and '-' (the first may contain '.')",
        error.DashAtEdge => "a component may not start or end with '-'",
        error.DotAtEdge => "the host component may not start or end with '.', or contain '..'",
        error.ComponentTooLong => "a component may not exceed 63 bytes",
        error.PathTooLong => "the path may not exceed 255 bytes",
    };
}

pub fn validate(path: []const u8) Error!void {
    if (path.len == 0) return error.Empty;
    if (path.len > MAX_LEN) return error.PathTooLong;
    var it = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (it.next()) |c| {
        if (c.len == 0) return error.EmptyComponent;
        if (c.len > 63) return error.ComponentTooLong;
        if (c[0] == '-' or c[c.len - 1] == '-') return error.DashAtEdge;
        if (first and (c[0] == '.' or c[c.len - 1] == '.' or std.mem.indexOf(u8, c, "..") != null)) return error.DotAtEdge;
        for (c) |ch| {
            const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-' or (first and ch == '.');
            if (!ok) return error.BadCharacter;
        }
        first = false;
    }
}

/// A namespace path: its first component is a DNS name (contains a dot)
pub fn isNamespace(path: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    return std.mem.indexOfScalar(u8, path[0..end], '.') != null;
}

test "module paths" {
    try validate("github.com/matt-dunleavy/http");
    try validate("lua.excedra.com/net/http-client");
    try validate("myapp");
    try std.testing.expect(isNamespace("github.com/matt-dunleavy/http"));
    try std.testing.expect(!isNamespace("myapp"));
    try std.testing.expect(!isNamespace("myapp/sub.dir")); // only the first component counts
    try std.testing.expectError(error.Empty, validate(""));
    try std.testing.expectError(error.EmptyComponent, validate("github.com//x"));
    try std.testing.expectError(error.EmptyComponent, validate("/x"));
    try std.testing.expectError(error.BadCharacter, validate("GitHub.com/x"));
    try std.testing.expectError(error.BadCharacter, validate("a/b.c"));
    try std.testing.expectError(error.BadCharacter, validate("my app"));
    try std.testing.expectError(error.DashAtEdge, validate("a/-b"));
    try std.testing.expectError(error.DotAtEdge, validate(".com/x"));
    try std.testing.expectError(error.DotAtEdge, validate("a..b/x"));
    try std.testing.expectError(error.ComponentTooLong, validate("a/" ++ "x" ** 64));
    try std.testing.expectError(error.PathTooLong, validate("a.b/" ++ ("x" ** 60 ++ "/") ** 4 ++ "y"));
}

test "validate never crashes and agrees with itself on random input" {
    var prng = std.Random.DefaultPrng.init(3);
    const random = prng.random();
    const alphabet = "abcz09-./ABC_ \x00\xff";
    var buf: [80]u8 = undefined;
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        const len = random.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        const path = buf[0..len];
        if (validate(path)) |_| {
            // a valid path has no empty component and only the allowed bytes
            var it = std.mem.splitScalar(u8, path, '/');
            while (it.next()) |c| {
                try std.testing.expect(c.len > 0 and c.len <= 63);
                for (c) |ch| try std.testing.expect((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '.');
            }
            _ = isNamespace(path);
        } else |err| {
            _ = describe(err);
        }
    }
}
