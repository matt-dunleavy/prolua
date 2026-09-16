// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Library root: what an embedder (or a tool in `src/tools/`) imports to get
//! at the interpreter. `cli/main.zig` is the stand-alone program built on top of
//! the same modules.

pub const api = @import("api.zig");
pub const state = @import("state.zig");
pub const value = @import("value.zig");
pub const proto = @import("proto.zig");
pub const opcode = @import("opcode.zig");
pub const debug = @import("debug.zig");
pub const vm = @import("vm.zig");
pub const lib = @import("lib/lib.zig");
pub const oslib = @import("lib/oslib.zig");
pub const stdio = @import("utils/stdio.zig");
pub const version = @import("version.zig");

/// The module system (docs/project/package-manager.md): what exists of it
pub const manifest = @import("module/manifest.zig");
pub const import_path = @import("module/import_path.zig");
pub const resolver = @import("module/resolver.zig");
pub const source = @import("module/source.zig");
pub const integrity = @import("module/integrity.zig");

pub const LuaState = state.LuaState;
