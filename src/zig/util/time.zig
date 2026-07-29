//! Port of `lib/ipmi_time.c` and `include/ipmitool/ipmi_time.h`: the
//! timestamp formatting shared by the SEL, SDR and FRU commands.
//!
//! Selected with `zig build -Dzig-modules=time`, which drops `lib/ipmi_time.c`
//! from the compile and links this module instead.
//!
//! # Upstream bugs preserved on purpose
//!
//! This is a straight port, not a fix.  Upstream carries known timezone and DST
//! defects here (branch `bugfix/43-Fix-timezone-and-DST-in-SEL`); changing the
//! behaviour in the same commit that changes the language would make any
//! differential regression indistinguishable from an intentional fix, so all
//! three are reproduced exactly and pinned by tests below:
//!
//!  1. `ipmiAsctimeR()` formats the relative "S+" form for special timestamps
//!     and then unconditionally overwrites the buffer with `"%c %Z"`, so the
//!     first result is always discarded.
//!  2. `ipmiStrftime()` assigns `daylight = -1` on the UTC path.  `daylight` is
//!     an output of `tzset()`, not an input, so this corrupts a libc global and
//!     never reaches `strftime()`.
//!  3. `ipmiLocaltime2utc()` splits `local` with `gmtime_r()` and reassembles it
//!     with `mktime()`, which reinterprets the fields as local time.  With
//!     `tm_isdst = -1` the result depends on whether the *reassembled* date is
//!     in DST, which is not necessarily the same answer as for the input.
//!
//! Formatting goes through libc `strftime()`/`snprintf()` so the `%c`, `%x`,
//! `%X` and `%Z` conversions keep producing exactly what they did before.
//!
//! Storage: `ipmiTimestampFmt()` and everything built on it return a pointer to
//! a single module-level buffer that the next call overwrites, and the
//! "Unspecified" results are string literals.  Callers must not free either.

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");

/// `IPMI_TIME_UNSPECIFIED`, as `time_t` after the C integer promotions.
pub const time_unspecified: c.time_t = 0xFFFFFFFF;

/// `IPMI_TIME_INIT_DONE`: timestamps below this are relative to BMC start.
pub const time_init_done: c.time_t = 0x20000000;

/// `SECONDS_A_DAY`.
pub const seconds_a_day: c.time_t = 24 * 60 * 60;

/// `IPMI_ASCTIME_SZ`.
pub const asctime_sz = 80;

/// `ipmi_datebuf_t`.
pub const DateBuf = [asctime_sz]u8;

/// `bool time_in_utc`, set by the `-Z` command line option.
///
/// Exported rather than kept private: `lib/ipmi_main.c` writes it directly.
pub var time_in_utc: bool = false;

/// `ipmi_timestamp_is_special()`: true when the stamp counts seconds since the
/// BMC powered on rather than since the epoch.
pub fn isSpecial(ts: c.time_t) bool {
    return ts < time_init_done;
}

/// `ipmi_timestamp_is_valid()`.
pub fn isValid(ts: c.time_t) bool {
    return ts != time_unspecified;
}

/// `ipmi_localtime2utc()`: subtract the UTC offset from a local `time_t`.
///
/// Bug 3 above is preserved verbatim: `gmtime_r()` then `mktime()`.
pub fn ipmiLocaltime2utc(local: c.time_t) callconv(.c) c.time_t {
    var tm: c.struct_tm = undefined;
    var stamp = local;
    _ = c.gmtime_r(&stamp, &tm);
    tm.tm_isdst = -1;
    return c.mktime(&tm);
}

/// `ipmi_strftime()`: `strftime()` honouring the `-Z` option.
///
/// Returns the number of bytes written, or 0 when the buffer was too small,
/// following `strftime()`.  `format` is ignored for the unspecified timestamp,
/// as section 37.1 of IPMI v2.0 rev 1.1 requires.
pub fn ipmiStrftime(
    s: [*]u8,
    max: usize,
    format: [*:0]const u8,
    stamp: c.time_t,
) callconv(.c) usize {
    var tm: c.struct_tm = undefined;
    var when = stamp;

    if (stamp == time_unspecified) {
        // C assigns the `int` result to a `size_t`; keep the conversion
        // non-trapping so a negative result stays the same huge value.
        return @bitCast(@as(isize, c.snprintf(s, max, "Unknown")));
    } else if (stamp <= time_init_done) {
        // Timestamp is relative to BMC start, no GMT offset.
        _ = c.gmtime_r(&when, &tm);
        return c.strftime(s, max, format, &tm);
    }

    if (time_in_utc or isSpecial(stamp)) {
        // The user wants the time reported in UTC, or the stamp is a number of
        // seconds since system power on; either way, no timezone offset.
        _ = c.gmtime_r(&when, &tm);
        // Bug 2: `daylight` is an output of tzset(), writing it does nothing
        // useful.  Kept so the C and Zig builds touch the same globals.
        c.daylight = -1;
    } else {
        // The user wants the time reported in the local time zone.
        _ = c.localtime_r(&when, &tm);
    }
    return c.strftime(s, max, format, &tm);
}

