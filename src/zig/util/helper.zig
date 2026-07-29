//! Port of `lib/helper.c` and `include/ipmitool/helper.h`.
//!
//! Selected with `zig build -Dzig-modules=helper`, which drops `lib/helper.c`
//! from the compile and links this module instead.  Almost every translation
//! unit in the tree calls something here, so the substitution has to be exact:
//! the acceptance criterion for this port is that the bytes ipmitool writes do
//! not change.
//!
//! Three conventions follow from that:
//!
//! * **Formatting stays in libc.**  `snprintf`, `printf` and `fprintf` are
//!   called through the bridge rather than reimplemented with `std.fmt`, so
//!   `%2.2x`, `%-32s`, `%#x` and the stdout/stderr interleaving are produced by
//!   the same code as before.  `std.fmt` would also have to reproduce glibc's
//!   locale handling, which is not worth the risk for output nobody wants to
//!   change.
//! * **Parsing stays in libc** for the same reason: `str2long()` and friends
//!   accept exactly what `strtol()` accepts, including the `0x`/`0` prefixes,
//!   leading whitespace and a lone `+`, and report overflow through `errno`.
//! * **Static buffers keep their C lifetimes.**  `buf2str()`, `mac2str()` and
//!   the `Unknown (0x..)` fallback all return pointers into module-level
//!   storage that the next call overwrites; callers must not free them.  No
//!   function in this module allocates, so no allocator is threaded through
//!   it - the one C allocation site, `logpriv`, lives in `util/log.zig`.
//!
//! Like `util/log.zig`, the `@export` calls are gathered in `exportSymbols()`
//! and only run when `helper` is selected; see `src/zig/exports.zig`.

