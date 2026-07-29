//! Generator for `src/zig/util/strings_tables.zig`.
//!
//! `lib/ipmi_strings.c` is ~1400 lines of `struct valstr` / `struct oemvalstr`
//! literals.  Hand transcribing them would be slow and, worse, silently lossy:
//! a dropped entry or a swapped duplicate key changes what ipmitool prints
//! without changing anything that fails to compile.  So the tables are parsed
//! out of the C and re-emitted as Zig, and the result is committed as ordinary
//! reviewable source.  Nothing is generated at build time — when the last C
//! translation unit goes away this generator goes with it.
//!
//! Symbolic values (`IPMI_NETFN_CHASSIS`, `IPMI_OEM_KONTRON`, ...) are resolved
//! from the `zig translate-c` view of `src/zig/ipmi_c.h`, i.e. from the same C
//! frontend the build itself uses, and the emitted file re-checks every one of
//! them against `@import("ipmi_c")` in a `comptime` block, so a header change
//! that this generator's snapshot missed is a compile error rather than a
//! wrong string.
//!
//! Usage (the config header directory is where `build.zig` wrote `config.h`):
//!
//!     zig translate-c -I include -I <config-dir> -DHAVE_CONFIG_H=1 \
//!         '-DDEFAULT_INTF="lan"' -lc src/zig/ipmi_c.h > ipmi_c.zig
//!     zig run tools/gen_strings.zig -- \
//!         lib/ipmi_strings.c ipmi_c.zig src/zig/util/strings_tables.zig
//!     zig fmt src/zig/util/strings_tables.zig

const std = @import("std");

/// Which C array type a table was declared with.
const Kind = enum {
    /// `const struct valstr NAME[]`
    valstr,
    /// `const struct oemvalstr NAME[]`
    oemvalstr,
    /// `const char *NAME[]`
    strlist,
};

/// One `{ ... }` initialiser, or one string in a `const char *[]`.
const Entry = struct {
    fields: []const []const u8,
    trailing: ?[]const u8 = null,
};

const Item = union(enum) {
    entry: Entry,
    comment: []const u8,
    cond_if: []const u8,
    cond_end,
};

const Table = struct {
    name: []const u8,
    kind: Kind,
    is_static: bool,
    doc: []const []const u8,
    items: std.ArrayList(Item),
};

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;

pub fn main(init: std.process.Init) !void {
    gpa = init.arena.allocator();
    io = init.io;

    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 4) {
        fatal("usage: gen_strings <ipmi_strings.c> <translated ipmi_c.zig> <output.zig>", .{});
    }

    const source = try readFile(args[1]);
    const translated = try readFile(args[2]);

    var tables = try parse(source);
    const constants = try collectConstants(&tables, translated);

    var out: std.ArrayList(u8) = .empty;
    try emit(&out, tables.items, constants.items);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = out.items });

    var entries: usize = 0;
    for (tables.items) |table| {
        for (table.items.items) |item| {
            if (item == .entry) entries += 1;
        }
    }
    var stdout_buf: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print(
        "{s}: {d} tables, {d} entries, {d} resolved constants\n",
        .{ args[3], tables.items.len, entries, constants.items.len },
    );
    try stdout.interface.flush();
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    stderr.interface.print("gen_strings: " ++ fmt ++ "\n", args) catch {};
    stderr.interface.flush() catch {};
    std.process.exit(1);
}

fn readFile(path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 << 20)) catch |err| {
        fatal("cannot read {s}: {t}", .{ path, err });
    };
}

// ---------------------------------------------------------------------------
// Parsing the C
// ---------------------------------------------------------------------------

