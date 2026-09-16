// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! POSIX spellings for the failures Zig reports as error names, so messages
//! read "cannot open x.lua: No such file or directory" the way C's `strerror`
//! would put it. Shared by the loader and the `io` and `os` libraries.

pub const SysError = struct { code: i64, text: []const u8 };

/// C reports failures through `errno`, and `luaL_fileresult` turns that into a
/// message and a number. Zig gives an error name instead, so map the ones a
/// file operation can produce back onto their POSIX spellings.
pub fn describe(err: anyerror) SysError {
    return switch (err) {
        error.FileNotFound => .{ .code = 2, .text = "No such file or directory" },
        error.ProcessNotFound => .{ .code = 3, .text = "No such process" },
        error.Interrupted, error.Canceled => .{ .code = 4, .text = "Interrupted system call" },
        error.InputOutput => .{ .code = 5, .text = "Input/output error" },
        error.NoDevice => .{ .code = 6, .text = "No such device or address" },
        error.OutOfMemory, error.SystemResources => .{ .code = 12, .text = "Cannot allocate memory" },
        error.AccessDenied, error.PermissionDenied => .{ .code = 13, .text = "Permission denied" },
        error.FileBusy => .{ .code = 16, .text = "Device or resource busy" },
        error.PathAlreadyExists => .{ .code = 17, .text = "File exists" },
        error.RenameAcrossMountPoints => .{ .code = 18, .text = "Invalid cross-device link" },
        error.NotDir => .{ .code = 20, .text = "Not a directory" },
        error.IsDir => .{ .code = 21, .text = "Is a directory" },
        error.SystemFdQuotaExceeded => .{ .code = 23, .text = "Too many open files in system" },
        error.ProcessFdQuotaExceeded => .{ .code = 24, .text = "Too many open files" },
        error.FileTooBig => .{ .code = 27, .text = "File too large" },
        error.NoSpaceLeft => .{ .code = 28, .text = "No space left on device" },
        error.ReadOnlyFileSystem => .{ .code = 30, .text = "Read-only file system" },
        error.NameTooLong => .{ .code = 36, .text = "File name too long" },
        error.DirNotEmpty => .{ .code = 39, .text = "Directory not empty" },
        error.SymLinkLoop => .{ .code = 40, .text = "Too many levels of symbolic links" },
        else => .{ .code = 0, .text = @errorName(err) },
    };
}