const std = @import("std");
const builtin = @import("builtin");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("log.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;

/// `IPMI_UID_MIN`: UID 0 is reserved by the specification.
pub const uid_min: u8 = c.IPMI_UID_MIN;

/// `IPMI_UID_MAX`.
pub const uid_max: u8 = c.IPMI_UID_MAX;

/// `BUF2STR_MAXIMUM_OUTPUT_SIZE`.
pub const buf2str_max_output_size = 3 * 1024 + 1;

/// `struct valstr`: one value/name pair, terminated by a `.str == null` entry.
pub const ValStr = extern struct {
    val: u32,
    str: ?[*:0]const u8,
};

/// `struct oemvalstr`: as `ValStr`, but keyed by IANA number as well.  The
/// terminator has `oem == 0xffffff`.
pub const OemValStr = extern struct {
    oem: u32,
    val: u16,
    str: ?[*:0]const u8,
};

comptime {
    abi.assertLayout(ValStr, c.struct_valstr);
    abi.assertLayout(OemValStr, c.struct_oemvalstr);
}

// ---------------------------------------------------------------------------
// Byte buffers
// ---------------------------------------------------------------------------

/// `buf2long()`: little-endian 32-bit load.
pub fn buf2long(buf: [*]const u8) callconv(.c) u32 {
    return @as(u32, buf[3]) << 24 | @as(u32, buf[2]) << 16 |
        @as(u32, buf[1]) << 8 | @as(u32, buf[0]);
}

/// `buf2short()`: little-endian 16-bit load.
pub fn buf2short(buf: [*]const u8) callconv(.c) u16 {
    return @as(u16, buf[1]) << 8 | @as(u16, buf[0]);
}

/// `static char str[BUF2STR_MAXIMUM_OUTPUT_SIZE]` inside `buf2str_extended()`.
var buf2str_storage: [buf2str_max_output_size]u8 = undefined;

/// `buf2str_extended()`: hex dump of `buf` with an optional separator.
///
/// Returns a pointer to module-level storage that the next call overwrites; the
/// caller must not free it.  Output longer than the buffer is truncated at a
/// byte or separator boundary, exactly as the C `snprintf()` accounting did.
pub fn buf2strExtended(
    buf: ?[*]const u8,
    len: c_int,
    sep: ?[*:0]const u8,
) callconv(.c) [*:0]const u8 {
    const str = &buf2str_storage;
    const data = buf orelse {
        _ = c.snprintf(str, str.len, "<NULL>");
        return @ptrCast(str);
    };

    // `cur + left == str.len` throughout, mirroring the C pointer/counter pair.
    var cur: usize = 0;
    var left: c_int = str.len;
    const sep_len: c_int = if (sep) |s| @intCast(std.mem.len(s)) else 0;

    var i: c_int = 0;
    while (i < len) : (i += 1) {
        // May return more than 2, depending on locale.
        const sz = c.snprintf(
            str[cur..].ptr,
            @intCast(left),
            "%2.2x",
            @as(c_uint, data[@intCast(i)]),
        );
        if (sz >= left) {
            // Buffer overflow, truncate.
            break;
        }
        cur += @intCast(sz);
        left -= sz;

        // Do not write a separator after the last byte.
        if (sep) |s| {
            if (i == len - 1) continue;
            if (sep_len >= left) break;
            // C passes `left - sz`, which only ever zero-fills past the copy.
            _ = c.strncpy(str[cur..].ptr, s, @intCast(left - sz));
            cur += @intCast(sep_len);
            left -= sep_len;
        }
    }
    str[cur] = 0;

    return @ptrCast(str);
}

/// `buf2str()`: `buf2str_extended()` with no separator.
pub fn buf2str(buf: ?[*]const u8, len: c_int) callconv(.c) [*:0]const u8 {
    return buf2strExtended(buf, len, null);
}

/// `ipmi_parse_hex()`: decode a string of two-character hex numbers.
///
/// Returns 0 for an empty string, -1 for an odd length, -2 for a NULL output,
/// -3 for a non-hexadecimal character, and otherwise the number of decoded
/// bytes - which may exceed `size`, in which case the excess is dropped.
pub fn ipmiParseHex(str: [*:0]const u8, out: ?[*]u8, size: c_int) callconv(.c) c_int {
    var len: c_int = @intCast(std.mem.len(str));
    if (len == 0) return 0;
    if (@rem(len, 2) != 0) return -1;

    // Out bytes.
    len = @divTrunc(len, 2);
    const dest = out orelse return -2;
    const capacity: usize = if (size > 0) @intCast(size) else 0;

    var b: u8 = 0;
    var shift: u3 = 4;
    var q: usize = 0;
    var p: usize = 0;
    while (str[p] != 0) : (p += 1) {
        const ch = str[p];
        if (!std.ascii.isHex(ch)) return -3;

        const d: u8 = if (ch < 'A')
            // It must be 0-9.
            ch - '0'
        else
            // It is A-F or a-f; lowercase it and map to 10-15.
            (ch | 0x20) - 'a' + 10;

        if (q < capacity) {
            // There is space, store.
            b += d << shift;
            if (shift != 0) {
                shift = 0;
            } else {
                shift = 4;
                dest[q] = b;
                b = 0;
                q += 1;
            }
        }
    }

    return len;
}

/// `printbuf()`: hex dump to stderr, 16 bytes per line, when `-v` is on.
pub fn printbuf(buf: [*]const u8, len: c_int, desc: ?[*:0]const u8) callconv(.c) void {
    if (len <= 0) return;
    if (c.verbose < 1) return;

    _ = c.fprintf(c.stderr, "%s (%d bytes)\n", @as([*c]const u8, @ptrCast(desc)), len);
    var i: c_int = 0;
    while (i < len) : (i += 1) {
        if (@rem(i, 16) == 0 and i != 0) _ = c.fprintf(c.stderr, "\n");
        _ = c.fprintf(c.stderr, " %2.2x", @as(c_uint, buf[@intCast(i)]));
    }
    _ = c.fprintf(c.stderr, "\n");
}

/// `array_byteswap()`: reverse a byte array in place.
///
/// A zero length is a no-op; C computes `length - 1` unconditionally, so the
/// wrapping subtraction here is deliberate.
pub fn arrayByteswap(buffer: [*]u8, length: usize) callconv(.c) [*]u8 {
    const max = length -% 1;
    var i: usize = 0;
    while (i < length / 2) : (i += 1) {
        const temp = buffer[i];
        buffer[i] = buffer[max - i];
        buffer[max - i] = temp;
    }
    return buffer;
}

/// `array_ntoh()`: big-endian (network) to host order.
pub fn arrayNtoh(buffer: [*]u8, length: usize) callconv(.c) [*]u8 {
    if (builtin.target.cpu.arch.endian() == .big) return buffer;
    return arrayByteswap(buffer, length);
}

/// `array_letoh()`: little-endian (IPMI) to host order.
pub fn arrayLetoh(buffer: [*]u8, length: usize) callconv(.c) [*]u8 {
    if (builtin.target.cpu.arch.endian() == .big) return arrayByteswap(buffer, length);
    return buffer;
}

/// `str2mac()`: parse `xx:xx:xx:xx:xx:xx` into six bytes.
///
/// `sscanf()` does the parsing so that the accepted syntax - which the `%02x`
/// width makes laxer than it looks - is unchanged.  Returns 0 or -1.
pub fn str2mac(arg: [*:0]const u8, buf: [*]u8) callconv(.c) c_int {
    var m = [_]c_uint{0} ** 6;
    if (c.sscanf(
        arg,
        "%02x:%02x:%02x:%02x:%02x:%02x",
        &m[0],
        &m[1],
        &m[2],
        &m[3],
        &m[4],
        &m[5],
    ) != 6) {
        c.lprintf(log.Level.err, "Invalid MAC address: %s", arg);
        return -1;
    }
    for (m) |octet| {
        if (octet > std.math.maxInt(u8)) {
            c.lprintf(log.Level.err, "Invalid MAC address: %s", arg);
            return -1;
        }
    }
    for (m, 0..) |octet, i| buf[i] = @intCast(octet);
    return 0;
}

/// `mac2str()`: six bytes as `xx:xx:xx:xx:xx:xx`.
///
/// Shares `buf2str()`'s static buffer; the next call to either overwrites it.
pub fn mac2str(buf: [*]const u8) callconv(.c) [*:0]const u8 {
    return buf2strExtended(buf, 6, ":");
}

// ---------------------------------------------------------------------------
// Value/name tables
// ---------------------------------------------------------------------------

/// `find_val_idx()`: index of `val` in `vs`, or null when it is absent.
fn findValIdx(val: u32, vs: ?[*]const ValStr) ?usize {
    if (vs) |table| {
        var i: usize = 0;
        while (table[i].str != null) : (i += 1) {
            if (table[i].val == val) return i;
        }
    }
    return null;
}

/// `static char un_str[32]` inside `unknown_val_str()`.
var unknown_val_storage: [32]u8 = undefined;

/// `unknown_val_str()`: the `Unknown (0x2A)` fallback.
///
/// Returns module-level storage, like the rest of ipmitool's string helpers.
fn unknownValStr(val: u32) [*:0]const u8 {
    @memset(&unknown_val_storage, 0);
    _ = c.snprintf(&unknown_val_storage, unknown_val_storage.len, "Unknown (0x%02X)", val);
    return @ptrCast(&unknown_val_storage);
}

/// `specific_val2str()`: look `val` up in `specific`, then in `generic`.
pub fn specificVal2str(
    val: u32,
    specific: ?[*]const ValStr,
    generic: ?[*]const ValStr,
) callconv(.c) [*:0]const u8 {
    if (findValIdx(val, specific)) |i| return specific.?[i].str.?;
    if (findValIdx(val, generic)) |i| return generic.?[i].str.?;
    return unknownValStr(val);
}

/// `val2str()`: name of `val` in `vs`, or the `Unknown (0x..)` fallback.
pub fn val2str(val: u32, vs: ?[*]const ValStr) callconv(.c) [*:0]const u8 {
    return specificVal2str(val, null, vs);
}

/// `oemval2str()`: name of `val` for IANA number `oem`.
///
/// Keeps the upstream FIXME: a PICMG entry matches every IANA number.
pub fn oemval2str(oem: u32, val: u32, vs: [*]const OemValStr) callconv(.c) [*:0]const u8 {
    const picmg: u32 = @intCast(c.IPMI_OEM_PICMG);
    var i: usize = 0;
    while (vs[i].oem != 0xffffff and vs[i].str != null) : (i += 1) {
        if ((vs[i].oem == oem or vs[i].oem == picmg) and vs[i].val == val) {
            return vs[i].str.?;
        }
    }
    return unknownValStr(val);
}

/// `str2val32()`: value whose name matches `str`, case insensitively.
///
/// Returns the terminator entry's `val` when nothing matches, which is how the
/// tables encode their own "unknown" value.
pub fn str2val32(str: [*:0]const u8, vs: [*]const ValStr) callconv(.c) u32 {
    var i: usize = 0;
    while (vs[i].str) |candidate| : (i += 1) {
        if (c.strcasecmp(candidate, str) == 0) return vs[i].val;
    }
    return vs[i].val;
}

/// `str2val()`, the `static inline` 16-bit wrapper in `helper.h`.
pub fn str2val(str: [*:0]const u8, vs: [*]const ValStr) u16 {
    return @truncate(str2val32(str, vs));
}

/// `print_valstr()`: dump a table to stdout (`loglevel < 0`) or to the log.
pub fn printValstr(vs: ?[*]const ValStr, title: ?[*:0]const u8, loglevel: c_int) callconv(.c) void {
    const table = vs orelse return;

    if (title) |name| {
        if (loglevel < 0) {
            _ = c.printf("\n%s:\n\n", name);
        } else {
            c.lprintf(loglevel, "\n%s:\n", name);
        }
    }

    if (loglevel < 0) {
        _ = c.printf("  VALUE\tHEX\tSTRING\n");
        _ = c.printf("==============================================\n");
    } else {
        c.lprintf(loglevel, "  VAL\tHEX\tSTRING");
        c.lprintf(loglevel, "==============================================");
    }

    var i: usize = 0;
    while (table[i].str) |str| : (i += 1) {
        const val = table[i].val;
        if (loglevel < 0) {
            if (val < 256) {
                _ = c.printf("  %d\t0x%02x\t%s\n", val, val, str);
            } else {
                _ = c.printf("  %d\t0x%04x\t%s\n", val, val, str);
            }
        } else {
            if (val < 256) {
                c.lprintf(loglevel, "  %d\t0x%02x\t%s", val, val, str);
            } else {
                c.lprintf(loglevel, "  %d\t0x%04x\t%s", val, val, str);
            }
        }
    }

    if (loglevel < 0) {
        _ = c.printf("\n");
    } else {
        c.lprintf(loglevel, "");
    }
}

/// `print_valstr_2col()`: as `printValstr()`, but two entries per line.
pub fn printValstr2col(vs: ?[*]const ValStr, title: ?[*:0]const u8, loglevel: c_int) callconv(.c) void {
    const table = vs orelse return;

    if (title) |name| {
        if (loglevel < 0) {
            _ = c.printf("\n%s:\n\n", name);
        } else {
            c.lprintf(loglevel, "\n%s:\n", name);
        }
    }

    var i: usize = 0;
    while (table[i].str) |str| : (i += 1) {
        if (table[i + 1].str) |next| {
            if (loglevel < 0) {
                _ = c.printf(
                    "  %4d  %-32s    %4d  %-32s\n",
                    table[i].val,
                    str,
                    table[i + 1].val,
                    next,
                );
            } else {
                c.lprintf(
                    loglevel,
                    "  %4d  %-32s    %4d  %-32s\n",
                    table[i].val,
                    str,
                    table[i + 1].val,
                    next,
                );
            }
            // Consumed two entries; the loop's own increment adds the second.
            i += 1;
        } else {
            // Last one.
            if (loglevel < 0) {
                _ = c.printf("  %4d  %-32s\n", table[i].val, str);
            } else {
                c.lprintf(loglevel, "  %4d  %-32s\n", table[i].val, str);
            }
        }
    }

    if (loglevel < 0) {
        _ = c.printf("\n");
    } else {
        c.lprintf(loglevel, "");
    }
}

// ---------------------------------------------------------------------------
// String to number conversions
//
// All of these return 0 on success, -1 for a NULL argument, -2 for trailing
// garbage and -3 for an out of range value.  On -2 the caller's variable holds
// whatever `strtoX()` managed to parse, and on -3 it holds the full value: the
// C code only zeroes it when the underlying parse failed, and code in the tree
// relies on nothing more than the return code.
// ---------------------------------------------------------------------------

/// `str2double()`.
pub fn str2double(str: ?[*:0]const u8, double_ptr: ?*f64) callconv(.c) c_int {
    const source = str orelse return -1;
    const out = double_ptr orelse return -1;

    out.* = 0;
    std.c._errno().* = 0;
    var end_ptr: [*c]u8 = null;
    out.* = c.strtod(source, &end_ptr);

    if (end_ptr[0] != 0) return -2;
    if (std.c._errno().* != 0) return -3;
    return 0;
}

/// `str2long()`.
pub fn str2long(str: ?[*:0]const u8, lng_ptr: ?*i64) callconv(.c) c_int {
    const source = str orelse return -1;
    const out = lng_ptr orelse return -1;

    out.* = 0;
    std.c._errno().* = 0;
    var end_ptr: [*c]u8 = null;
    out.* = c.strtol(source, &end_ptr, 0);

    if (end_ptr[0] != 0) return -2;
    if (std.c._errno().* != 0) return -3;
    return 0;
}

/// `str2ulong()`.
pub fn str2ulong(str: ?[*:0]const u8, ulng_ptr: ?*u64) callconv(.c) c_int {
    const source = str orelse return -1;
    const out = ulng_ptr orelse return -1;

    out.* = 0;
    std.c._errno().* = 0;
    var end_ptr: [*c]u8 = null;
    out.* = c.strtoul(source, &end_ptr, 0);

    if (end_ptr[0] != 0) return -2;
    if (std.c._errno().* != 0) return -3;
    return 0;
}

/// Shared body of `str2int()`, `str2short()` and `str2char()`.
fn parseSigned(comptime T: type, str: ?[*:0]const u8, out_ptr: ?*T) c_int {
    if (str == null) return -1;
    const out = out_ptr orelse return -1;

    var arg_long: i64 = 0;
    const rc = str2long(str, &arg_long);
    if (rc != 0) {
        out.* = 0;
        return rc;
    }

    if (arg_long < std.math.minInt(T) or arg_long > std.math.maxInt(T)) return -3;

    out.* = @intCast(arg_long);
    return 0;
}

/// Shared body of `str2uint()`, `str2ushort()` and `str2uchar()`.
fn parseUnsigned(comptime T: type, str: ?[*:0]const u8, out_ptr: ?*T) c_int {
    if (str == null) return -1;
    const out = out_ptr orelse return -1;

    var arg_ulong: u64 = 0;
    const rc = str2ulong(str, &arg_ulong);
    if (rc != 0) {
        out.* = 0;
        return rc;
    }

    if (arg_ulong > std.math.maxInt(T)) return -3;

    out.* = @intCast(arg_ulong);
    return 0;
}

/// `str2int()`.
pub fn str2int(str: ?[*:0]const u8, int_ptr: ?*i32) callconv(.c) c_int {
    return parseSigned(i32, str, int_ptr);
}

/// `str2uint()`.
pub fn str2uint(str: ?[*:0]const u8, uint_ptr: ?*u32) callconv(.c) c_int {
    return parseUnsigned(u32, str, uint_ptr);
}

/// `str2short()`.
pub fn str2short(str: ?[*:0]const u8, shrt_ptr: ?*i16) callconv(.c) c_int {
    return parseSigned(i16, str, shrt_ptr);
}

/// `str2ushort()`.
pub fn str2ushort(str: ?[*:0]const u8, ushrt_ptr: ?*u16) callconv(.c) c_int {
    return parseUnsigned(u16, str, ushrt_ptr);
}

/// `str2char()`.
pub fn str2char(str: ?[*:0]const u8, chr_ptr: ?*i8) callconv(.c) c_int {
    return parseSigned(i8, str, chr_ptr);
}

/// `str2uchar()`.
pub fn str2uchar(str: ?[*:0]const u8, uchr_ptr: ?*u8) callconv(.c) c_int {
    return parseUnsigned(u8, str, uchr_ptr);
}

// ---------------------------------------------------------------------------
// Miscellany
// ---------------------------------------------------------------------------

/// `ipmi_csum()`: two's complement checksum of the first `s` bytes of `d`.
pub fn ipmiCsum(d: [*]const u8, s: c_int) callconv(.c) u8 {
    var sum: u8 = 0;
    var i: c_int = 0;
    while (i < s) : (i += 1) sum +%= d[@intCast(i)];
    return 0 -% sum;
}

/// `S_ISREG()`, which `translate-c` cannot bring over from `<sys/stat.h>`.
fn isRegularFile(mode: c.__mode_t) bool {
    return (mode & @as(c.__mode_t, @intCast(c.S_IFMT))) == @as(c.__mode_t, @intCast(c.S_IFREG));
}

/// C's `(int)` conversion: truncating and never trapping.
fn toCInt(value: anytype) c_int {
    comptime std.debug.assert(@bitSizeOf(c_int) == 32);
    return @bitCast(@as(u32, @truncate(value)));
}

/// `FILE *` as the bridge spells it.
///
/// It is not the same type on every target: glibc's `struct _IO_FILE` is
/// complete on aarch64, where translate-c produces `[*c]FILE`, and opaque on
/// x86-64, where it produces `?*FILE` because a C pointer to an opaque type is
/// not indexable.  Taking the type from `fopen()` keeps this compiling - and
/// ABI-identical - on both.
const FilePtr = @typeInfo(@TypeOf(c.fopen)).@"fn".return_type.?;

/// `ipmi_open_file()`: open `file`, refusing links and shared inodes.
///
/// Needs a complete `struct stat` from the bridge, which translate-c only
/// produces for glibc; a musl target renders it `opaque` and this function will
/// not compile.  glibc is what CI builds and what the autotools oracle used, so
/// that is accepted for now.
///
/// Returns an owning `FILE *` the caller closes with `fclose()`, or NULL.  The
/// diagnostics deliberately keep C's mismatched `%d` conversions for
/// `st_ino`/`st_nlink`: the values are passed with the same widths, so the same
/// low bits are printed.
pub fn ipmiOpenFile(file: [*:0]const u8, rw: c_int) callconv(.c) FilePtr {
    var st1: c.struct_stat = undefined;
    var st2: c.struct_stat = undefined;

    // Verify existence.
    if (c.lstat(file, &st1) < 0) {
        if (rw != 0) {
            // Does not exist, ok to create.
            const fp = c.fopen(file, "w");
            if (fp == null) {
                c.lperror(log.Level.err, "Unable to open file %s for write", file);
                return null;
            }
            // Created ok, now return the descriptor.
            return fp;
        }
        c.lprintf(log.Level.err, "File %s does not exist", file);
        return null;
    }

    if (!@hasDecl(c, "ENABLE_FILE_SECURITY")) {
        if (rw == 0) {
            // On read skip the extra checks.
            const fp = c.fopen(file, "r");
            if (fp == null) {
                c.lperror(log.Level.err, "Unable to open file %s", file);
                return null;
            }
            return fp;
        }
    }

    // It exists - only regular files, not links.
    if (!isRegularFile(st1.st_mode)) {
        c.lprintf(log.Level.err, "File %s has invalid mode: %d", file, st1.st_mode);
        return null;
    }

    // Allow only files with 1 link (itself).
    if (st1.st_nlink != 1) {
        c.lprintf(
            log.Level.err,
            "File %s has invalid link count: %d != 1",
            file,
            toCInt(st1.st_nlink),
        );
        return null;
    }

    const fp = c.fopen(file, if (rw != 0) "w+" else "r");
    if (fp == null) {
        c.lperror(log.Level.err, "Unable to open file %s", file);
        return null;
    }

    // Stat again.
    if (c.fstat(c.fileno(fp), &st2) < 0) {
        c.lperror(log.Level.err, "Unable to stat file %s", file);
        _ = c.fclose(fp);
        return null;
    }

    // Verify inode.
    if (st1.st_ino != st2.st_ino) {
        c.lprintf(
            log.Level.err,
            "File %s has invalid inode: %d != %d",
            file,
            st1.st_ino,
            st2.st_ino,
        );
        _ = c.fclose(fp);
        return null;
    }

    // Verify owner.
    if (st1.st_uid != st2.st_uid) {
        c.lprintf(
            log.Level.err,
            "File %s has invalid user id: %d != %d",
            file,
            st1.st_uid,
            st2.st_uid,
        );
        _ = c.fclose(fp);
        return null;
    }

    // Verify inode.
    if (st2.st_nlink != 1) {
        c.lprintf(
            log.Level.err,
            "File %s has invalid link count: %d != 1",
            file,
            st2.st_nlink,
        );
        _ = c.fclose(fp);
        return null;
    }

    return fp;
}

/// `signal(sig, SIG_IGN)`.
///
/// The bridge cannot expose `SIG_IGN`: translate-c renders it as a function
/// pointer built from the integer 1, which is not a legal address for a
/// function pointer on targets whose instructions are aligned (aarch64 wants
/// 4).  `sigaction()` with `std.c.SIG.IGN` is the same libc call underneath -
/// glibc's `signal()` is a `sigaction()` wrapper - and for a signal that is
/// being *ignored* the flags and mask that `signal()` would additionally set
/// have no observable effect.
fn ignoreSignal(sig: c_int) void {
    var act = std.mem.zeroes(std.c.Sigaction);
    act.handler = .{ .handler = std.c.SIG.IGN };
    _ = std.c.sigaction(@enumFromInt(sig), &act, null);
}

/// `ipmi_start_daemon()`: fork into the background, keeping `intf->fd` open.
pub fn ipmiStartDaemon(intf: *Intf) callconv(.c) void {
    var sighup: c.sigset_t = undefined;
    _ = c.sigemptyset(&sighup);
    _ = c.sigaddset(&sighup, c.SIGHUP);
    if (c.sigprocmask(c.SIG_UNBLOCK, &sighup, null) < 0) {
        _ = c.fprintf(c.stderr, "ERROR: could not unblock SIGHUP signal\n");
    }
    ignoreSignal(c.SIGHUP);
    ignoreSignal(c.SIGTTOU);
    ignoreSignal(c.SIGTTIN);
    ignoreSignal(c.SIGQUIT);
    ignoreSignal(c.SIGTSTP);

    var pid = c.fork();
    if (pid < 0 or pid > 0) c.exit(0);

    if (@hasDecl(c, "TIOCNOTTY")) {
        if (c.setpgid(0, c.getpid()) == -1) c.exit(1);
        const tty = c.open(c._PATH_TTY, c.O_RDWR);
        if (tty >= 0) {
            _ = c.ioctl(tty, @as(c_ulong, c.TIOCNOTTY), @as(?*anyopaque, null));
            _ = c.close(tty);
        }
    } else {
        if (c.setpgid(0, 0) == -1) c.exit(1);
        pid = c.fork();
        if (pid < 0 or pid > 0) c.exit(0);
    }

    if (c.chdir("/") != 0) {
        c.lprintf(
            log.Level.err,
            "chdir failed: %s (%d)",
            c.strerror(std.c._errno().*),
            std.c._errno().*,
        );
        c.exit(1);
    }
    _ = c.umask(0);

    var fd: c_int = 0;
    while (fd < 64) : (fd += 1) {
        if (fd != intf.fd) _ = c.close(fd);
    }

    fd = c.open("/dev/null", c.O_RDWR);
    if (fd != c.STDIN_FILENO) {
        c.lprintf(
            log.Level.err,
            "failed to reset stdin: %s (%d)",
            c.strerror(std.c._errno().*),
            std.c._errno().*,
        );
        c.exit(1);
    }
    if (c.dup(fd) != c.STDOUT_FILENO) {
        c.lprintf(
            log.Level.err,
            "failed to reset stdout: %s (%d)",
            c.strerror(std.c._errno().*),
            std.c._errno().*,
        );
        c.exit(1);
    }
    if (c.dup(fd) != c.STDERR_FILENO) {
        c.lprintf(
            log.Level.err,
            "failed to reset stderr: %s (%d)",
            c.strerror(std.c._errno().*),
            std.c._errno().*,
        );
        c.exit(1);
    }
}

/// `completion_code_vals`, defined by `lib/ipmi_strings.c`.
fn completionCodeVals() [*]const ValStr {
    return @ptrCast(c.completion_code_vals);
}

/// `eval_ccode()`: report the result of an `_ipmi_*` helper.
///
/// Returns 0 when `ccode` is 0 and -1 otherwise, printing the reason.
pub fn evalCcode(ccode: c_int) callconv(.c) c_int {
    if (ccode == 0) return 0;

    if (ccode < 0) {
        switch (ccode) {
            -1 => c.lprintf(log.Level.err, "IPMI response is NULL."),
            -2 => c.lprintf(log.Level.err, "Unexpected data length received."),
            -3 => c.lprintf(log.Level.err, "Invalid function parameter."),
            -4 => c.lprintf(log.Level.err, "ipmitool: malloc failure."),
            else => {},
        }
        return -1;
    }

    c.lprintf(
        log.Level.err,
        "IPMI command failed: %s",
        val2str(@intCast(ccode), completionCodeVals()),
    );
    return -1;
}

/// `is_fru_id()`: parse a FRU ID, `<0..255>`.
pub fn isFruId(argv_ptr: ?[*:0]const u8, fru_id_ptr: ?*u8) callconv(.c) c_int {
    if (argv_ptr == null or fru_id_ptr == null) {
        c.lprintf(log.Level.err, "is_fru_id(): invalid argument(s).");
        return -1;
    }

    if (str2uchar(argv_ptr, fru_id_ptr) == 0) return 0;

    c.lprintf(
        log.Level.err,
        "FRU ID '%s' is either invalid or out of range.",
        argv_ptr.?,
    );
    return -1;
}

/// `is_ipmi_channel_num()`: parse a channel number, `<0x0..0xB>` or
/// `<0xE..0xF>`.
pub fn isIpmiChannelNum(argv_ptr: ?[*:0]const u8, channel_ptr: ?*u8) callconv(.c) c_int {
    if (argv_ptr == null or channel_ptr == null) {
        c.lprintf(log.Level.err, "is_ipmi_channel_num(): invalid argument(s).");
        return -1;
    }

    if (str2uchar(argv_ptr, channel_ptr) == 0) {
        const channel = channel_ptr.?.*;
        if (channel <= 0xB or (channel >= 0xE and channel <= 0xF)) return 0;
    }

    c.lprintf(
        log.Level.err,
        "Given Channel number '%s' is either invalid or out of range.",
        argv_ptr.?,
    );
    c.lprintf(log.Level.err, "Channel number must be from ranges: <0x0..0xB>, <0xE..0xF>");
    return -1;
}

/// `is_ipmi_user_id()`: parse a user ID, `<IPMI_UID_MIN..IPMI_UID_MAX>`.
pub fn isIpmiUserId(argv_ptr: ?[*:0]const u8, ipmi_uid_ptr: ?*u8) callconv(.c) c_int {
    if (argv_ptr == null or ipmi_uid_ptr == null) {
        c.lprintf(log.Level.err, "is_ipmi_user_id(): invalid argument(s).");
        return -1;
    }

    if (str2uchar(argv_ptr, ipmi_uid_ptr) == 0) {
        const uid = ipmi_uid_ptr.?.*;
        if (uid >= uid_min and uid <= uid_max) return 0;
    }

    c.lprintf(
        log.Level.err,
        "Given User ID '%s' is either invalid or out of range.",
        argv_ptr.?,
    );
    c.lprintf(
        log.Level.err,
        "User ID is limited to range <%i..%i>.",
        @as(c_int, c.IPMI_UID_MIN),
        @as(c_int, c.IPMI_UID_MAX),
    );
    return -1;
}

/// `is_ipmi_user_priv_limit()`: parse a privilege limit, `<0x1..0x5>` or `0xF`.
pub fn isIpmiUserPrivLimit(
    argv_ptr: ?[*:0]const u8,
    ipmi_priv_limit_ptr: ?*u8,
) callconv(.c) c_int {
    if (argv_ptr == null or ipmi_priv_limit_ptr == null) {
        c.lprintf(log.Level.err, "is_ipmi_user_priv_limit(): invalid argument(s).");
        return -1;
    }

    const parsed = str2uchar(argv_ptr, ipmi_priv_limit_ptr) == 0;
    const bad_range = if (parsed) blk: {
        const limit = ipmi_priv_limit_ptr.?.*;
        break :blk (limit < 0x01 or limit > 0x05) and limit != 0x0F;
    } else false;
    if (!parsed or bad_range) {
        c.lprintf(log.Level.err, "Given Privilege Limit '%s' is invalid.", argv_ptr.?);
        c.lprintf(log.Level.err, "Privilege Limit is limited to <0x1..0x5> and <0xF>.");
        return -1;
    }
    return 0;
}

/// `ipmi_get_oem_id()`: Get Board ID, used to identify Sun/Tyan boards.
pub fn ipmiGetOemId(intf: *Intf) callconv(.c) u16 {
    var req = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = @intCast(c.IPMI_NETFN_TSOL);
    req.msg.cmd = 0x21;
    req.msg.data_len = 0;

    const rsp = intf.sendrecv.?(intf, &req) orelse {
        c.lprintf(log.Level.err, "Get Board ID command failed");
        return 0;
    };
    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Get Board ID command failed: %#x %s",
            @as(c_uint, rsp.ccode),
            val2str(rsp.ccode, completionCodeVals()),
        );
        return 0;
    }

    const oem_id = @as(u16, rsp.data[0]) | @as(u16, rsp.data[1]) << 8;
    c.lprintf(log.Level.debug, "Board ID: %x", @as(c_uint, oem_id));
    return oem_id;
}