fn parse(source: []const u8) !std.ArrayList(Table) {
    var tables: std.ArrayList(Table) = .empty;

    var pending_doc: std.ArrayList([]const u8) = .empty;
    var in_block_comment = false;
    var current: ?*Table = null;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");

        if (in_block_comment) {
            const text = stripCommentBody(line);
            if (std.mem.indexOf(u8, line, "*/") != null) in_block_comment = false;
            if (current) |table| {
                if (text.len != 0) try table.items.append(gpa, .{ .comment = text });
            } else {
                if (text.len != 0 or pending_doc.items.len != 0) {
                    try pending_doc.append(gpa, text);
                }
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "/*")) {
            const closed = std.mem.indexOf(u8, line, "*/") != null;
            in_block_comment = !closed;
            const text = stripCommentBody(line);
            if (current) |table| {
                if (text.len != 0) try table.items.append(gpa, .{ .comment = text });
            } else {
                pending_doc = .empty;
                if (text.len != 0) try pending_doc.append(gpa, text);
            }
            continue;
        }

        if (current) |table| {
            if (std.mem.eql(u8, line, "};") or std.mem.eql(u8, line, "}")) {
                current = null;
                continue;
            }
            if (line.len == 0) continue;
            if (line[0] == '#') {
                try table.items.append(gpa, parseDirective(line));
                continue;
            }
            try parseEntries(table, line);
            continue;
        }

        if (parseHeader(line)) |header| {
            var doc = pending_doc;
            while (doc.items.len != 0 and doc.items[doc.items.len - 1].len == 0) {
                _ = doc.pop();
            }
            try tables.append(gpa, .{
                .name = header.name,
                .kind = header.kind,
                .is_static = header.is_static,
                .doc = try doc.toOwnedSlice(gpa),
                .items = .empty,
            });
            current = &tables.items[tables.items.len - 1];
            pending_doc = .empty;
            continue;
        }

        pending_doc = .empty;
    }

    if (current != null) fatal("unterminated table at end of file", .{});
    return tables;
}

/// Strips `/*`, `*/` and a leading ` * ` continuation marker from one line of a
/// C block comment.
fn stripCommentBody(line: []const u8) []const u8 {
    var text = line;
    if (std.mem.startsWith(u8, text, "/*")) text = text[2..];
    if (std.mem.indexOf(u8, text, "*/")) |end| text = text[0..end];
    text = std.mem.trim(u8, text, " \t\r");
    if (std.mem.startsWith(u8, text, "* ")) text = text[2..];
    if (std.mem.eql(u8, text, "*")) text = text[0..0];
    return std.mem.trim(u8, text, " \t\r");
}

fn parseDirective(line: []const u8) Item {
    if (std.mem.startsWith(u8, line, "#ifdef ")) {
        const rest = std.mem.trim(u8, line["#ifdef ".len..], " \t\r");
        return .{ .cond_if = rest };
    }
    if (std.mem.startsWith(u8, line, "#endif")) return .cond_end;
    fatal("unsupported preprocessor directive inside a table: {s}", .{line});
}

const Header = struct { name: []const u8, kind: Kind, is_static: bool };

fn parseHeader(line: []const u8) ?Header {
    var rest = line;
    var is_static = false;
    if (std.mem.startsWith(u8, rest, "static ")) {
        is_static = true;
        rest = rest["static ".len..];
    }
    const kind: Kind, const prefix: []const u8 = if (std.mem.startsWith(u8, rest, "const struct valstr "))
        .{ .valstr, "const struct valstr " }
    else if (std.mem.startsWith(u8, rest, "const struct oemvalstr "))
        .{ .oemvalstr, "const struct oemvalstr " }
    else if (std.mem.startsWith(u8, rest, "const char *"))
        .{ .strlist, "const char *" }
    else
        return null;

    rest = rest[prefix.len..];
    const bracket = std.mem.indexOf(u8, rest, "[]") orelse return null;
    if (std.mem.indexOf(u8, rest, "= {") == null) return null;
    return .{ .name = std.mem.trim(u8, rest[0..bracket], " \t"), .kind = kind, .is_static = is_static };
}

