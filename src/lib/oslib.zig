// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Operating system facilities (loslib.c).
//!
//! The C original delegates the calendar to `<time.h>`: `mktime`, `localtime`
//! and `strftime` do the work and Lua only marshals values. Zig has none of
//! those, so the proleptic Gregorian arithmetic, the local-time offset (read
//! from the system's TZif database) and a C-locale `strftime` are all
//! implemented here.
//!
//! `os.setlocale` calls libc (see its note on `os.date` and numerals). The
//! date names below are the only ones this interpreter knows.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("../api.zig");
const syserr = @import("../utils/syserr.zig");
const aux = @import("auxlib.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");
const stdio = @import("../utils/stdio.zig");
const iolib = @import("iolib.zig");

pub fn openOs(L: *state.LuaState) !void {
    try aux.registerLib(L, "os", &syslib);
    api.pop(L, 1);
}

const syslib = [_]aux.Reg{
    .{ .name = "clock", .func = os_clock },
    .{ .name = "date", .func = os_date },
    .{ .name = "difftime", .func = os_difftime },
    .{ .name = "execute", .func = os_execute },
    .{ .name = "exit", .func = os_exit },
    .{ .name = "getenv", .func = os_getenv },
    .{ .name = "remove", .func = os_remove },
    .{ .name = "rename", .func = os_rename },
    .{ .name = "setlocale", .func = os_setlocale },
    .{ .name = "time", .func = os_time },
    .{ .name = "tmpname", .func = os_tmpname },
};

// === Environment ===

/// `std.process.Environ` is only reachable through the `std.process.Init` the
/// runtime hands to `main`, which this library never sees. Reading libc's
/// `environ` gives the same answer without threading state through the VM.
const have_environ = builtin.link_libc and switch (builtin.os.tag) {
    .windows, .wasi, .emscripten => false,
    else => true,
};

/// The value of `key`, or null when unset. The result points into the process
/// environment block and stays valid for the life of the process.
pub fn getEnv(key: []const u8) ?[]const u8 {
    if (have_environ) {
        var i: usize = 0;
        while (std.c.environ[i]) |entry| : (i += 1) {
            const pair = std.mem.span(entry);
            if (pair.len > key.len and pair[key.len] == '=' and
                std.mem.eql(u8, pair[0..key.len], key))
            {
                return pair[key.len + 1 ..];
            }
        }
    }
    return null;
}

/// The parent environment, in the shape `std.process.spawn` wants for a child.
pub fn processEnviron() std.process.Environ {
    if (have_environ) {
        var n: usize = 0;
        while (std.c.environ[n] != null) n += 1;
        const block: [:null]const ?[*:0]const u8 = @ptrCast(std.c.environ[0..n :null]);
        return .{ .block = .{ .slice = block } };
    }
    return .empty;
}

// === Civil calendar arithmetic ===

const secs_per_day: i64 = 24 * 60 * 60;

/// Years outside this range cannot be represented by a `struct tm`, and are
/// where C's `gmtime` starts returning NULL; `os.date` reports them as
/// unrepresentable rather than printing an absurd year.
const min_year: i64 = -9999;
const max_year: i64 = 9999999;

const Civil = struct { year: i64, mon: i64, day: i64 };

/// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard
/// Hinnant's `days_from_civil`). `mon` must be 1..12; `day` need not be in
/// 1..31 because the result is linear in it, which is what lets `os.time`
/// normalize an out-of-range date the way `mktime` does.
fn daysFromCivil(year: i64, mon: i64, day: i64) i64 {
    const y = year - @as(i64, if (mon <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = mon + @as(i64, if (mon > 2) -3 else 9);
    const doy = @divTrunc(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Inverse of `daysFromCivil` (Hinnant's `civil_from_days`).
fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) -
        @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const mon = mp + @as(i64, if (mp < 10) 3 else -9);
    return .{ .year = y + @as(i64, if (mon <= 2) 1 else 0), .mon = mon, .day = day };
}

fn isLeapYear(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

// === Local time zone ===

/// One entry of the system's time-zone table: seconds east of UTC plus the
/// designation `%Z` prints.
const Zone = struct {
    offset: i32,
    is_dst: bool,
    abbrev_len: u8,
    abbrev_buf: [8]u8,

    fn make(offset: i32, is_dst: bool, name: []const u8) Zone {
        var z: Zone = .{
            .offset = offset,
            .is_dst = is_dst,
            .abbrev_len = @intCast(@min(name.len, 8)),
            .abbrev_buf = @splat(0),
        };
        @memcpy(z.abbrev_buf[0..z.abbrev_len], name[0..z.abbrev_len]);
        return z;
    }

    fn abbrev(self: *const Zone) []const u8 {
        return self.abbrev_buf[0..self.abbrev_len];
    }
};

/// `gmtime` designates UTC as "GMT", which is what `%Z` prints for `!` formats.
const utc_zone = Zone.make(0, false, "GMT");

/// A TZif file's transition table stops around 2037; the POSIX rule in its
/// footer covers everything after that, so it is parsed too.
///
/// The offsets in a POSIX TZ string are minutes *west* of UTC, the opposite
/// sign from everything else here, so `EST5EDT` means an offset of -5 hours.
const PosixTz = struct {
    std_zone: Zone,
    dst_zone: Zone,
    has_dst: bool,
    start: TzRule,
    end: TzRule,
};

/// When daylight saving starts or ends, as a day within the year plus a
/// wall-clock time.
const TzRule = struct {
    form: enum {
        /// `Mm.w.d`: the `d`-th weekday of week `w` of month `m`, week 5
        /// meaning the last one.
        month_week_day,
        /// `Jn`: day of year 1..365, never counting February 29th.
        julian_no_leap,
        /// `n`: day of year 0..365, counting February 29th.
        day_of_year,
    },
    mon: i64 = 1,
    week: i64 = 1,
    wday: i64 = 0,
    yday: i64 = 0,
    secs: i64 = 2 * 60 * 60, // POSIX default is 02:00 local time
};

/// The local zone is a process-wide fact, so it is read once and memoized in
/// static storage. Both the TZif file and the parsed tables live in `tz_scratch`
/// during the load and are distilled into the values below, so no Lua allocator
/// is involved and nothing has to be freed. Not thread-safe, which matches the
/// rest of the interpreter.
const max_transitions = 1024;
var tz_scratch: [48 * 1024]u8 = undefined;
var tz_loaded = false;
var tz_count: usize = 0;
var tz_times: [max_transitions]i64 = undefined;
var tz_zones: [max_transitions]Zone = undefined;
var tz_initial: Zone = utc_zone;
var tz_posix: ?PosixTz = null;

/// The TZif file describing the local zone, or null to stay on UTC. A `TZ`
/// naming a POSIX rule rather than a zone file (`EST5EDT`) resolves only if
/// tzdata happens to ship a file of that name; otherwise the open fails and
/// UTC is used.
fn tzPath(buf: []u8) ?[]const u8 {
    const tz = getEnv("TZ") orelse return "/etc/localtime";
    const name = if (tz.len > 0 and tz[0] == ':') tz[1..] else tz;
    if (name.len == 0) return null; // TZ="" selects UTC
    if (name[0] == '/') return name;
    if (std.mem.indexOf(u8, name, "..") != null) return null;
    return std.fmt.bufPrint(buf, "/usr/share/zoneinfo/{s}", .{name}) catch null;
}

fn loadLocalZone() void {
    if (tz_loaded) return;
    tz_loaded = true; // a failed load is not retried

    var path_buf: [512]u8 = undefined;
    const path = tzPath(&path_buf) orelse return;

    const io = stdio.io();
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var fba = std.heap.FixedBufferAllocator.init(&tz_scratch);
    const tz = std.Tz.parse(fba.allocator(), &reader.interface) catch return;

    // Before the first transition, POSIX uses the first non-DST type.
    for (tz.timetypes) |tt| {
        if (!tt.isDst()) {
            tz_initial = Zone.make(tt.offset, false, tt.name());
            break;
        }
    } else if (tz.timetypes.len > 0) {
        tz_initial = Zone.make(tz.timetypes[0].offset, tz.timetypes[0].isDst(), tz.timetypes[0].name());
    }

    // Zones with more transitions than fit keep the most recent ones, which
    // are the only ones a running program is likely to ask about.
    const all = tz.transitions;
    const kept = all[all.len -| max_transitions..];
    for (kept, 0..) |tr, i| {
        tz_times[i] = tr.ts;
        tz_zones[i] = Zone.make(tr.timetype.offset, tr.timetype.isDst(), tr.timetype.name());
    }
    tz_count = kept.len;

    if (tz.footer) |footer| tz_posix = parsePosixTz(footer);
}

/// The zone in effect at UTC instant `t`.
fn localZoneAt(t: i64) *const Zone {
    loadLocalZone();
    // Past the last recorded transition the footer's rule takes over, which is
    // what keeps daylight saving working for dates beyond 2037.
    if (tz_count == 0 or t >= tz_times[tz_count - 1]) {
        if (posixZoneAt(t)) |zone| return zone;
    }
    if (tz_count == 0 or t < tz_times[0]) return &tz_initial;
    var lo: usize = 0;
    var hi: usize = tz_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (tz_times[mid] <= t) lo = mid + 1 else hi = mid;
    }
    return &tz_zones[lo - 1];
}

// === POSIX TZ rules ===

/// Parse a POSIX TZ string, `stdoffset[dst[offset][,start[,end]]]`. Returns
/// null for anything unrecognized, which leaves the caller on the transition
/// table alone.
fn parsePosixTz(spec: []const u8) ?PosixTz {
    var p: usize = 0;
    const std_name = parseZoneName(spec, &p) orelse return null;
    const std_west = parseTzOffset(spec, &p) orelse return null;
    const std_zone = Zone.make(@intCast(-std_west), false, std_name);

    if (p >= spec.len) {
        return .{
            .std_zone = std_zone,
            .dst_zone = std_zone,
            .has_dst = false,
            .start = .{ .form = .day_of_year },
            .end = .{ .form = .day_of_year },
        };
    }

    const dst_name = parseZoneName(spec, &p) orelse return null;
    // An absent DST offset means one hour ahead of standard time.
    const dst_west = if (p < spec.len and spec[p] != ',')
        (parseTzOffset(spec, &p) orelse return null)
    else
        std_west - 60 * 60;
    const dst_zone = Zone.make(@intCast(-dst_west), true, dst_name);

    if (p >= spec.len or spec[p] != ',') return null;
    p += 1;
    const start = parseTzRule(spec, &p) orelse return null;
    if (p >= spec.len or spec[p] != ',') return null;
    p += 1;
    const end = parseTzRule(spec, &p) orelse return null;

    return .{
        .std_zone = std_zone,
        .dst_zone = dst_zone,
        .has_dst = true,
        .start = start,
        .end = end,
    };
}

/// A designation, either bare letters or the `<...>` form that allows digits
/// and signs (`<-03>`).
fn parseZoneName(spec: []const u8, p: *usize) ?[]const u8 {
    if (p.* >= spec.len) return null;
    if (spec[p.*] == '<') {
        const close = std.mem.indexOfScalarPos(u8, spec, p.*, '>') orelse return null;
        const name = spec[p.* + 1 .. close];
        p.* = close + 1;
        return if (name.len == 0) null else name;
    }
    const start = p.*;
    while (p.* < spec.len) : (p.* += 1) {
        const c = spec[p.*];
        if (c == ',' or c == '+' or c == '-' or (c >= '0' and c <= '9')) break;
    }
    return if (p.* == start) null else spec[start..p.*];
}

/// `[+|-]hh[:mm[:ss]]`, in seconds west of UTC.
fn parseTzOffset(spec: []const u8, p: *usize) ?i64 {
    var negative = false;
    if (p.* < spec.len and (spec[p.*] == '+' or spec[p.*] == '-')) {
        negative = spec[p.*] == '-';
        p.* += 1;
    }
    const hours = parseTzNumber(spec, p) orelse return null;
    var total = hours * 60 * 60;
    if (p.* < spec.len and spec[p.*] == ':') {
        p.* += 1;
        total += (parseTzNumber(spec, p) orelse return null) * 60;
        if (p.* < spec.len and spec[p.*] == ':') {
            p.* += 1;
            total += parseTzNumber(spec, p) orelse return null;
        }
    }
    return if (negative) -total else total;
}

fn parseTzNumber(spec: []const u8, p: *usize) ?i64 {
    const start = p.*;
    var n: i64 = 0;
    while (p.* < spec.len and spec[p.*] >= '0' and spec[p.*] <= '9') : (p.* += 1) {
        n = n * 10 + (spec[p.*] - '0');
        if (n > 1_000_000) return null;
    }
    return if (p.* == start) null else n;
}

fn parseTzRule(spec: []const u8, p: *usize) ?TzRule {
    if (p.* >= spec.len) return null;
    var rule: TzRule = undefined;
    switch (spec[p.*]) {
        'M' => {
            p.* += 1;
            const mon = parseTzNumber(spec, p) orelse return null;
            if (p.* >= spec.len or spec[p.*] != '.') return null;
            p.* += 1;
            const week = parseTzNumber(spec, p) orelse return null;
            if (p.* >= spec.len or spec[p.*] != '.') return null;
            p.* += 1;
            const wday = parseTzNumber(spec, p) orelse return null;
            if (mon < 1 or mon > 12 or week < 1 or week > 5 or wday > 6) return null;
            rule = .{ .form = .month_week_day, .mon = mon, .week = week, .wday = wday };
        },
        'J' => {
            p.* += 1;
            const yday = parseTzNumber(spec, p) orelse return null;
            if (yday < 1 or yday > 365) return null;
            rule = .{ .form = .julian_no_leap, .yday = yday };
        },
        else => {
            const yday = parseTzNumber(spec, p) orelse return null;
            if (yday > 365) return null;
            rule = .{ .form = .day_of_year, .yday = yday };
        },
    }
    if (p.* < spec.len and spec[p.*] == '/') {
        p.* += 1;
        rule.secs = parseTzOffset(spec, p) orelse return null;
    }
    return rule;
}

/// Local wall-clock seconds at which `rule` fires in `year`.
fn ruleInstant(rule: TzRule, year: i64) i64 {
    const day = switch (rule.form) {
        .month_week_day => nthWeekdayOfMonth(year, rule.mon, rule.week, rule.wday),
        // `Jn` skips February 29th, so days after February shift in a leap year.
        .julian_no_leap => daysFromCivil(year, 1, 1) + rule.yday - 1 +
            @as(i64, if (rule.yday >= 60 and isLeapYear(year)) 1 else 0),
        .day_of_year => daysFromCivil(year, 1, 1) + rule.yday,
    };
    return day * secs_per_day + rule.secs;
}

/// Days since the epoch for the `wday`-th weekday of week `week` of `mon`;
/// week 5 means the last one in the month.
fn nthWeekdayOfMonth(year: i64, mon: i64, week: i64, wday: i64) i64 {
    const first = daysFromCivil(year, mon, 1);
    const first_wday = @mod(first + 4, 7);
    if (week < 5) {
        return first + @mod(wday - first_wday, 7) + (week - 1) * 7;
    }
    const next_month = daysFromCivil(year, mon + 1, 1);
    const last = next_month - 1;
    const last_wday = @mod(last + 4, 7);
    return last - @mod(last_wday - wday, 7);
}

/// The zone the footer's rule puts in effect at UTC instant `t`.
fn posixZoneAt(t: i64) ?*const Zone {
    if (tz_posix == null) return null;
    const rule = &tz_posix.?;
    if (!rule.has_dst) return &rule.std_zone;

    const std_off: i64 = rule.std_zone.offset;
    const dst_off: i64 = rule.dst_zone.offset;
    const year = civilFromDays(@divFloor(t + std_off, secs_per_day)).year;
    // The start rule's clock still reads standard time, the end rule's reads
    // daylight time, so each converts with its own offset.
    const start_utc = ruleInstant(rule.start, year) - std_off;
    const end_utc = ruleInstant(rule.end, year) - dst_off;

    // Southern-hemisphere zones start daylight saving after they end it, so
    // the interval wraps around the new year.
    const in_dst = if (start_utc <= end_utc)
        (t >= start_utc and t < end_utc)
    else
        (t >= start_utc or t < end_utc);
    return if (in_dst) &rule.dst_zone else &rule.std_zone;
}

// === Broken-down time ===

/// The fields of `struct tm`, but with a full year and a 1-based month so no
/// 1900/0-based deltas are needed on the way in or out.
const Tm = struct {
    year: i64,
    mon: i64,
    mday: i64,
    hour: i64,
    min: i64,
    sec: i64,
    wday: i64, // 0 = Sunday
    yday: i64, // 0 = January 1st
    is_dst: bool,
    gmtoff: i32,
    abbrev: []const u8,
};

/// `localtime`/`gmtime`: split a UTC instant into local calendar fields.
fn breakTime(t: i64, utc: bool) ?Tm {
    const zone = if (utc) &utc_zone else localZoneAt(t);
    const local = t + zone.offset;
    const days = @divFloor(local, secs_per_day);
    const civil = civilFromDays(days);
    if (civil.year < min_year or civil.year > max_year) return null;

    const rem = local - days * secs_per_day;
    return .{
        .year = civil.year,
        .mon = civil.mon,
        .mday = civil.day,
        .hour = @divTrunc(rem, 3600),
        .min = @divTrunc(@mod(rem, 3600), 60),
        .sec = @mod(rem, 60),
        // 1970-01-01 was a Thursday, which is 4 counting from Sunday.
        .wday = @mod(days + 4, 7),
        .yday = days - daysFromCivil(civil.year, 1, 1),
        .is_dst = zone.is_dst,
        .gmtoff = zone.offset,
        .abbrev = zone.abbrev(),
    };
}

/// `mktime`: read the fields as local time and return the UTC instant.
/// Out-of-range fields normalize, so `month = 13` means January of the next
/// year.
fn makeTime(year: i64, mon: i64, day: i64, hour: i64, min: i64, sec: i64) i64 {
    // Fold the month into the year first; `daysFromCivil` needs 1..12.
    const m0 = mon - 1;
    const y = year + @divFloor(m0, 12);
    const m = @mod(m0, 12) + 1;
    const naive = daysFromCivil(y, m, day) * secs_per_day + hour * 3600 + min * 60 + sec;

    // Solve `utc + offset(utc) == naive`. The offset depends on the answer, so
    // guess with the offset at the naive instant and correct once; that settles
    // every case except local times a DST jump skipped or repeated, where
    // `mktime` is implementation-defined anyway.
    const guess = naive - localZoneAt(naive).offset;
    return naive - localZoneAt(guess).offset;
}

fn nowSeconds() i64 {
    return std.Io.Clock.real.now(stdio.io()).toSeconds();
}

// === C-locale date names ===

const wday_abbrev = [7][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const wday_name = [7][]const u8{
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
};
const mon_abbrev = [12][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};
const mon_name = [12][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

const IsoWeek = struct { year: i64, week: i64 };

/// ISO 8601 week-based year and week number, for `%G`, `%g` and `%V`.
fn isoWeek(tm: *const Tm) IsoWeek {
    const iso_wday: i64 = if (tm.wday == 0) 7 else tm.wday; // Monday = 1
    var year = tm.year;
    var week = @divFloor(tm.yday + 1 - iso_wday + 10, 7);
    if (week < 1) {
        year -= 1;
        week = isoWeeksInYear(year);
    } else if (week > isoWeeksInYear(year)) {
        year += 1;
        week = 1;
    }
    return .{ .year = year, .week = week };
}

/// A year has 53 ISO weeks when it begins on a Thursday, or on a Wednesday in
/// a leap year.
fn isoWeeksInYear(y: i64) i64 {
    const jan1_wday = @mod(daysFromCivil(y, 1, 1) + 4, 7);
    return if (jan1_wday == 4 or (jan1_wday == 3 and isLeapYear(y))) 53 else 52;
}

// === strftime ===

fn specError(L: *state.LuaState, spec: []const u8) anyerror {
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "invalid conversion specifier '%{s}'", .{spec}) catch
        "invalid conversion specifier";
    return aux.argError(L, 1, msg);
}

/// Specifiers C defines in terms of others. Expanding them keeps `addAtomic`
/// free of recursion.
fn expansionOf(c: u8) ?[]const u8 {
    return switch (c) {
        'c' => "%a %b %e %H:%M:%S %Y",
        'D', 'x' => "%m/%d/%y",
        'F' => "%Y-%m-%d",
        'r' => "%I:%M:%S %p",
        'R' => "%H:%M",
        'T', 'X' => "%H:%M:%S",
        else => null,
    };
}

fn addSpec(L: *state.LuaState, b: *aux.Buffer, tm: *const Tm, c: u8) !void {
    const expansion = expansionOf(c) orelse return addAtomic(L, b, tm, c);
    var i: usize = 0;
    while (i < expansion.len) {
        if (expansion[i] == '%') {
            try addAtomic(L, b, tm, expansion[i + 1]);
            i += 2;
        } else {
            try b.addChar(expansion[i]);
            i += 1;
        }
    }
}

/// Write a non-negative date field padded to `width` with `fill`.
///
/// Zig renders `{d:0>2}` on a *signed* integer as an explicit sign rather than
/// a leading zero ("+1", not "01"), so the value is widened to unsigned first.
/// Every field reaching here is a calendar component and cannot be negative.
fn addPad(b: *aux.Buffer, comptime width: comptime_int, comptime fill: u8, v: i64) !void {
    const u: u64 = if (v < 0) 0 else @intCast(v);
    try b.addFmt(std.fmt.comptimePrint("{{d:{c}>{d}}}", .{ fill, width }), .{u});
}

fn addAtomic(L: *state.LuaState, b: *aux.Buffer, tm: *const Tm, c: u8) !void {
    switch (c) {
        'a' => try b.addString(wday_abbrev[@intCast(tm.wday)]),
        'A' => try b.addString(wday_name[@intCast(tm.wday)]),
        'b', 'h' => try b.addString(mon_abbrev[@intCast(tm.mon - 1)]),
        'B' => try b.addString(mon_name[@intCast(tm.mon - 1)]),
        'C' => try addPad(b, 2, '0', @divFloor(tm.year, 100)),
        'd' => try addPad(b, 2, '0', tm.mday),
        'e' => try addPad(b, 2, ' ', tm.mday),
        'g' => try addPad(b, 2, '0', @mod(isoWeek(tm).year, 100)),
        'G' => try b.addFmt("{d}", .{isoWeek(tm).year}),
        'H' => try addPad(b, 2, '0', tm.hour),
        'I' => try addPad(b, 2, '0', hour12(tm.hour)),
        'j' => try addPad(b, 3, '0', tm.yday + 1),
        'm' => try addPad(b, 2, '0', tm.mon),
        'M' => try addPad(b, 2, '0', tm.min),
        'n' => try b.addChar('\n'),
        'p' => try b.addString(if (tm.hour < 12) "AM" else "PM"),
        'S' => try addPad(b, 2, '0', tm.sec),
        't' => try b.addChar('\t'),
        'u' => try b.addFmt("{d}", .{if (tm.wday == 0) @as(i64, 7) else tm.wday}),
        // %U and %W count the whole weeks completed before the current one,
        // differing only in which day starts a week.
        'U' => try addPad(b, 2, '0', @divFloor(tm.yday + 7 - tm.wday, 7)),
        'V' => try addPad(b, 2, '0', isoWeek(tm).week),
        'w' => try b.addFmt("{d}", .{tm.wday}),
        'W' => try addPad(b, 2, '0', @divFloor(tm.yday + 7 - @mod(tm.wday + 6, 7), 7)),
        'y' => try addPad(b, 2, '0', @mod(tm.year, 100)),
        'Y' => try b.addFmt("{d}", .{tm.year}),
        'z' => {
            const east = tm.gmtoff >= 0;
            const secs: u32 = @intCast(if (east) tm.gmtoff else -tm.gmtoff);
            try b.addFmt("{c}{d:0>2}{d:0>2}", .{
                @as(u8, if (east) '+' else '-'),
                @as(u64, secs / 3600),
                @as(u64, (secs % 3600) / 60),
            });
        },
        'Z' => try b.addString(tm.abbrev),
        '%' => try b.addChar('%'),
        else => {
            const spec = [_]u8{c};
            return specError(L, &spec);
        },
    }
}

fn hour12(hour: i64) i64 {
    const h = @mod(hour, 12);
    return if (h == 0) 12 else h;
}

// === Date table marshalling ===

/// `t[key] = v` for the table on top of the stack. The key and value are
/// pushed before the table is resolved, unlike `api.setField`, so a stack
/// reallocation in between cannot leave a stale pointer behind.
fn setIntField(L: *state.LuaState, key: []const u8, v: i64) !void {
    try api.pushString(L, key);
    try api.pushInteger(L, v);
    try api.setTable(L, -3);
}

fn setBoolField(L: *state.LuaState, key: []const u8, v: bool) !void {
    try api.pushString(L, key);
    try api.pushBoolean(L, v);
    try api.setTable(L, -3);
}

/// `setallfields`: the nine fields of a `*t` result.
fn setAllFields(L: *state.LuaState, tm: *const Tm) !void {
    try setIntField(L, "year", tm.year);
    try setIntField(L, "month", tm.mon);
    try setIntField(L, "day", tm.mday);
    try setIntField(L, "hour", tm.hour);
    try setIntField(L, "min", tm.min);
    try setIntField(L, "sec", tm.sec);
    try setIntField(L, "yday", tm.yday + 1);
    try setIntField(L, "wday", tm.wday + 1);
    try setBoolField(L, "isdst", tm.is_dst);
}

/// `getfield`: read an integer field of the table on top of the stack. A null
/// `def` makes the field mandatory. The value is popped before any error is
/// raised, because the error message has to be what is left on the stack.
fn getTimeField(L: *state.LuaState, key: []const u8, def: ?i64, delta: i64) !i64 {
    try api.pushString(L, key);
    try api.getTable(L, -2);
    const absent = api.isNil(L, -1);
    const n = api.toInteger(L, -1);
    api.pop(L, 1);

    if (absent) {
        if (def) |d| return d;
        return aux.err(L, "field '{s}' missing in date table", .{key});
    }
    if (n == null) return aux.err(L, "field '{s}' is not an integer", .{key});
    const v = n.?;
    // C stores these in `int` fields after subtracting `delta` (1900 for the
    // year, 1 for the month), so anything wider is out of bounds
    const fits = if (v >= 0) v - delta <= std.math.maxInt(i32) else std.math.minInt(i32) + delta <= v;
    if (!fits) return aux.err(L, "field '{s}' is out-of-bound", .{key});
    return v;
}

/// `getboolfield`: null when the field is absent.
fn getBoolField(L: *state.LuaState, key: []const u8) !?bool {
    try api.pushString(L, key);
    try api.getTable(L, -2);
    const res: ?bool = if (api.isNil(L, -1)) null else api.toBoolean(L, -1);
    api.pop(L, 1);
    return res;
}

// === File and process results ===

/// `luaL_fileresult`: `true`, or `nil, message, errno`.
fn fileResult(L: *state.LuaState, err: ?anyerror, fname: ?[]const u8) !i32 {
    const e = err orelse {
        try api.pushBoolean(L, true);
        return 1;
    };
    const info = syserr.describe(e);
    try api.pushNil(L);
    if (fname) |f| {
        try api.pushFString(L, "{s}: {s}", .{ f, info.text });
    } else {
        try api.pushString(L, info.text);
    }
    try api.pushInteger(L, info.code);
    return 3;
}

/// `luaL_execresult`: `true|nil, "exit"|"signal", code`.
pub fn execResult(L: *state.LuaState, term: std.process.Child.Term) !i32 {
    switch (term) {
        .exited => |code| {
            if (code == 0) try api.pushBoolean(L, true) else try api.pushNil(L);
            try api.pushString(L, "exit");
            try api.pushInteger(L, code);
        },
        .signal, .stopped => |sig| {
            try api.pushNil(L);
            try api.pushString(L, "signal");
            try api.pushInteger(L, @intFromEnum(sig));
        },
        .unknown => |code| {
            try api.pushNil(L);
            try api.pushString(L, "exit");
            try api.pushInteger(L, code);
        },
    }
    return 3;
}

// === Library functions ===

/// os.clock() -- CPU time used by the program, in seconds
fn os_clock(L: *state.LuaState) !i32 {
    const ns = std.Io.Clock.cpu_process.now(stdio.io()).nanoseconds;
    const secs: f64 = @floatFromInt(ns);
    try api.pushNumber(L, secs / @as(f64, std.time.ns_per_s));
    return 1;
}

/// os.time([table]) -- current time, or the instant a date table names
fn os_time(L: *state.LuaState) !i32 {
    if (aux.isNoneOrNil(L, 1)) {
        try api.pushInteger(L, nowSeconds());
        return 1;
    }

    try aux.checkTable(L, 1);
    try api.setTop(L, 1); // the table must be on top for the field helpers

    // Only the date is mandatory; a bare `{year=,month=,day=}` means midday,
    // which keeps the result inside the day whatever the zone turns out to be.
    const year = try getTimeField(L, "year", null, 1900);
    const mon = try getTimeField(L, "month", null, 1);
    const day = try getTimeField(L, "day", null, 0);
    const hour = try getTimeField(L, "hour", 12, 0);
    const min = try getTimeField(L, "min", 0, 0);
    const sec = try getTimeField(L, "sec", 0, 0);
    _ = try getBoolField(L, "isdst"); // the zone table decides this for us

    const t = makeTime(year, mon, day, hour, min, sec);
    const maybe_tm = breakTime(t, false);
    if (maybe_tm == null) {
        return aux.err(L, "time result cannot be represented in this installation", .{});
    }
    const tm = maybe_tm.?;

    try setAllFields(L, &tm); // report the normalized fields back to the caller
    try api.pushInteger(L, t);
    return 1;
}

/// os.date([format [, time]]) -- format a time, or break it into a table
fn os_date(L: *state.LuaState) !i32 {
    const arg = try aux.optString(L, 1, "%c");
    const t: i64 = if (aux.isNoneOrNil(L, 2)) nowSeconds() else try aux.checkInteger(L, 2);

    const utc = arg.len > 0 and arg[0] == '!';
    const fmt = if (utc) arg[1..] else arg;

    const maybe_tm = breakTime(t, utc);
    if (maybe_tm == null) {
        return aux.err(L, "date result cannot be represented in this installation", .{});
    }
    const tm = maybe_tm.?;

    if (std.mem.eql(u8, fmt, "*t")) {
        try api.createTable(L, 0, 9);
        try setAllFields(L, &tm);
        return 1;
    }

    var b = aux.Buffer.init(L);
    defer b.deinit();
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            try b.addChar(fmt[i]);
            i += 1;
            continue;
        }
        i += 1;
        // A trailing '%' has nothing to check, which is what C's `checkoption`
        // reports as an empty specifier.
        if (i >= fmt.len) return specError(L, "");
        try addSpec(L, &b, &tm, fmt[i]);
        i += 1;
    }
    try b.pushResult();
    return 1;
}

/// os.difftime(t2, t1) -- seconds from t1 to t2
fn os_difftime(L: *state.LuaState) !i32 {
    const t2 = try aux.checkInteger(L, 1);
    const t1 = try aux.checkInteger(L, 2);
    try api.pushNumber(L, @as(f64, @floatFromInt(t2)) - @as(f64, @floatFromInt(t1)));
    return 1;
}

/// os.getenv(name) -- nil when the variable is unset
fn os_getenv(L: *state.LuaState) !i32 {
    const name = try aux.checkString(L, 1);
    if (getEnv(name)) |v| {
        try api.pushString(L, v);
    } else {
        try api.pushNil(L);
    }
    return 1;
}

/// os.remove(filename) -- C's `remove`, which also unlinks empty directories
fn os_remove(L: *state.LuaState) !i32 {
    const name = try aux.checkString(L, 1);
    const io = stdio.io();
    const cwd = std.Io.Dir.cwd();

    cwd.deleteFile(io, name) catch |file_err| {
        const e: anyerror = file_err;
        if (e != error.IsDir) return fileResult(L, e, name);
        cwd.deleteDir(io, name) catch |dir_err| return fileResult(L, dir_err, name);
    };
    return fileResult(L, null, name);
}

/// os.rename(from, to)
fn os_rename(L: *state.LuaState) !i32 {
    const from = try aux.checkString(L, 1);
    const to = try aux.checkString(L, 2);
    const cwd = std.Io.Dir.cwd();
    cwd.rename(from, cwd, to, stdio.io()) catch |err| return fileResult(L, err, null);
    return fileResult(L, null, null);
}

/// os.tmpname() -- a file name not currently in use
///
/// POSIX Lua uses `mkstemp`, which reserves the name by creating the file; the
/// exclusive create below does the same, so two calls cannot collide.
fn os_tmpname(L: *state.LuaState) !i32 {
    const io = stdio.io();
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";

    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        var rand: [6]u8 = undefined;
        io.random(&rand);
        var name: [len_of_template]u8 = (tmpname_template ++ "XXXXXX").*;
        for (&rand, 0..) |r, i| {
            name[tmpname_template.len + i] = alphabet[r % alphabet.len];
        }

        const file = std.Io.Dir.cwd().createFile(io, &name, .{
            .exclusive = true,
            .truncate = false,
        }) catch |err| {
            const e: anyerror = err;
            if (e == error.PathAlreadyExists) continue;
            break;
        };
        file.close(io);
        try api.pushString(L, &name);
        return 1;
    }
    return aux.err(L, "unable to generate a unique filename", .{});
}

const tmpname_template = if (builtin.os.tag == .windows) "lua_" else "/tmp/lua_";
const len_of_template = tmpname_template.len + 6;

/// os.exit([code [, close]])
fn os_exit(L: *state.LuaState) !i32 {
    const status: i64 = if (api.isBoolean(L, 1))
        (if (api.toBoolean(L, 1)) 0 else 1)
    else
        try aux.optInteger(L, 1, 0);

    if (api.toBoolean(L, 2)) {
        L.close(); // closes every handle through its finalizer
    } else {
        iolib.flushAll(L); // what C's exit() does for stdio streams
    }
    std.process.exit(@truncate(@as(u64, @bitCast(status))));
}

pub const shell_path = if (builtin.os.tag == .windows) "cmd.exe" else "/bin/sh";
/// argv[0] for the shell: `system()` and `popen()` pass "sh", and the shell
/// names itself that way in its diagnostics ("sh: line 1: ...")
pub const shell_argv0 = if (builtin.os.tag == .windows) "cmd.exe" else "sh";
pub const shell_flag = if (builtin.os.tag == .windows) "/c" else "-c";

/// os.execute([command]) -- run `command` through the system shell
///
/// With no argument this only reports whether a shell exists, as C's
/// `system(NULL)` does.
fn os_execute(L: *state.LuaState) !i32 {
    if (aux.isNoneOrNil(L, 1)) {
        const found = if (std.Io.Dir.cwd().statFile(stdio.io(), shell_path, .{})) |_| true else |_| false;
        try api.pushBoolean(L, found);
        return 1;
    }
    const cmd = try aux.checkString(L, 1);

    // `stdio.io()`'s instance carries `Allocator.failing` and an empty
    // environment, neither of which a spawn can use, so this one call gets its
    // own `Io` over the state's allocator and the real environment block.
    var spawner: std.Io.Threaded = .init(L.allocator, .{ .environ = processEnviron() });
    defer spawner.deinit();
    const io = spawner.io();

    const argv = [_][]const u8{ shell_argv0, shell_flag, cmd };
    var child = std.process.spawn(io, .{ .argv = &argv }) catch |err|
        return fileResult(L, err, null);
    const term = child.wait(io) catch |err| return fileResult(L, err, null);
    return execResult(L, term);
}

/// os.setlocale([locale [, category]])
///
/// libc's `setlocale`, as the reference: the process locale changes, so
/// `string.format` and `tostring` (both `snprintf`) follow it. Known gap:
/// `os.date` formats names from the tables above, in English whatever the
/// LC_TIME setting, and the numeral parser does not read the locale's
/// decimal point.
fn os_setlocale(L: *state.LuaState) !i32 {
    const categories = [_][]const u8{ "all", "collate", "ctype", "monetary", "numeric", "time" };
    const lc = [_]std.c.LC{ .ALL, .COLLATE, .CTYPE, .MONETARY, .NUMERIC, .TIME };
    // Guarded because `checkOption` treats an absent argument as a bad string
    // rather than as the default.
    const which: usize = if (aux.isNoneOrNil(L, 2)) 0 else @intCast(try aux.checkOption(L, 2, "all", &categories));

    var buf: [256]u8 = undefined;
    var locale: ?[*:0]const u8 = null; // absent or nil: query the current locale
    if (!aux.isNoneOrNil(L, 1)) {
        const s = try aux.checkString(L, 1);
        if (s.len >= buf.len) return aux.err(L, "locale name too long", .{});
        @memcpy(buf[0..s.len], s);
        buf[s.len] = 0;
        locale = buf[0..s.len :0];
    }
    if (std.c.setlocale(lc[which], locale)) |name| {
        try api.pushString(L, std.mem.span(name));
    } else {
        try api.pushNil(L);
    }
    return 1;
}

// === Tests ===
//
// The calendar arithmetic is pure, so it is checked here; everything that
// touches the VM or the clock is exercised by ostest.lua instead.

test "oslib.daysFromCivil anchors on the epoch" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
    try std.testing.expectEqual(@as(i64, 1), daysFromCivil(1970, 1, 2));
    try std.testing.expectEqual(@as(i64, 11323), daysFromCivil(2001, 1, 1));
    try std.testing.expectEqual(@as(i64, -719468), daysFromCivil(0, 3, 1));
}