/// `args2buf()`: parse up to `len` arguments as byte values into `out`.
///
/// Returns true on success.  A negative `argc` is treated as huge, as the C
/// cast to `size_t` did, so `len` alone bounds the loop.
pub fn args2buf(
    argc: c_int,
    argv: [*]const [*:0]const u8,
    out: [*]u8,
    len: usize,
) callconv(.c) bool {
    const count = @min(len, @as(usize, @bitCast(@as(isize, argc))));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var byte: u8 = 0;
        if (str2uchar(argv[i], &byte) != 0) {
            c.lprintf(log.Level.err, "Bad byte value: %s", argv[i]);
            return false;
        }
        out[i] = byte;
    }
    return true;
}

// ---------------------------------------------------------------------------
// `static inline` helpers from helper.h
//
// These have no symbol to replace; they are here so a ported module can use
// them without going through the bridge.
// ---------------------------------------------------------------------------

/// `ipmi16toh()`.
pub fn ipmi16toh(ipmi16: [*]const u8) u16 {
    return @as(u16, ipmi16[1]) << 8 | ipmi16[0];
}

/// `htoipmi16()`.
pub fn htoipmi16(h: u16, out: [*]u8) void {
    out[0] = @truncate(h);
    out[1] = @truncate(h >> 8);
}

