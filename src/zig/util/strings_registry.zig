//! Dynamic half of the port of `lib/ipmi_strings.c`: `ipmi_oem_info` and the
//! IANA private enterprise number registry it is built from.
//!
//! The static tables are in `strings.zig` / `strings_tables.zig`; this file is
//! separate because it calls back into `lib/log.c`, which the ABI test binary
//! deliberately does not link.  Both halves are pulled in together by
//! `exports.zig` under `-Dzig-modules=strings`.
//!
//! The layout of the array `ipmi_oem_info` points at is part of the contract
//! with `ipmi_oem_info_free`, and it is the same as the C's:
//!
//!     [ head entries | registry entries, in file order | tail | terminator ]
//!
//! The head entries shadow whatever IANA registered for 0 and 0x0FFFFF, the
//! tail entry must not shadow a real IANA assignment, and everything between
//! them is `malloc`ed and owned by the array.

const std = @import("std");

const c = @import("ipmi_c");
const helper = @import("helper.zig");
const log = @import("log.zig");
const strings = @import("strings.zig");

const tables = strings.tables;
const ValStr = helper.ValStr;

/// `IANA_NAME_OFFSET`: the registry indents the organisation name by exactly
/// two spaces below its enterprise number.
const name_offset = 2;

/// `IANA_PEN_REGISTRY`.
const registry_file = "enterprise-numbers";

/// `LOG_DEBUG + 4` in `oem_info_init_from_list`: six `-v` options.
const oemlist_debug: c_int = log.Level.debug + 4;

/// Allocator for the temporary entry list.  The registry strings and the array
/// `ipmi_oem_info` points at are `malloc`ed directly instead, because
/// `ipmi_oem_info_free` hands them to `free()`.
const allocator = std.heap.c_allocator;

/// `ipmi_oem_info`: an array filled from IANA's enterprise number registry,
/// or `ipmi_oem_info_dummy` when it could not be allocated.
var oem_info: ?[*]const ValStr = null;

/// Pointer identity is what `ipmi_oem_info_free` uses to recognise the fallback.
const dummy: [*]const ValStr = &tables.ipmi_oem_info_dummy;

// ---------------------------------------------------------------------------
// Reading the registry
// ---------------------------------------------------------------------------

/// `oem_info_list_load`, minus the linked list: entries are collected in file
/// order because that is the order they end up in the final array.
///
/// Returns the number of entries read, or -1 when the registry cannot be
/// opened.
fn loadRegistry(entries: *std.ArrayList(ValStr)) c_int {
    const file = openRegistry() orelse {
        c.lperror(log.Level.err, "IANA PEN registry open failed");
        return -1;
    };
    defer _ = std.c.fclose(file);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    readAll(file, &text);

    var lines: Lines = .{ .text = text.items };
    while (lines.next()) |number_line| {
        // A registry entry starts with the enterprise number at column 0.  The
        // C runs strtol as well, but `isdigit(line[0])` already decides it.
        const iana = leadingNumber(number_line) orelse continue;

        // The organisation name has to follow immediately.  A line that does
        // not qualify is still consumed, exactly as the second getline does.
        const name_line = lines.next() orelse continue;
        if (leadingSpaces(name_line) != name_offset) continue;

        var name = name_line[name_offset..];
        if (name.len != 0 and name[name.len - 1] == '\n') name = name[0 .. name.len - 1];

        const copy = dupeZ(name) orelse {
            c.lperror(log.Level.err, "IANA PEN registry string allocation failed");
            break;
        };
        entries.append(allocator, .{ .val = iana, .str = copy }) catch {
            c.lperror(log.Level.err, "IANA PEN registry entry allocation failed");
            freeStr(copy);
            break;
        };
    }

    return std.math.cast(c_int, entries.items.len) orelse std.math.maxInt(c_int);
}

/// The per-user registry under `$HOME` wins over the system one, and a missing
/// `$HOME` just skips it.  `fopen` is used rather than a Zig file API so that
/// `lperror`'s `strerror(errno)` says the same thing it did in C.
fn openRegistry() ?*std.c.FILE {
    if (std.c.getenv("HOME")) |home| {
        var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path = joinTruncating(buf[0..std.fs.max_path_bytes], &.{
            std.mem.span(@as([*:0]const u8, home)),
            c.PATH_SEPARATOR ++ c.IANAUSERDIR ++ c.PATH_SEPARATOR ++ registry_file,
        });
        if (std.c.fopen(path, "r")) |file| return file;
    }
    return std.c.fopen(c.IANADIR ++ c.PATH_SEPARATOR ++ registry_file, "r");
}