/// `ipmi_asctime_r()`: `"Wed Jun 30 21:49:08 1993 CEST"`, without the newline.
///
/// Returns `outbuf`.  Bug 1 above is preserved: the `S+` branches compute a
/// relative timestamp that the trailing `"%c %Z"` call immediately overwrites,
/// so special timestamps are rendered as an absolute date near the epoch.
pub fn ipmiAsctimeR(stamp: c.time_t, outbuf: [*]u8) callconv(.c) [*c]u8 {
    if (isSpecial(stamp)) {
        if (stamp < seconds_a_day) {
            _ = ipmiStrftime(outbuf, asctime_sz, "S+%H:%M:%S", stamp);
        } else {
            // IPMI_TIME_INIT_DONE is over 17 years.  This should never happen
            // normally, but we support it anyway.
            _ = ipmiStrftime(outbuf, asctime_sz, "S+%yy %jd %H:%M:%S", stamp);
        }
    }

    _ = ipmiStrftime(outbuf, asctime_sz, "%c %Z", stamp);
    return outbuf;
}

/// `static ipmi_datebuf_t datebuf` inside `ipmi_timestamp_fmt()`.
var datebuf: DateBuf = undefined;

/// `ipmi_timestamp_fmt()`: format `stamp` with `fmt`.
///
/// Returns module-level storage that the next call overwrites.  `fmt` is
/// assumed never to expand beyond `IPMI_ASCTIME_SZ`, as in C.
pub fn ipmiTimestampFmt(stamp: u32, fmt: [*:0]const u8) callconv(.c) [*c]u8 {
    _ = ipmiStrftime(&datebuf, datebuf.len, fmt, @intCast(stamp));
    return &datebuf;
}

/// The `"Unspecified"` literal the four accessors return for an invalid stamp.
///
/// C returns a string literal through a `char *`, which the callers only ever
/// read; `@constCast` reproduces that without copying.
fn unspecified() [*c]u8 {
    return @constCast(@as([*c]const u8, "Unspecified"));
}

/// `ipmi_timestamp_string()`: `Day Mon DD HH:MM:SS YYYY ZZZ`.
pub fn ipmiTimestampString(stamp: u32) callconv(.c) [*c]u8 {
    if (!isValid(stamp)) return unspecified();

    if (isSpecial(stamp)) {
        if (stamp < seconds_a_day) {
            return ipmiTimestampFmt(stamp, "S+ %H:%M:%S");
        }
        return ipmiTimestampFmt(stamp, "S+ %y years %j days %H:%M:%S");
    }
    return ipmiTimestampFmt(stamp, "%c %Z");
}

/// `ipmi_timestamp_numeric()`: `MM/DD/YYYY HH:MM:SS ZZZ`.
pub fn ipmiTimestampNumeric(stamp: u32) callconv(.c) [*c]u8 {
    if (!isValid(stamp)) return unspecified();

    if (isSpecial(stamp)) {
        if (stamp < seconds_a_day) {
            return ipmiTimestampFmt(stamp, "S+ %H:%M:%S");
        }
        return ipmiTimestampFmt(stamp, "S+ %y/%j %H:%M:%S");
    }
    return ipmiTimestampFmt(stamp, "%x %X %Z");
}

/// `ipmi_timestamp_date()`: `MM/DD/YYYY ZZZ`.
pub fn ipmiTimestampDate(stamp: u32) callconv(.c) [*c]u8 {
    if (!isValid(stamp)) return unspecified();

    if (isSpecial(stamp)) return ipmiTimestampFmt(stamp, "S+ %y/%j");
    return ipmiTimestampFmt(stamp, "%x");
}

/// `ipmi_timestamp_time()`: `HH:MM:SS ZZZ`.
///
/// The format is the same for normal and special timestamps.
pub fn ipmiTimestampTime(stamp: u32) callconv(.c) [*c]u8 {
    if (!isValid(stamp)) return unspecified();
    return ipmiTimestampFmt(stamp, "%X %Z");
}

// ---------------------------------------------------------------------------
// C ABI surface
// ---------------------------------------------------------------------------