/// `ipmi24toh()`.
pub fn ipmi24toh(ipmi24: [*]const u8) u32 {
    return @as(u32, ipmi24[2]) << 16 | @as(u32, ipmi24[1]) << 8 | ipmi24[0];
}

/// `htoipmi24()`.
pub fn htoipmi24(h: u32, out: [*]u8) void {
    out[0] = @truncate(h);
    out[1] = @truncate(h >> 8);
    out[2] = @truncate(h >> 16);
}

/// `ipmi32toh()`.
pub fn ipmi32toh(ipmi32: [*]const u8) u32 {
    return @as(u32, ipmi32[3]) << 24 | @as(u32, ipmi32[2]) << 16 |
        @as(u32, ipmi32[1]) << 8 | ipmi32[0];
}

/// `htoipmi32()`.
pub fn htoipmi32(h: u32, out: [*]u8) void {
    out[0] = @truncate(h);
    out[1] = @truncate(h >> 8);
    out[2] = @truncate(h >> 16);
    out[3] = @truncate(h >> 24);
}

/// `IS_SET()`.
pub fn isSet(value: anytype, bit: anytype) bool {
    return (value & (@as(@TypeOf(value), 1) << @intCast(bit))) != 0;
}

// ---------------------------------------------------------------------------
// C ABI surface
// ---------------------------------------------------------------------------