/// Splits one line of a table body into entries plus an optional trailing
/// comment.  Brace initialisers and bare `const char *` strings both end up
/// here; the C file keeps every initialiser on a single line.
fn parseEntries(table: *Table, line: []const u8) !void {
    var i: usize = 0;
    var last_entry: ?*Item = null;

    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == ',')) i += 1;
        if (i >= line.len) break;

        if (line[i] == '/' and i + 1 < line.len and line[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, line, i, "*/") orelse
                fatal("unterminated comment: {s}", .{line});
            const text = stripCommentBody(line[i .. end + 2]);
            if (last_entry) |item| {
                item.entry.trailing = text;
            } else if (text.len != 0) {
                try table.items.append(gpa, .{ .comment = text });
            }
            i = end + 2;
            continue;
        }

        if (line[i] == '{') {
            const end = matchBrace(line, i);
            const fields = try splitFields(line[i + 1 .. end]);
            try table.items.append(gpa, .{ .entry = .{ .fields = fields } });
            last_entry = &table.items.items[table.items.items.len - 1];
            i = end + 1;
            continue;
        }

        // A bare value: `const char *[]` tables list strings directly.
        const end = scanValue(line, i);
        const text = std.mem.trim(u8, line[i..end], " \t\r");
        if (text.len != 0) {
            const fields = try gpa.alloc([]const u8, 1);
            fields[0] = text;
            try table.items.append(gpa, .{ .entry = .{ .fields = fields } });
            last_entry = &table.items.items[table.items.items.len - 1];
        }
        i = end;
    }
}

fn matchBrace(line: []const u8, start: usize) usize {
    var depth: usize = 0;
    var i = start;
    var in_string = false;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (in_string) {
            if (ch == '\\') {
                i += 1;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        switch (ch) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    fatal("unbalanced braces: {s}", .{line});
}

/// Scans one comma separated value starting at `start`, stopping at the comma
/// or the start of a trailing comment.
fn scanValue(line: []const u8, start: usize) usize {
    var i = start;
    var in_string = false;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (in_string) {
            if (ch == '\\') {
                i += 1;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        if (ch == '"') {
            in_string = true;
            continue;
        }
        if (ch == ',') return i;
        if (ch == '/' and i + 1 < line.len and line[i + 1] == '*') return i;
    }
    return i;
}

fn splitFields(body: []const u8) ![]const []const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < body.len) {
        while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;
        if (i >= body.len) break;
        const end = scanValue(body, i);
        const text = std.mem.trim(u8, body[i..end], " \t\r");
        if (text.len != 0) try fields.append(gpa, text);
        i = if (end < body.len and body[end] == ',') end + 1 else end;
    }
    return fields.items;
}

// ---------------------------------------------------------------------------
// Resolving the symbolic values
// ---------------------------------------------------------------------------

const Constant = struct {
    /// The C spelling, e.g. `IPMI_NETFN_CHASSIS`.
    c_name: []const u8,
    /// The Zig spelling, e.g. `ipmi_netfn_chassis`.
    zig_name: []const u8,
    /// The literal `translate-c` produced for it, e.g. `0x0`.
    literal: []const u8,
};

fn collectConstants(tables: *std.ArrayList(Table), translated: []const u8) !std.ArrayList(Constant) {
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (tables.items) |table| {
        for (table.items.items) |item| {
            const entry = switch (item) {
                .entry => |e| e,
                else => continue,
            };
            const value_fields = entry.fields.len - 1;
            for (entry.fields[0..value_fields]) |field| {
                if (isNumeric(field)) continue;
                if (special(field) != null) continue;
                if (!isIdentifier(field)) fatal("unsupported value expression: {s}", .{field});
                try names.put(gpa, field, {});
            }
        }
    }

    var constants: std.ArrayList(Constant) = .empty;
    for (names.keys()) |name| {
        try constants.append(gpa, .{
            .c_name = name,
            .zig_name = try std.ascii.allocLowerString(gpa, name),
            .literal = lookupLiteral(translated, name) orelse
                fatal("{s} is not declared by the translated bridge header", .{name}),
        });
    }
    std.mem.sort(Constant, constants.items, {}, lessThanConstant);
    return constants;
}

fn lessThanConstant(_: void, a: Constant, b: Constant) bool {
    return std.mem.lessThan(u8, a.c_name, b.c_name);
}

/// Pulls the integer literal out of the two forms `zig translate-c` emits for
/// an object-like macro and for an enumerator:
///
///     pub const IPMI_NETFN_CHASSIS = @as(c_int, 0x0);
///     pub const IPMI_OEM_PICMG: c_int = 12634;
fn lookupLiteral(translated: []const u8, name: []const u8) ?[]const u8 {
    return lookupLiteralDepth(translated, name, 0);
}

fn lookupLiteralDepth(translated: []const u8, name: []const u8, depth: usize) ?[]const u8 {
    if (depth > 8) fatal("{s} does not resolve to a literal", .{name});
    var lines = std.mem.splitScalar(u8, translated, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "pub const ")) continue;
        var rest = line["pub const ".len..];
        if (!std.mem.startsWith(u8, rest, name)) continue;
        rest = rest[name.len..];
        if (std.mem.startsWith(u8, rest, ": ")) {
            const eq = std.mem.indexOf(u8, rest, "= ") orelse continue;
            rest = rest[eq + 2 ..];
        } else if (std.mem.startsWith(u8, rest, " = ")) {
            rest = rest[3..];
        } else {
            continue;
        }
        rest = std.mem.trimEnd(u8, rest, "; \t\r");
        if (std.mem.startsWith(u8, rest, "@as(c_int, ") and std.mem.endsWith(u8, rest, ")")) {
            rest = rest["@as(c_int, ".len .. rest.len - 1];
        } else if (std.mem.startsWith(u8, rest, "@as(c_uint, ") and std.mem.endsWith(u8, rest, ")")) {
            rest = rest["@as(c_uint, ".len .. rest.len - 1];
        }
        rest = std.mem.trim(u8, rest, " \t\r");
        // `#define A B` where B is another macro; follow the alias.
        if (isIdentifier(rest)) return lookupLiteralDepth(translated, rest, depth + 1);
        if (!isNumeric(rest)) return null;
        return rest;
    }
    return null;
}