test "oslib.civilFromDays inverts daysFromCivil" {
    var day: i64 = -800000;
    while (day < 800000) : (day += 337) {
        const civil = civilFromDays(day);
        try std.testing.expectEqual(day, daysFromCivil(civil.year, civil.mon, civil.day));
        try std.testing.expect(civil.mon >= 1 and civil.mon <= 12);
        try std.testing.expect(civil.day >= 1 and civil.day <= 31);
    }
}

test "oslib.daysFromCivil normalizes an out-of-range day" {
    // What lets os.time accept `day = 32` and mean the 1st of the next month.
    try std.testing.expectEqual(daysFromCivil(2024, 2, 1), daysFromCivil(2024, 1, 32));
    try std.testing.expectEqual(daysFromCivil(2024, 3, 1), daysFromCivil(2024, 2, 30));
}

test "oslib.breakTime splits a known UTC instant" {
    // 2001-09-09T01:46:40Z, a Sunday, day 252 of the year.
    const tm = breakTime(1_000_000_000, true).?;
    try std.testing.expectEqual(@as(i64, 2001), tm.year);
    try std.testing.expectEqual(@as(i64, 9), tm.mon);
    try std.testing.expectEqual(@as(i64, 9), tm.mday);
    try std.testing.expectEqual(@as(i64, 1), tm.hour);
    try std.testing.expectEqual(@as(i64, 46), tm.min);
    try std.testing.expectEqual(@as(i64, 40), tm.sec);
    try std.testing.expectEqual(@as(i64, 0), tm.wday);
    try std.testing.expectEqual(@as(i64, 251), tm.yday);
    try std.testing.expectEqual(@as(i64, 0), tm.gmtoff);
}