/// Called at comptime from `src/zig/exports.zig` when `helper` is selected.
///
/// The ABI assertions live here rather than at file scope so that they are
/// only analysed when the module is actually selected - see the note in
/// doc/zig-migration/varargs-trampoline.md.
pub fn exportSymbols() void {
    @setEvalBranchQuota(100_000);
    abi.assertCallSignature(@TypeOf(buf2long), @TypeOf(c.buf2long));
    abi.assertCallSignature(@TypeOf(buf2short), @TypeOf(c.buf2short));
    abi.assertCallSignature(@TypeOf(buf2strExtended), @TypeOf(c.buf2str_extended));
    abi.assertCallSignature(@TypeOf(buf2str), @TypeOf(c.buf2str));
    abi.assertCallSignature(@TypeOf(ipmiParseHex), @TypeOf(c.ipmi_parse_hex));
    abi.assertCallSignature(@TypeOf(printbuf), @TypeOf(c.printbuf));
    abi.assertCallSignature(@TypeOf(arrayByteswap), @TypeOf(c.array_byteswap));
    abi.assertCallSignature(@TypeOf(arrayNtoh), @TypeOf(c.array_ntoh));
    abi.assertCallSignature(@TypeOf(arrayLetoh), @TypeOf(c.array_letoh));
    abi.assertCallSignature(@TypeOf(str2mac), @TypeOf(c.str2mac));
    abi.assertCallSignature(@TypeOf(mac2str), @TypeOf(c.mac2str));
    abi.assertCallSignature(@TypeOf(specificVal2str), @TypeOf(c.specific_val2str));
    abi.assertCallSignature(@TypeOf(val2str), @TypeOf(c.val2str));
    abi.assertCallSignature(@TypeOf(oemval2str), @TypeOf(c.oemval2str));
    abi.assertCallSignature(@TypeOf(str2val32), @TypeOf(c.str2val32));
    abi.assertCallSignature(@TypeOf(printValstr), @TypeOf(c.print_valstr));
    abi.assertCallSignature(@TypeOf(printValstr2col), @TypeOf(c.print_valstr_2col));
    abi.assertCallSignature(@TypeOf(str2double), @TypeOf(c.str2double));
    abi.assertCallSignature(@TypeOf(str2long), @TypeOf(c.str2long));
    abi.assertCallSignature(@TypeOf(str2ulong), @TypeOf(c.str2ulong));
    abi.assertCallSignature(@TypeOf(str2int), @TypeOf(c.str2int));
    abi.assertCallSignature(@TypeOf(str2uint), @TypeOf(c.str2uint));
    abi.assertCallSignature(@TypeOf(str2short), @TypeOf(c.str2short));
    abi.assertCallSignature(@TypeOf(str2ushort), @TypeOf(c.str2ushort));
    abi.assertCallSignature(@TypeOf(str2char), @TypeOf(c.str2char));
    abi.assertCallSignature(@TypeOf(str2uchar), @TypeOf(c.str2uchar));
    abi.assertCallSignature(@TypeOf(ipmiCsum), @TypeOf(c.ipmi_csum));
    abi.assertCallSignature(@TypeOf(ipmiOpenFile), @TypeOf(c.ipmi_open_file));
    abi.assertCallSignature(@TypeOf(ipmiStartDaemon), @TypeOf(c.ipmi_start_daemon));
    abi.assertCallSignature(@TypeOf(evalCcode), @TypeOf(c.eval_ccode));
    abi.assertCallSignature(@TypeOf(isFruId), @TypeOf(c.is_fru_id));
    abi.assertCallSignature(@TypeOf(isIpmiChannelNum), @TypeOf(c.is_ipmi_channel_num));
    abi.assertCallSignature(@TypeOf(isIpmiUserId), @TypeOf(c.is_ipmi_user_id));
    abi.assertCallSignature(@TypeOf(isIpmiUserPrivLimit), @TypeOf(c.is_ipmi_user_priv_limit));
    abi.assertCallSignature(@TypeOf(ipmiGetOemId), @TypeOf(c.ipmi_get_oem_id));
    abi.assertCallSignature(@TypeOf(args2buf), @TypeOf(c.args2buf));

    @export(&buf2long, .{ .name = "buf2long", .linkage = .strong });
    @export(&buf2short, .{ .name = "buf2short", .linkage = .strong });
    @export(&buf2strExtended, .{ .name = "buf2str_extended", .linkage = .strong });
    @export(&buf2str, .{ .name = "buf2str", .linkage = .strong });
    @export(&ipmiParseHex, .{ .name = "ipmi_parse_hex", .linkage = .strong });
    @export(&printbuf, .{ .name = "printbuf", .linkage = .strong });
    @export(&arrayByteswap, .{ .name = "array_byteswap", .linkage = .strong });
    @export(&arrayNtoh, .{ .name = "array_ntoh", .linkage = .strong });
    @export(&arrayLetoh, .{ .name = "array_letoh", .linkage = .strong });
    @export(&str2mac, .{ .name = "str2mac", .linkage = .strong });
    @export(&mac2str, .{ .name = "mac2str", .linkage = .strong });
    @export(&specificVal2str, .{ .name = "specific_val2str", .linkage = .strong });
    @export(&val2str, .{ .name = "val2str", .linkage = .strong });
    @export(&oemval2str, .{ .name = "oemval2str", .linkage = .strong });
    @export(&str2val32, .{ .name = "str2val32", .linkage = .strong });
    @export(&printValstr, .{ .name = "print_valstr", .linkage = .strong });
    @export(&printValstr2col, .{ .name = "print_valstr_2col", .linkage = .strong });
    @export(&str2double, .{ .name = "str2double", .linkage = .strong });
    @export(&str2long, .{ .name = "str2long", .linkage = .strong });
    @export(&str2ulong, .{ .name = "str2ulong", .linkage = .strong });
    @export(&str2int, .{ .name = "str2int", .linkage = .strong });
    @export(&str2uint, .{ .name = "str2uint", .linkage = .strong });
    @export(&str2short, .{ .name = "str2short", .linkage = .strong });
    @export(&str2ushort, .{ .name = "str2ushort", .linkage = .strong });
    @export(&str2char, .{ .name = "str2char", .linkage = .strong });
    @export(&str2uchar, .{ .name = "str2uchar", .linkage = .strong });
    @export(&ipmiCsum, .{ .name = "ipmi_csum", .linkage = .strong });
    @export(&ipmiOpenFile, .{ .name = "ipmi_open_file", .linkage = .strong });
    @export(&ipmiStartDaemon, .{ .name = "ipmi_start_daemon", .linkage = .strong });
    @export(&evalCcode, .{ .name = "eval_ccode", .linkage = .strong });
    @export(&isFruId, .{ .name = "is_fru_id", .linkage = .strong });
    @export(&isIpmiChannelNum, .{ .name = "is_ipmi_channel_num", .linkage = .strong });
    @export(&isIpmiUserId, .{ .name = "is_ipmi_user_id", .linkage = .strong });
    @export(&isIpmiUserPrivLimit, .{ .name = "is_ipmi_user_priv_limit", .linkage = .strong });
    @export(&ipmiGetOemId, .{ .name = "ipmi_get_oem_id", .linkage = .strong });
    @export(&args2buf, .{ .name = "args2buf", .linkage = .strong });
}

