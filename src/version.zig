// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

const std = @import("std");

pub const VERSION_MAJOR = 0;
pub const VERSION_MINOR = 1;
pub const VERSION_PATCH = 0;
/// The three numbers as the string `VERSION` and `prolua -v` show
pub const VERSION = std.fmt.comptimePrint("{d}.{d}.{d}", .{ VERSION_MAJOR, VERSION_MINOR, VERSION_PATCH });

/// The Lua release this implementation follows
pub const LUA_VERSION = "5.4";

pub const PROGRAM_NAME = "Prolua";
pub const DESCRIPTION = "A Lua-inspired runtime for modern development environments.";
pub const AUTHORS = "Matt Dunleavy";
pub const COPYRIGHT = "Copyright (C) 2024-2026 Matt Dunleavy";
pub const LICENSE = "MIT";

/// What `prolua -v` and the REPL greeting print: the name and version on
/// one line, the copyright on the next. `test/clitest.sh` strips both lines
/// (and the reference's one-line banner) before comparing output.
pub const BANNER = PROGRAM_NAME ++ " " ++ VERSION ++ "\n" ++ COPYRIGHT;