/// Values that are clearer as their Zig equivalent than as a copied constant.
fn special(field: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, field, "UINT8_MAX")) return "std.math.maxInt(u8)";
    if (std.mem.eql(u8, field, "UINT16_MAX")) return "std.math.maxInt(u16)";
    if (std.mem.eql(u8, field, "UINT32_MAX")) return "std.math.maxInt(u32)";
    return null;
}

fn isNumeric(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        for (text[2..]) |ch| {
            if (!std.ascii.isHex(ch)) return false;
        }
        return text.len > 2;
    }
    for (text) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    // Zig rejects a leading zero on a decimal literal.
    return text.len == 1 or text[0] != '0';
}

fn isIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!std.ascii.isAlphabetic(text[0]) and text[0] != '_') return false;
    for (text) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Emitting the Zig
// ---------------------------------------------------------------------------

const preamble =
    \\//! Lookup tables ported from `lib/ipmi_strings.c`.
    \\//!
    \\//! Generated by `tools/gen_strings.zig`; edit that and regenerate rather than
    \\//! editing this file.  The imperative half of `lib/ipmi_strings.c` — the IANA
    \\//! PEN registry loader behind `ipmi_oem_info` — is hand written in
    \\//! `strings.zig`, which is also where these tables are wired into the module.
    \\//!
    \\//! Every table keeps the C entry order, including duplicate keys: `val2str`
    \\//! returns the first match, so reordering a table silently changes output.
    \\//! The `comptime` block at the end re-exports them under their C names.
    \\
    \\const std = @import("std");
    \\
    \\const c = @import("ipmi_c");
    \\const helper = @import("helper.zig");
    \\
    \\const ValStr = helper.ValStr;
    \\const OemValStr = helper.OemValStr;
    \\
;

