// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

/// Base Lua version number
pub const LUA_VERSION_NUM: f64 = 504.0; // Lua 5.4

/// Minimum stack size
pub const MINSTACK: usize = 20;

/// String cache configuration
pub const STRCACHE_N: usize = 53;
pub const STRCACHE_M: usize = 2;

/// Maximum size of a chunk name in messages (LUA_IDSIZE): stock Lua's 60.
/// (Fedora's build of the reference interpreter patches it to 512, so the
/// harnesses run scripts under short relative names, where the two agree,
/// and the official suite's checks of the stock size pass.)
pub const IDSIZE: usize = 60;

/// Maximum number of local variables
pub const MAXVARS: usize = 200;

/// Maximum number of upvalues
pub const MAXUPVAL: usize = 255;

/// Maximum number of constants
pub const MAXARG_Bx: usize = (1 << 18) - 1;

/// Maximum call depth
pub const MAXCCALLS: usize = 200;

/// Garbage collection configuration
pub const GCPAUSE: usize = 200;
pub const GCSTEPMUL: usize = 100;
pub const GCSTEPSIZE: usize = 1024;

/// Memory allocation limits
pub const MAXSIZE: usize = ~@as(usize, 0);

/// String interning configuration
pub const LUAI_MAXSHORTLEN: usize = 40;
