// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Test root for the runtime modules (`zig build test-runtime`).
//!
//! Zig only collects `test` blocks from files a test actually references, so
//! the modules are listed here explicitly. Each `_ = @import` pulls in that
//! file's tests without touching the executable's entry point.
//!

test {
    _ = @import("numeral.zig");
    _ = @import("value.zig");
    _ = @import("string.zig");
    _ = @import("table.zig");
    _ = @import("gc.zig");
    _ = @import("state.zig");
    _ = @import("stack.zig");
    _ = @import("closure.zig");
    _ = @import("vm.zig");
    _ = @import("api.zig");
    _ = @import("lib/auxlib.zig");
    _ = @import("lib/baselib.zig");
    _ = @import("lib/iolib.zig");
    _ = @import("lib/mathlib.zig");
    _ = @import("lib/oslib.zig");
    _ = @import("lib/stringlib.zig");
    _ = @import("lib/utf8lib.zig");
    _ = @import("codegen.zig");
    _ = @import("debug.zig");
    _ = @import("coroutine.zig");
    _ = @import("dump.zig");
    _ = @import("undump.zig");
}