// ---------------------------------------------------------------------------
// Tests
//
// The test binary built from `src/zig/root.zig` links no ipmitool C objects, so
// only the functions that stay inside libc are exercised here.  The rest -
// everything that calls `lprintf()` or reads `verbose` - is covered by the
// differential runs against the baseline oracle described in the pull request.
// ---------------------------------------------------------------------------

test "buf2long and buf2short are little endian" {
    const buf = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    try std.testing.expectEqual(@as(u32, 0x12345678), buf2long(&buf));
    try std.testing.expectEqual(@as(u16, 0x5678), buf2short(&buf));

    const high = [_]u8{ 0x00, 0x00, 0x00, 0xff };
    try std.testing.expectEqual(@as(u32, 0xff000000), buf2long(&high));
}

test "buf2str formats and separates" {
    const buf = [_]u8{ 0x00, 0x0f, 0xa5, 0xff };
    try std.testing.expectEqualStrings("000fa5ff", std.mem.span(buf2str(&buf, 4)));
    try std.testing.expectEqualStrings(
        "00 0f a5 ff",
        std.mem.span(buf2strExtended(&buf, 4, " ")),
    );
    try std.testing.expectEqualStrings("", std.mem.span(buf2str(&buf, 0)));
    try std.testing.expectEqualStrings("<NULL>", std.mem.span(buf2str(null, 4)));
    try std.testing.expectEqualStrings("00:0f:a5:ff:00:0f", std.mem.span(mac2str(&(buf ** 2))));
}