test "oslib.breakTime handles instants before the epoch" {
    const tm = breakTime(-1, true).?;
    try std.testing.expectEqual(@as(i64, 1969), tm.year);
    try std.testing.expectEqual(@as(i64, 12), tm.mon);
    try std.testing.expectEqual(@as(i64, 31), tm.mday);
    try std.testing.expectEqual(@as(i64, 23), tm.hour);
    try std.testing.expectEqual(@as(i64, 59), tm.min);
    try std.testing.expectEqual(@as(i64, 59), tm.sec);
    try std.testing.expectEqual(@as(i64, 3), tm.wday); // Wednesday
}

test "oslib.makeTime round-trips through breakTime" {
    // Local zone is whatever the host says, so compare against breakTime
    // rather than a fixed number.
    const t = makeTime(2024, 6, 15, 12, 30, 45);
    const tm = breakTime(t, false).?;
    try std.testing.expectEqual(@as(i64, 2024), tm.year);
    try std.testing.expectEqual(@as(i64, 6), tm.mon);
    try std.testing.expectEqual(@as(i64, 15), tm.mday);
    try std.testing.expectEqual(@as(i64, 12), tm.hour);
    try std.testing.expectEqual(@as(i64, 30), tm.min);
    try std.testing.expectEqual(@as(i64, 45), tm.sec);
}