/// Called at comptime from `src/zig/exports.zig` when `time` is selected.
///
/// The ABI assertions live here rather than at file scope so that they are
/// only analysed when the module is actually selected - see the note in
/// doc/zig-migration/varargs-trampoline.md.
pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(ipmiLocaltime2utc), @TypeOf(c.ipmi_localtime2utc));
    abi.assertCallSignature(@TypeOf(ipmiStrftime), @TypeOf(c.ipmi_strftime));
    abi.assertCallSignature(@TypeOf(ipmiAsctimeR), @TypeOf(c.ipmi_asctime_r));
    abi.assertCallSignature(@TypeOf(ipmiTimestampFmt), @TypeOf(c.ipmi_timestamp_fmt));
    abi.assertCallSignature(@TypeOf(ipmiTimestampString), @TypeOf(c.ipmi_timestamp_string));
    abi.assertCallSignature(@TypeOf(ipmiTimestampNumeric), @TypeOf(c.ipmi_timestamp_numeric));
    abi.assertCallSignature(@TypeOf(ipmiTimestampDate), @TypeOf(c.ipmi_timestamp_date));
    abi.assertCallSignature(@TypeOf(ipmiTimestampTime), @TypeOf(c.ipmi_timestamp_time));

    @export(&time_in_utc, .{ .name = "time_in_utc", .linkage = .strong });
    @export(&ipmiLocaltime2utc, .{ .name = "ipmi_localtime2utc", .linkage = .strong });
    @export(&ipmiStrftime, .{ .name = "ipmi_strftime", .linkage = .strong });
    @export(&ipmiAsctimeR, .{ .name = "ipmi_asctime_r", .linkage = .strong });
    @export(&ipmiTimestampFmt, .{ .name = "ipmi_timestamp_fmt", .linkage = .strong });
    @export(&ipmiTimestampString, .{ .name = "ipmi_timestamp_string", .linkage = .strong });
    @export(&ipmiTimestampNumeric, .{ .name = "ipmi_timestamp_numeric", .linkage = .strong });
    @export(&ipmiTimestampDate, .{ .name = "ipmi_timestamp_date", .linkage = .strong });
    @export(&ipmiTimestampTime, .{ .name = "ipmi_timestamp_time", .linkage = .strong });
}

comptime {
    if (@sizeOf(DateBuf) != asctime_sz) @compileError("ipmi_datebuf_t size drift");
    if (c.IPMI_ASCTIME_SZ != asctime_sz) @compileError("IPMI_ASCTIME_SZ drift");
    if (c.SECONDS_A_DAY != seconds_a_day) @compileError("SECONDS_A_DAY drift");
}

// ---------------------------------------------------------------------------
// Tests
//
// Everything here goes through libc only, so it runs in the ABI test binary.
// `TZ` is forced to UTC where the expected output would otherwise depend on the
// machine, and the tests that pin the upstream bugs say so explicitly.
// ---------------------------------------------------------------------------

/// Point libc at a fixed timezone for the duration of a test.
fn setTimezone(tz: [*:0]const u8) void {
    _ = c.setenv("TZ", tz, 1);
    c.tzset();
}

test "constants match ipmi_time.h" {
    try std.testing.expectEqual(@as(c.time_t, c.IPMI_TIME_UNSPECIFIED), time_unspecified);
    try std.testing.expectEqual(@as(c.time_t, c.IPMI_TIME_INIT_DONE), time_init_done);
    try std.testing.expectEqual(@as(c.time_t, c.SECONDS_A_DAY), seconds_a_day);
    try std.testing.expectEqual(@as(usize, c.IPMI_ASCTIME_SZ), asctime_sz);
}

test "timestamp predicates" {
    try std.testing.expect(isSpecial(0));
    try std.testing.expect(isSpecial(time_init_done - 1));
    try std.testing.expect(!isSpecial(time_init_done));
    try std.testing.expect(isValid(0));
    try std.testing.expect(isValid(time_init_done));
    try std.testing.expect(!isValid(time_unspecified));
}

test "the unspecified timestamp ignores the format" {
    var buf: DateBuf = undefined;
    const written = ipmiStrftime(&buf, buf.len, "%Y", time_unspecified);
    try std.testing.expectEqual(@as(usize, 7), written);
    try std.testing.expectEqualStrings("Unknown", buf[0..7]);

    try std.testing.expectEqualStrings(
        "Unspecified",
        std.mem.span(ipmiTimestampString(0xFFFFFFFF)),
    );
    try std.testing.expectEqualStrings(
        "Unspecified",
        std.mem.span(ipmiTimestampNumeric(0xFFFFFFFF)),
    );
    try std.testing.expectEqualStrings(
        "Unspecified",
        std.mem.span(ipmiTimestampDate(0xFFFFFFFF)),
    );
    try std.testing.expectEqualStrings(
        "Unspecified",
        std.mem.span(ipmiTimestampTime(0xFFFFFFFF)),
    );
}

