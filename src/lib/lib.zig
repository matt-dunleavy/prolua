// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Standard library aggregator (linit.c).
//!
//! `openLibs` is the single entry point an embedder or the interpreter calls;
//! nothing else should have to know which libraries exist.

const std = @import("std");
const state = @import("../state.zig");
const api = @import("../api.zig");

pub const auxlib = @import("auxlib.zig");
pub const baselib = @import("baselib.zig");
pub const corolib = @import("corolib.zig");
pub const debuglib = @import("debuglib.zig");
pub const iolib = @import("iolib.zig");
pub const mathlib = @import("mathlib.zig");
pub const oslib = @import("oslib.zig");
pub const package = @import("package.zig");
pub const stringlib = @import("stringlib.zig");
pub const tablelib = @import("tablelib.zig");
pub const utf8lib = @import("utf8lib.zig");

/// Names recorded in `package.loaded`, so `require "string"` returns the
/// already-open library instead of searching the filesystem. Error messages
/// also walk these tables to name the function that raised them.
const module_names = [_][]const u8{
    "string", "table",     "math",  "os",      "io",
    "utf8",   "coroutine", "debug", "package",
};

/// Open every standard library into `L`'s globals.
///
/// `package` comes after the rest so `package.loaded` can be populated with
/// libraries that are already open.
pub fn openLibs(L: *state.LuaState) !void {
    try baselib.openBase(L);
    try stringlib.openString(L);
    try tablelib.openTable(L);
    try mathlib.openMath(L);
    try oslib.openOs(L);
    try iolib.openIo(L);
    try utf8lib.openUtf8(L);
    try corolib.openCoroutine(L);
    try debuglib.openDebug(L);
    try package.openPackage(L);

    for (module_names) |name| try package.markLoaded(L, name);

    // The base library lives in _G, which is itself a loaded module
    try package.loadedTable(L);
    try api.pushGlobalTable(L);
    try api.setField(L, -2, "_G");
    api.pop(L, 1);
}