/// `snprintf(buf, buf.len, "%s%s", ...)`: concatenate, truncate, NUL terminate.
fn joinTruncating(buf: []u8, parts: []const []const u8) [:0]const u8 {
    var len: usize = 0;
    for (parts) |part| {
        const room = buf.len - 1 - len;
        const take = @min(room, part.len);
        @memcpy(buf[len..][0..take], part[0..take]);
        len += take;
        if (take < part.len) break;
    }
    buf[len] = 0;
    return buf[0..len :0];
}

fn readAll(file: *std.c.FILE, out: *std.ArrayList(u8)) void {
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const read = std.c.fread(&chunk, 1, chunk.len, file);
        if (read == 0) return;
        out.appendSlice(allocator, chunk[0..read]) catch return;
    }
}

/// Iterates lines the way `getline` does: the newline stays on the line, and a
/// file that does not end in one still yields its last line.
const Lines = struct {
    text: []const u8,
    pos: usize = 0,

    fn next(it: *Lines) ?[]const u8 {
        if (it.pos >= it.text.len) return null;
        const start = it.pos;
        const end = if (std.mem.indexOfScalarPos(u8, it.text, start, '\n')) |nl|
            nl + 1
        else
            it.text.len;
        it.pos = end;
        return it.text[start..end];
    }
};

/// `isdigit(line[0])` followed by `strtol(line, &endptr, 10)`, truncated into
/// the `uint32_t` the C assigns it to.
fn leadingNumber(line: []const u8) ?u32 {
    if (line.len == 0 or !std.ascii.isDigit(line[0])) return null;

    var value: c_long = 0;
    var saturated = false;
    for (line) |ch| {
        if (!std.ascii.isDigit(ch)) break;
        if (saturated) continue;
        const digit: c_long = ch - '0';
        value = std.math.mul(c_long, value, 10) catch {
            saturated = true;
            continue;
        };
        value = std.math.add(c_long, value, digit) catch {
            saturated = true;
            continue;
        };
    }
    // strtol saturates at LONG_MAX on overflow.
    if (saturated) value = std.math.maxInt(c_long);
    return @truncate(@as(c_ulong, @bitCast(value)));
}

/// `count_bytes(line, ' ')`.
fn leadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') count += 1;
    return count;
}

fn dupeZ(text: []const u8) ?[*:0]const u8 {
    const raw = std.c.malloc(text.len + 1) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @memcpy(bytes[0..text.len], text);
    bytes[text.len] = 0;
    return @ptrCast(bytes);
}

// ---------------------------------------------------------------------------
// Building the array
// ---------------------------------------------------------------------------

/// `oem_info_init_from_list`.  Returns false when the array could not be
/// allocated, in which case the caller still owns the registry strings.
fn install(entries: []const ValStr) bool {
    // The terminators of the static arrays are not copied.
    const head_entries = tables.ipmi_oem_info_head.len - 1;
    const tail_entries = tables.ipmi_oem_info_tail.len - 1;
    const total = entries.len + head_entries + tail_entries + 1;

    const raw = std.c.malloc(total * @sizeOf(ValStr)) orelse {
        c.lperror(log.Level.err, "IANA PEN registry array allocation failed");
        oem_info = dummy;
        return false;
    };
    const array: [*]ValStr = @ptrCast(@alignCast(raw));
    oem_info = array;

    c.lprintf(oemlist_debug, "  Allocating %6zu entries", total);

    // Filled back to front, and logged in that order, so that six -v options
    // produce the same transcript the C did.
    var slot = total - 1;
    array[slot] = .{ .val = std.math.maxInt(u32), .str = null };

    var tail = tail_entries;
    while (tail > 0) {
        tail -= 1;
        slot -= 1;
        array[slot] = tables.ipmi_oem_info_tail[tail];
        logEntry(slot, array[slot]);
    }

    var loaded = entries.len;
    while (loaded > 0) {
        loaded -= 1;
        slot -= 1;
        array[slot] = entries[loaded];
        logEntry(slot, array[slot]);
    }

    var head = head_entries;
    while (head > 0) {
        head -= 1;
        slot -= 1;
        array[slot] = tables.ipmi_oem_info_head[head];
        logEntry(slot, array[slot]);
    }

    return true;
}