test "relative timestamps are formatted without a timezone offset" {
    setTimezone("EST5EDT");
    defer setTimezone("UTC");

    // Below IPMI_TIME_INIT_DONE the stamp counts seconds since BMC start and
    // gmtime_r() is used whatever the local timezone is.
    var buf: DateBuf = undefined;
    _ = ipmiStrftime(&buf, buf.len, "%H:%M:%S", 3661);
    try std.testing.expectEqualStrings("01:01:01", buf[0..8]);

    try std.testing.expectEqualStrings(
        "S+ 01:01:01",
        std.mem.span(ipmiTimestampString(3661)),
    );
    try std.testing.expectEqualStrings(
        "S+ 01:01:01",
        std.mem.span(ipmiTimestampNumeric(3661)),
    );
    try std.testing.expectEqualStrings(
        "S+ 70/001",
        std.mem.span(ipmiTimestampDate(3661)),
    );
}

test "a long relative timestamp switches to the years/days form" {
    const stamp: u32 = 100 * @as(u32, @intCast(seconds_a_day));
    try std.testing.expectEqualStrings(
        "S+ 70 years 101 days 00:00:00",
        std.mem.span(ipmiTimestampString(stamp)),
    );
    try std.testing.expectEqualStrings(
        "S+ 70/101 00:00:00",
        std.mem.span(ipmiTimestampNumeric(stamp)),
    );
}

test "absolute timestamps honour the -Z option" {
    setTimezone("EST5EDT");
    defer {
        setTimezone("UTC");
        time_in_utc = false;
    }

    // 2018-06-30 21:49:08 UTC, comfortably above IPMI_TIME_INIT_DONE.
    const stamp: u32 = 1530395348;
    var buf: DateBuf = undefined;

    time_in_utc = false;
    _ = ipmiStrftime(&buf, buf.len, "%Y-%m-%d %H:%M:%S", stamp);
    try std.testing.expectEqualStrings("2018-06-30 17:49:08", buf[0..19]);

    time_in_utc = true;
    _ = ipmiStrftime(&buf, buf.len, "%Y-%m-%d %H:%M:%S", stamp);
    try std.testing.expectEqualStrings("2018-06-30 21:49:08", buf[0..19]);
}

test "BUG: ipmi_asctime_r discards the relative form it just computed" {
    setTimezone("UTC");

    // Upstream computes "S+01:01:01" and then overwrites the whole buffer with
    // the "%c %Z" rendering of the same stamp.  Preserved deliberately; see the
    // module comment and the follow-up issue linked from the pull request.
    var buf: DateBuf = .{0} ** asctime_sz;
    _ = ipmiAsctimeR(3661, &buf);

    const text = std.mem.sliceTo(&buf, 0);
    try std.testing.expect(!std.mem.startsWith(u8, text, "S+"));
    try std.testing.expect(std.mem.indexOf(u8, text, "1970") != null);
}

test "BUG: ipmi_strftime clobbers the libc daylight global" {
    setTimezone("EST5EDT");
    defer setTimezone("UTC");

    // `daylight` is an output of tzset(); formatting a single UTC timestamp
    // leaves it at -1 for the rest of the process.
    var buf: DateBuf = undefined;
    time_in_utc = true;
    defer time_in_utc = false;
    _ = ipmiStrftime(&buf, buf.len, "%Y", 1530395348);

    try std.testing.expectEqual(@as(c_int, -1), c.daylight);
}

test "BUG: ipmi_localtime2utc round trips through gmtime_r and mktime" {
    setTimezone("UTC");

    // In UTC the round trip is the identity, which is the only case upstream
    // gets right.
    try std.testing.expectEqual(@as(c.time_t, 1530395348), ipmiLocaltime2utc(1530395348));

    // Away from UTC the offset is applied in the wrong direction, and with
    // tm_isdst = -1 the answer depends on whether the *reassembled* date is in
    // DST rather than the input date.  EST5EDT is UTC-5, DST in June, so the
    // 21:49:08 UTC fields are re-read as 21:49:08 EDT, i.e. UTC+4h.
    setTimezone("EST5EDT");
    try std.testing.expectEqual(
        @as(c.time_t, 1530395348 + 4 * 60 * 60),
        ipmiLocaltime2utc(1530395348),
    );
    setTimezone("UTC");
}