test "oslib.makeTime normalizes out-of-range fields" {
    try std.testing.expectEqual(makeTime(2025, 1, 1, 0, 0, 0), makeTime(2024, 13, 1, 0, 0, 0));
    try std.testing.expectEqual(makeTime(2024, 1, 1, 1, 0, 0), makeTime(2024, 1, 1, 0, 60, 0));
    try std.testing.expectEqual(makeTime(2024, 1, 1, 0, 0, 0), makeTime(2023, 12, 32, 0, 0, 0));
}

test "oslib.isoWeek matches the ISO 8601 examples" {
    // 2005-01-01 is a Saturday, which ISO 8601 counts as week 53 of 2004.
    const sat = breakTime(makeTimeUtc(2005, 1, 1), true).?;
    const w1 = isoWeek(&sat);
    try std.testing.expectEqual(@as(i64, 2004), w1.year);
    try std.testing.expectEqual(@as(i64, 53), w1.week);

    // 2007-01-01 is a Monday: week 1 of 2007.
    const mon = breakTime(makeTimeUtc(2007, 1, 1), true).?;
    const w2 = isoWeek(&mon);
    try std.testing.expectEqual(@as(i64, 2007), w2.year);
    try std.testing.expectEqual(@as(i64, 1), w2.week);

    // 2026-12-31 falls in week 53 of 2026.
    const end = breakTime(makeTimeUtc(2026, 12, 31), true).?;
    const w3 = isoWeek(&end);
    try std.testing.expectEqual(@as(i64, 2026), w3.year);
    try std.testing.expectEqual(@as(i64, 53), w3.week);
}