fn logEntry(slot: usize, entry: ValStr) void {
    c.lprintf(
        oemlist_debug,
        "  [%6zu] %8d | %s",
        slot,
        @as(c_int, @bitCast(entry.val)),
        entry.str,
    );
}

// ---------------------------------------------------------------------------
// C ABI surface
// ---------------------------------------------------------------------------

/// `ipmi_oem_info_init`.
fn init() callconv(.c) void {
    c.lprintf(log.Level.info, "Loading IANA PEN Registry...");

    if (oem_info != null) {
        c.lprintf(log.Level.info, "IANA PEN Registry is already loaded");
        return;
    }

    var entries: std.ArrayList(ValStr) = .empty;
    defer entries.deinit(allocator);

    if (loadRegistry(&entries) < 1) {
        c.lprintf(log.Level.warn, "Failed to load entries from IANA PEN Registry");
    }

    // On success the array owns the strings; on failure nothing else will.
    if (!install(entries.items)) {
        for (entries.items) |entry| freeStr(entry.str);
    }
}

/// `ipmi_oem_info_free`.
fn deinit() callconv(.c) void {
    const info = oem_info orelse return;
    if (info == dummy) return;

    // Everything from the end of the head entries up to the statically
    // allocated tail was allocated by `loadRegistry`.
    var i = tables.ipmi_oem_info_head.len - 1;
    while (info[i].val < std.math.maxInt(u32) and
        info[i].str != tables.ipmi_oem_info_tail[0].str) : (i += 1)
    {
        const slot = &@as([*]ValStr, @constCast(info))[i];
        freeStr(slot.str);
        slot.str = null;
    }

    std.c.free(@constCast(@as(*const anyopaque, @ptrCast(info))));
    oem_info = null;
}

fn freeStr(str: ?[*:0]const u8) void {
    const text = str orelse return;
    std.c.free(@constCast(@as(*const anyopaque, @ptrCast(text))));
}

/// `assertCallSignature` for a function the C declares without a prototype.
///
/// `ipmi_strings.h` spells these two `void ipmi_oem_info_init();`, which
/// `translate-c` faithfully models as C-variadic.  A zero argument Zig function
/// is still the right definition — that is what every caller compiles to — so
/// check the parts that are meaningful instead.
fn assertUnprototyped(comptime Ported: type, comptime Original: type) void {
    comptime {
        const ported = @typeInfo(Ported).@"fn";
        const original = @typeInfo(Original).@"fn";
        const Tag = std.builtin.CallingConvention.Tag;

        if (@as(Tag, ported.calling_convention) != @as(Tag, original.calling_convention)) {
            @compileError("ABI drift: calling convention mismatch for " ++ @typeName(Ported));
        }
        if (!original.is_var_args or original.params.len != 0) {
            @compileError(@typeName(Original) ++ " grew a prototype; use assertCallSignature");
        }
        if (ported.params.len != 0) {
            @compileError("ABI drift: " ++ @typeName(Ported) ++ " must take no arguments");
        }
        if (ported.return_type.? != void or original.return_type.? != void) {
            @compileError("ABI drift: return type mismatch for " ++ @typeName(Ported));
        }
    }
}

comptime {
    assertUnprototyped(@TypeOf(init), @TypeOf(c.ipmi_oem_info_init));
    assertUnprototyped(@TypeOf(deinit), @TypeOf(c.ipmi_oem_info_free));

    // `ipmi_oem_info` is a plain `const struct valstr *`; the bridge's own
    // declaration is the reference for its representation.
    if (@sizeOf(@TypeOf(oem_info)) != @sizeOf(@TypeOf(c.ipmi_oem_info))) {
        @compileError("ABI drift: ipmi_oem_info is not pointer sized");
    }

    @export(&oem_info, .{ .name = "ipmi_oem_info", .linkage = .strong });
    @export(&init, .{ .name = "ipmi_oem_info_init", .linkage = .strong });
    @export(&deinit, .{ .name = "ipmi_oem_info_free", .linkage = .strong });
}
