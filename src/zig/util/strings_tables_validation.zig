//! Static-table checks against a frozen, independently compiled C baseline.
//!
//! No C bridge, headers, compiler or current C tables are needed by consumers.
//! See `tools/gen_strings_baseline.sh` for the optional historical oracle.

const std = @import("std");
const tables = @import("strings_tables.zig");
const types = @import("table_types.zig");

const ValStr = types.ValStr;
const OemValStr = types.OemValStr;
const Str = ?[*:0]const u8;

pub const baseline_revision = "207aa0ddeec2a7192a2edd9559c1bf4bd19a6f21";
pub const fixture_without_sha256 = @embedFile("testdata/strings-c-sha256-0.txt");
pub const fixture_with_sha256 = @embedFile("testdata/strings-c-sha256-1.txt");
pub const fixture_checksums = @embedFile("testdata/strings-c.SHA256SUMS");

pub const Lines = std.mem.SplitIterator(u8, .scalar);

fn field(fields: *Lines) ![]const u8 {
    return fields.next() orelse error.InvalidFixture;
}

fn number(comptime T: type, text: []const u8) !T {
    return std.fmt.parseInt(T, text, 0) catch error.InvalidFixture;
}

fn endFields(fields: *Lines) !void {
    if (fields.next() != null) return error.InvalidFixture;
}

fn checkText(actual: Str, fields: *Lines) !void {
    const length = try field(fields);
    if (std.mem.eql(u8, length, "null")) {
        if (actual != null) return error.NullValue;
    } else {
        const text = std.mem.span(actual orelse return error.NullValue);
        const bytes = try number(usize, length);
        const hex = try field(fields);
        if (text.len != bytes or hex.len / 2 != bytes or hex.len % 2 != 0)
            return error.TextValue;
        for (text, 0..) |byte, i| {
            const expected = std.fmt.parseInt(u8, hex[2 * i ..][0..2], 16) catch
                return error.InvalidFixture;
            if (byte != expected) return error.TextValue;
        }
    }
    try endFields(fields);
}

/// The same comparison used by the comptime gate, exposed for mutation tests.
/// Array bounds, not a sentinel walk, determine how many rows are checked.
pub fn checkTable(comptime Elem: type, actual: []const Elem, count: usize, lines: *Lines) !void {
    if (actual.len != count) return error.EntryCount;
    if (count == 0) return error.Sentinel;
    for (actual, 0..) |entry, i| {
        var fields = std.mem.splitScalar(u8, try field(lines), '|');
        if (try number(usize, try field(&fields)) != i) return error.EntryIndex;
        if (Elem == ValStr) {
            if (entry.val != try number(u32, try field(&fields))) return error.NumericValue;
        } else if (Elem == OemValStr) {
            if (entry.oem != try number(u32, try field(&fields))) return error.NumericValue;
            if (entry.val != try number(u16, try field(&fields))) return error.NumericValue;
        } else if (Elem != Str) {
            @compileError("unexpected static table element type");
        }
        const text = if (Elem == Str) entry else entry.str;
        try checkText(text, &fields);
        if ((i == count - 1) != (text == null)) return error.Sentinel;
        if (Elem == OemValStr and i == count - 1 and entry.oem != 0xffffff)
            return error.Sentinel;
    }
}

fn kind(comptime Elem: type) []const u8 {
    if (Elem == ValStr) return "valstr";
    if (Elem == OemValStr) return "oemvalstr";
    if (Elem == Str) return "strlist";
    @compileError("unexpected static table element type");
}