/// Zone-free `makeTime`, so the tests above do not depend on the host's TZ.
fn makeTimeUtc(year: i64, mon: i64, day: i64) i64 {
    return daysFromCivil(year, mon, day) * secs_per_day;
}

test "oslib.hour12 wraps midnight and noon" {
    try std.testing.expectEqual(@as(i64, 12), hour12(0));
    try std.testing.expectEqual(@as(i64, 1), hour12(1));
    try std.testing.expectEqual(@as(i64, 12), hour12(12));
    try std.testing.expectEqual(@as(i64, 11), hour12(23));
}

test "oslib.parsePosixTz reads the America/New_York footer" {
    // EST5EDT,M3.2.0,M11.1.0 — second Sunday in March to first Sunday in November.
    const rule = parsePosixTz("EST5EDT,M3.2.0,M11.1.0").?;
    try std.testing.expect(rule.has_dst);
    try std.testing.expectEqual(@as(i32, -5 * 3600), rule.std_zone.offset);
    try std.testing.expectEqual(@as(i32, -4 * 3600), rule.dst_zone.offset);
    try std.testing.expectEqualStrings("EST", rule.std_zone.abbrev());
    try std.testing.expectEqualStrings("EDT", rule.dst_zone.abbrev());
    try std.testing.expectEqual(@as(@TypeOf(rule.start.form), .month_week_day), rule.start.form);
    try std.testing.expectEqual(@as(i64, 3), rule.start.mon);
    try std.testing.expectEqual(@as(i64, 2), rule.start.week);
}