const epilogue_helpers =
    \\
    \\/// Fails the build when `<ipmitool/ipmi_strings.h>` declares an exported table
    \\/// with a different element type than the one this module defines it with.
    \\/// This is the data-symbol counterpart of `abi.assertCallSignature`.
    \\fn assertTableType(comptime Elem: type, comptime CTable: type) void {
    \\    const info = @typeInfo(CTable);
    \\    if (info != .pointer) @compileError("expected a C array-to-pointer decay");
    \\    const CElem = info.pointer.child;
    \\    if (@sizeOf(Elem) != @sizeOf(CElem) or @alignOf(Elem) != @alignOf(CElem)) {
    \\        @compileError("element layout differs from " ++ @typeName(CElem));
    \\    }
    \\}
    \\
    \\/// Fails the build when a value copied out of a C header no longer matches it.
    \\fn assertConst(comptime mine: comptime_int, comptime theirs: anytype) void {
    \\    if (mine != theirs) @compileError("constant drifted from the C header");
    \\}
    \\
;

fn emit(out: *std.ArrayList(u8), tables: []const Table, constants: []const Constant) !void {
    try out.appendSlice(gpa, preamble);

    try out.appendSlice(gpa,
        \\
        \\/// `HAVE_CRYPTO_SHA256` in `config.h`: libcrypto's SHA256 support decides
        \\/// whether the RAKP and integrity tables carry their SHA256 entries.
        \\const have_crypto_sha256 = @hasDecl(c, "HAVE_CRYPTO_SHA256");
        \\
        \\// -- values the tables are written in terms of -------------------------------
        \\//
        \\// Copied from the C headers by the generator and re-checked against the
        \\// `ipmi_c` bridge in the `comptime` block at the bottom of the file.
        \\
        \\
    );
    for (constants) |constant| {
        try out.print(gpa, "/// `{s}`.\nconst {s} = {s};\n", .{
            constant.c_name,
            constant.zig_name,
            constant.literal,
        });
    }

    for (tables) |table| {
        try out.append(gpa, '\n');
        if (table.doc.len == 0) {
            try out.print(gpa, "/// `{s}` in `lib/ipmi_strings.c`.\n", .{table.name});
        } else {
            for (table.doc) |line| {
                if (line.len == 0) {
                    try out.appendSlice(gpa, "///\n");
                } else {
                    try out.print(gpa, "/// {s}\n", .{line});
                }
            }
        }
        try emitTable(out, &table);
    }

    try out.appendSlice(gpa, epilogue_helpers);

    try out.appendSlice(gpa, "\ncomptime {\n");
    for (tables) |table| {
        if (table.is_static) continue;
        try out.print(
            gpa,
            "    assertTableType({s}, @TypeOf(c.{s}));\n",
            .{ elemType(table.kind), table.name },
        );
    }
    try out.append(gpa, '\n');
    for (constants) |constant| {
        try out.print(gpa, "    assertConst({s}, c.{s});\n", .{ constant.zig_name, constant.c_name });
    }
    try out.append(gpa, '\n');
    for (tables) |table| {
        if (table.is_static) continue;
        try out.print(
            gpa,
            "    @export(&{s}, .{{ .name = \"{s}\", .linkage = .strong }});\n",
            .{ table.name, table.name },
        );
    }
    try out.appendSlice(gpa, "}\n");
}

fn elemType(kind: Kind) []const u8 {
    return switch (kind) {
        .valstr => "ValStr",
        .oemvalstr => "OemValStr",
        .strlist => "?[*:0]const u8",
    };
}

fn emitTable(out: *std.ArrayList(u8), table: *const Table) !void {
    const elem = elemType(table.kind);
    const items = table.items.items;

    // A `#ifdef` inside a table splits it into chunks that are concatenated at
    // comptime, so an unselected chunk contributes no entries at all.
    var conditional = false;
    for (items) |item| {
        if (item == .cond_if) conditional = true;
    }

    if (!conditional) {
        try out.print(gpa, "pub const {s} = [_]{s}{{\n", .{ table.name, elem });
        try emitItems(out, table.kind, items, "    ");
        try out.appendSlice(gpa, "};\n");
        return;
    }

    try out.print(gpa, "pub const {s} =\n", .{table.name});
    var start: usize = 0;
    var cond: ?[]const u8 = null;
    var first = true;
    for (items, 0..) |item, i| {
        switch (item) {
            .cond_if => |macro| {
                try emitChunk(out, table.kind, elem, items[start..i], cond, first);
                first = false;
                start = i + 1;
                cond = macro;
            },
            .cond_end => {
                try emitChunk(out, table.kind, elem, items[start..i], cond, first);
                first = false;
                start = i + 1;
                cond = null;
            },
            else => {},
        }
    }
    try emitChunk(out, table.kind, elem, items[start..], cond, first);
    try out.appendSlice(gpa, ";\n");
}