fn assertSnapshot(comptime snapshot: []const u8) void {
    comptime {
        var lines = std.mem.splitScalar(u8, snapshot, '\n');
        const header = "strings-c-baseline-v1|" ++ baseline_revision ++
            (if (tables.have_crypto_sha256) "|sha256=1" else "|sha256=0");
        if (!std.mem.eql(u8, lines.next().?, header))
            @compileError("static string baseline provenance/feature mismatch");
        var constants: usize = 0;
        var arrays: usize = 0;
        var entries: usize = 0;
        var seen: []const u8 = "|";
        while (lines.next()) |line| {
            if (line.len == 0) {
                if (lines.next() != null) @compileError("unexpected empty baseline line");
                break;
            }
            var fields = std.mem.splitScalar(u8, line, '|');
            const tag = field(&fields) catch @compileError("invalid baseline tag");
            const name = field(&fields) catch @compileError("invalid baseline name");
            if (!@hasDecl(tables, name)) @compileError("missing static table/constant: " ++ name);
            const key = "|" ++ name ++ "|";
            if (std.mem.indexOf(u8, seen, key) != null)
                @compileError("duplicate static baseline declaration: " ++ name);
            seen = seen ++ name ++ "|";
            const actual = @field(tables, name);
            if (std.mem.eql(u8, tag, "constant")) {
                if (@TypeOf(actual) != comptime_int) @compileError("unexpected constant type: " ++ name);
                const expected = number(u32, field(&fields) catch @compileError("missing baseline value")) catch
                    @compileError("invalid baseline value");
                if (actual != expected) @compileError("static constant drifted from frozen C baseline: " ++ name);
                constants += 1;
            } else if (std.mem.eql(u8, tag, "table")) {
                const info = @typeInfo(@TypeOf(actual));
                if (info != .array) @compileError("static table is not an array: " ++ name);
                const expected_kind = field(&fields) catch @compileError("missing baseline table kind");
                if (!std.mem.eql(u8, kind(info.array.child), expected_kind))
                    @compileError("static table element type drifted: " ++ name);
                const count = number(usize, field(&fields) catch @compileError("missing baseline count")) catch
                    @compileError("invalid baseline count");
                checkTable(info.array.child, &actual, count, &lines) catch |err|
                    @compileError("static table drifted from frozen C baseline: " ++ name ++ " (" ++ @errorName(err) ++ ")");
                arrays += 1;
                entries += count;
            } else @compileError("unknown baseline record kind");
            endFields(&fields) catch @compileError("unexpected baseline fields");
        }
        for (@typeInfo(tables).@"struct".decls) |decl| {
            if (std.mem.eql(u8, decl.name, "have_crypto_sha256")) continue;
            if (std.mem.indexOf(u8, seen, "|" ++ decl.name ++ "|") == null)
                @compileError("static declaration missing from frozen baseline: " ++ decl.name);
        }
        if (constants != 72 or arrays != 34 or entries != (if (tables.have_crypto_sha256) 1276 else 1274))
            @compileError("incomplete frozen static string baseline");
    }
}

comptime {
    @setEvalBranchQuota(2_000_000);
    if (tables.have_crypto_sha256 != @import("build_options").have_crypto_sha256)
        @compileError("SHA256 table feature drifted from build options");

    // Fixed-width C-origin layouts remain checked even after C header deletion.
    const pointer_alignment = @alignOf(Str);
    const valstr_pointer_offset = std.mem.alignForward(usize, 4, pointer_alignment);
    const oemvalstr_pointer_offset = std.mem.alignForward(usize, 6, pointer_alignment);
    if (@TypeOf(@as(ValStr, undefined).val) != u32 or @TypeOf(@as(ValStr, undefined).str) != Str or
        @TypeOf(@as(OemValStr, undefined).oem) != u32 or @TypeOf(@as(OemValStr, undefined).val) != u16 or
        @TypeOf(@as(OemValStr, undefined).str) != Str or
        @typeInfo(ValStr).@"struct".layout != .@"extern" or
        @offsetOf(ValStr, "val") != 0 or @offsetOf(ValStr, "str") != valstr_pointer_offset or
        @sizeOf(ValStr) != valstr_pointer_offset + @sizeOf(Str) or @alignOf(ValStr) != pointer_alignment or
        @typeInfo(OemValStr).@"struct".layout != .@"extern" or
        @offsetOf(OemValStr, "oem") != 0 or @offsetOf(OemValStr, "val") != 4 or
        @offsetOf(OemValStr, "str") != oemvalstr_pointer_offset or
        @sizeOf(OemValStr) != oemvalstr_pointer_offset + @sizeOf(Str) or @alignOf(OemValStr) != pointer_alignment)
        @compileError("static lookup entry layout drifted from the C-origin ABI");

    assertSnapshot(if (tables.have_crypto_sha256) fixture_with_sha256 else fixture_without_sha256);
}