test "buf2str truncates instead of overflowing" {
    const buf = [_]u8{0xab} ** 2048;
    const out = std.mem.span(buf2str(&buf, buf.len));
    try std.testing.expectEqual(@as(usize, buf2str_max_output_size - 1), out.len);
    try std.testing.expect(std.mem.startsWith(u8, out, "abab"));

    // The separator is accounted for as well, so the buffer still fills up
    // exactly and stays null terminated.
    const sep = std.mem.span(buf2strExtended(&buf, buf.len, "::"));
    try std.testing.expectEqual(@as(usize, buf2str_max_output_size - 1), sep.len);
    try std.testing.expect(std.mem.startsWith(u8, sep, "ab::ab::"));
}

test "ipmi_parse_hex decodes and reports the C error codes" {
    var out = [_]u8{0} ** 8;

    try std.testing.expectEqual(@as(c_int, 8), ipmiParseHex("50415353574F5244", &out, out.len));
    try std.testing.expectEqualStrings("PASSWORD", &out);

    try std.testing.expectEqual(@as(c_int, 0), ipmiParseHex("", &out, out.len));
    try std.testing.expectEqual(@as(c_int, -1), ipmiParseHex("abc", &out, out.len));
    try std.testing.expectEqual(@as(c_int, -2), ipmiParseHex("abcd", null, 4));
    try std.testing.expectEqual(@as(c_int, -3), ipmiParseHex("zz", &out, out.len));

    // The full length is reported even when the output buffer is shorter.
    out = [_]u8{0} ** 8;
    try std.testing.expectEqual(@as(c_int, 4), ipmiParseHex("01020304", &out, 2));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 0, 0, 0, 0, 0, 0 }, &out);
}

test "array_byteswap reverses in place and tolerates an empty array" {
    var buf = [_]u8{ 1, 2, 3, 4, 5 };
    _ = arrayByteswap(&buf, buf.len);
    try std.testing.expectEqualSlices(u8, &.{ 5, 4, 3, 2, 1 }, &buf);

    var empty = [_]u8{};
    _ = arrayByteswap(&empty, 0);
}

test "array_letoh and array_ntoh follow the host byte order" {
    var le = [_]u8{ 1, 2, 3, 4 };
    _ = arrayLetoh(&le, le.len);
    var ne = [_]u8{ 1, 2, 3, 4 };
    _ = arrayNtoh(&ne, ne.len);

    switch (builtin.target.cpu.arch.endian()) {
        .little => {
            try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &le);
            try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1 }, &ne);
        },
        .big => {
            try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1 }, &le);
            try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &ne);
        },
    }
}

test "ipmi_csum is the two's complement of the sum" {
    const buf = [_]u8{ 0x20, 0x18, 0xc8 };
    try std.testing.expectEqual(@as(u8, 0x00), ipmiCsum(&buf, 3));
    try std.testing.expectEqual(@as(u8, 0xe0), ipmiCsum(&buf, 1));
    try std.testing.expectEqual(@as(u8, 0x00), ipmiCsum(&buf, 0));
    try std.testing.expectEqual(@as(u8, 0x00), ipmiCsum(&buf, -1));
}

test "val2str falls back to the Unknown form" {
    const table = [_]ValStr{
        .{ .val = 0x00, .str = "zero" },
        .{ .val = 0x2a, .str = "answer" },
        .{ .val = 0, .str = null },
    };

    try std.testing.expectEqualStrings("zero", std.mem.span(val2str(0, &table)));
    try std.testing.expectEqualStrings("answer", std.mem.span(val2str(0x2a, &table)));
    try std.testing.expectEqualStrings("Unknown (0x07)", std.mem.span(val2str(7, &table)));
    try std.testing.expectEqualStrings("Unknown (0xFF)", std.mem.span(val2str(0xff, &table)));
    try std.testing.expectEqualStrings("Unknown (0x123)", std.mem.span(val2str(0x123, &table)));
    try std.testing.expectEqualStrings("Unknown (0x2A)", std.mem.span(val2str(0x2a, null)));
}