fn emitChunk(
    out: *std.ArrayList(u8),
    kind: Kind,
    elem: []const u8,
    items: []const Item,
    cond: ?[]const u8,
    first: bool,
) !void {
    if (items.len == 0) return;
    if (!first) try out.appendSlice(gpa, " ++\n");
    if (cond) |macro| {
        try out.print(gpa, "    (if ({s}) [_]{s}{{\n", .{ zigCond(macro), elem });
        try emitItems(out, kind, items, "        ");
        try out.print(gpa, "    }} else [_]{s}{{}})", .{elem});
        return;
    }
    try out.print(gpa, "    [_]{s}{{\n", .{elem});
    try emitItems(out, kind, items, "        ");
    try out.appendSlice(gpa, "    }");
}

fn zigCond(macro: []const u8) []const u8 {
    if (std.mem.eql(u8, macro, "HAVE_CRYPTO_SHA256")) return "have_crypto_sha256";
    fatal("no Zig spelling for #ifdef {s}", .{macro});
}

fn emitItems(out: *std.ArrayList(u8), kind: Kind, items: []const Item, indent: []const u8) !void {
    for (items) |item| {
        switch (item) {
            .comment => |text| try out.print(gpa, "{s}// {s}\n", .{ indent, text }),
            .cond_if, .cond_end => {},
            .entry => |entry| {
                try out.appendSlice(gpa, indent);
                try emitEntry(out, kind, entry);
                if (entry.trailing) |text| {
                    try out.print(gpa, " // {s}", .{text});
                }
                try out.append(gpa, '\n');
            },
        }
    }
}

fn emitEntry(out: *std.ArrayList(u8), kind: Kind, entry: Entry) !void {
    switch (kind) {
        .valstr => {
            if (entry.fields.len != 2) fatal("valstr entry with {d} fields", .{entry.fields.len});
            try out.print(gpa, ".{{ .val = {s}, .str = {s} }},", .{
                renderValue(entry.fields[0]),
                renderString(entry.fields[1]),
            });
        },
        .oemvalstr => {
            if (entry.fields.len != 3) fatal("oemvalstr entry with {d} fields", .{entry.fields.len});
            try out.print(gpa, ".{{ .oem = {s}, .val = {s}, .str = {s} }},", .{
                renderValue(entry.fields[0]),
                renderValue(entry.fields[1]),
                renderString(entry.fields[2]),
            });
        },
        .strlist => {
            if (entry.fields.len != 1) fatal("strlist entry with {d} fields", .{entry.fields.len});
            try out.print(gpa, "{s},", .{renderString(entry.fields[0])});
        },
    }
}

fn renderValue(field: []const u8) []const u8 {
    if (isNumeric(field)) return field;
    if (special(field)) |text| return text;
    if (isIdentifier(field)) return std.ascii.allocLowerString(gpa, field) catch @panic("OOM");
    fatal("unsupported value expression: {s}", .{field});
}

fn renderString(field: []const u8) []const u8 {
    if (std.mem.eql(u8, field, "NULL")) return "null";
    if (field.len < 2 or field[0] != '"' or field[field.len - 1] != '"') {
        fatal("unsupported string expression: {s}", .{field});
    }
    if (std.mem.indexOfScalar(u8, field, '\\') != null) {
        fatal("escape sequences need review before they can be copied: {s}", .{field});
    }
    return field;
}