test "specific_val2str prefers the specific table" {
    const specific = [_]ValStr{
        .{ .val = 1, .str = "specific" },
        .{ .val = 0, .str = null },
    };
    const generic = [_]ValStr{
        .{ .val = 1, .str = "generic" },
        .{ .val = 2, .str = "other" },
        .{ .val = 0, .str = null },
    };

    try std.testing.expectEqualStrings(
        "specific",
        std.mem.span(specificVal2str(1, &specific, &generic)),
    );
    try std.testing.expectEqualStrings(
        "other",
        std.mem.span(specificVal2str(2, &specific, &generic)),
    );
}

test "oemval2str matches the IANA number or PICMG" {
    const table = [_]OemValStr{
        .{ .oem = 42, .val = 1, .str = "sun" },
        .{ .oem = @intCast(c.IPMI_OEM_PICMG), .val = 2, .str = "picmg" },
        .{ .oem = 0xffffff, .val = 0, .str = null },
    };

    try std.testing.expectEqualStrings("sun", std.mem.span(oemval2str(42, 1, &table)));
    // The upstream FIXME: PICMG entries match every IANA number.
    try std.testing.expectEqualStrings("picmg", std.mem.span(oemval2str(42, 2, &table)));
    try std.testing.expectEqualStrings("Unknown (0x03)", std.mem.span(oemval2str(42, 3, &table)));
}

test "str2val32 is case insensitive and returns the terminator" {
    const table = [_]ValStr{
        .{ .val = 1, .str = "One" },
        .{ .val = 2, .str = "two" },
        .{ .val = 0xffff, .str = null },
    };

    try std.testing.expectEqual(@as(u32, 1), str2val32("ONE", &table));
    try std.testing.expectEqual(@as(u32, 2), str2val32("Two", &table));
    try std.testing.expectEqual(@as(u32, 0xffff), str2val32("three", &table));
    try std.testing.expectEqual(@as(u16, 0xffff), str2val("three", &table));
}

test "str2long accepts what strtol accepts" {
    var value: i64 = 0;

    try std.testing.expectEqual(@as(c_int, 0), str2long("42", &value));
    try std.testing.expectEqual(@as(i64, 42), value);
    try std.testing.expectEqual(@as(c_int, 0), str2long("0x2a", &value));
    try std.testing.expectEqual(@as(i64, 42), value);
    try std.testing.expectEqual(@as(c_int, 0), str2long("052", &value));
    try std.testing.expectEqual(@as(i64, 42), value);
    try std.testing.expectEqual(@as(c_int, 0), str2long("  -1", &value));
    try std.testing.expectEqual(@as(i64, -1), value);

    // An empty string parses as zero, as in C.
    try std.testing.expectEqual(@as(c_int, 0), str2long("", &value));
    try std.testing.expectEqual(@as(i64, 0), value);

    try std.testing.expectEqual(@as(c_int, -2), str2long("42x", &value));
    try std.testing.expectEqual(@as(c_int, -3), str2long("99999999999999999999", &value));
    try std.testing.expectEqual(@as(c_int, -1), str2long(null, &value));
    try std.testing.expectEqual(@as(c_int, -1), str2long("1", null));
}

test "str2ulong and str2double" {
    var uvalue: u64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), str2ulong("0xff", &uvalue));
    try std.testing.expectEqual(@as(u64, 255), uvalue);
    try std.testing.expectEqual(@as(c_int, -2), str2ulong("1 2", &uvalue));

    var dvalue: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), str2double("1.5", &dvalue));
    try std.testing.expectEqual(@as(f64, 1.5), dvalue);
    try std.testing.expectEqual(@as(c_int, -2), str2double("1.5v", &dvalue));
    try std.testing.expectEqual(@as(c_int, -1), str2double(null, &dvalue));
}

test "narrowing conversions range check" {
    var byte: u8 = 0xaa;
    try std.testing.expectEqual(@as(c_int, 0), str2uchar("255", &byte));
    try std.testing.expectEqual(@as(u8, 255), byte);
    try std.testing.expectEqual(@as(c_int, -3), str2uchar("256", &byte));
    // C leaves the value alone when only the range check fails.
    try std.testing.expectEqual(@as(u8, 255), byte);
    // ... and zeroes it when the parse itself failed.
    try std.testing.expectEqual(@as(c_int, -2), str2uchar("1z", &byte));
    try std.testing.expectEqual(@as(u8, 0), byte);

    var short: i16 = 0;
    try std.testing.expectEqual(@as(c_int, 0), str2short("-32768", &short));
    try std.testing.expectEqual(@as(i16, -32768), short);
    try std.testing.expectEqual(@as(c_int, -3), str2short("32768", &short));

    var chr: i8 = 0;
    try std.testing.expectEqual(@as(c_int, 0), str2char("-128", &chr));
    try std.testing.expectEqual(@as(i8, -128), chr);
    try std.testing.expectEqual(@as(c_int, -3), str2char("128", &chr));

    var word: u16 = 0;
    try std.testing.expectEqual(@as(c_int, 0), str2ushort("0xffff", &word));
    try std.testing.expectEqual(@as(u16, 0xffff), word);
    try std.testing.expectEqual(@as(c_int, -3), str2ushort("0x10000", &word));

    var dword: u32 = 0;
    try std.testing.expectEqual(@as(c_int, 0), str2uint("4294967295", &dword));
    try std.testing.expectEqual(@as(u32, 0xffffffff), dword);
    try std.testing.expectEqual(@as(c_int, -3), str2uint("4294967296", &dword));

    var int: i32 = 0;
    try std.testing.expectEqual(@as(c_int, 0), str2int("-2147483648", &int));
    try std.testing.expectEqual(@as(i32, -2147483648), int);
    try std.testing.expectEqual(@as(c_int, -3), str2int("2147483648", &int));
}

test "helper.h inline endian conversions" {
    var buf = [_]u8{0} ** 4;

    htoipmi16(0x1234, &buf);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0, 0 }, &buf);
    try std.testing.expectEqual(@as(u16, 0x1234), ipmi16toh(&buf));

    htoipmi24(0x123456, &buf);
    try std.testing.expectEqualSlices(u8, &.{ 0x56, 0x34, 0x12, 0 }, &buf);
    try std.testing.expectEqual(@as(u32, 0x123456), ipmi24toh(&buf));

    htoipmi32(0x12345678, &buf);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, &buf);
    try std.testing.expectEqual(@as(u32, 0x12345678), ipmi32toh(&buf));

    try std.testing.expect(isSet(@as(u8, 0b0100), 2));
    try std.testing.expect(!isSet(@as(u8, 0b0100), 1));
}
