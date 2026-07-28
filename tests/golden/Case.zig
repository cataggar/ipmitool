//! Declarative golden test cases.
//!
//! Cases live in `tests/cases/*.cases`. One file holds many cases so that the
//! suite stays reviewable; each case starts with a `[name]` header:
//!
//!     [mc_info]
//!     desc: mc info against a recorded Get Device ID response
//!     args: -I dummy mc info
//!     transcript: mc_info.tr
//!     covers: mc
//!
//! Recognised keys:
//!
//!     desc:        free text, not part of the snapshot
//!     args:        argv passed after the binary path (double quotes supported)
//!     transcript:  file in tests/transcripts (default: default.tr)
//!     covers:      space separated top-level commands this case exercises
//!     env:         NAME=VALUE, repeatable, added to the fixed environment
//!     blob:        <dest> <fixture.hex>, writes a hex fixture into the work dir
//!     text:        <dest> <fixture.txt>, copies a text fixture into the work dir
//!     registry:    default | none  (IANA PEN registry visible to the binary)
//!     timeout_ms:  per-case wall clock budget (default 10000)
//!
//! `{work}` anywhere in `args` expands to the case's work directory, which is
//! also scrubbed back out of the captured output.

const std = @import("std");
const Io = std.Io;

const Case = @This();

pub const Registry = enum { default, none };

name: []const u8,
desc: []const u8 = "",
args: []const []const u8 = &.{},
transcript: []const u8 = "default.tr",
covers: []const []const u8 = &.{},
env: []const Env = &.{},
blobs: []const Blob = &.{},
registry: Registry = .default,
timeout_ms: u32 = 10_000,
source: []const u8 = "",

pub const Env = struct { name: []const u8, value: []const u8 };
pub const Blob = struct { dest: []const u8, fixture: []const u8, kind: enum { hex, text } };

pub const Error = error{BadCaseFile} || std.mem.Allocator.Error;

pub const LoadResult = struct {
    cases: []Case,
};

/// Parse every `*.cases` file in `dir`, sorted by file name then by order of
/// appearance, so the suite runs deterministically.
pub fn loadAll(
    gpa: std.mem.Allocator,
    io: Io,
    dir_path: []const u8,
    diag: *std.ArrayList(u8),
) Error![]Case {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);

    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        try diag.print(gpa, "cannot open case directory '{s}'", .{dir_path});
        return error.BadCaseFile;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".cases")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    var cases: std.ArrayList(Case) = .empty;
    for (names.items) |name| {
        const path = try std.fs.path.join(gpa, &.{ dir_path, name });
        const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch {
            try diag.print(gpa, "cannot read case file '{s}'", .{path});
            return error.BadCaseFile;
        };
        defer gpa.free(text);
        try parseInto(gpa, path, text, &cases, diag);
    }
    return cases.toOwnedSlice(gpa);
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn parseInto(
    gpa: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    out: *std.ArrayList(Case),
    diag: *std.ArrayList(u8),
) Error!void {
    var current: ?Case = null;
    var covers: std.ArrayList([]const u8) = .empty;
    var env: std.ArrayList(Env) = .empty;
    var blobs: std.ArrayList(Blob) = .empty;
    var have_args = false;

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (true) {
        const maybe_line = lines.next();
        const at_end = maybe_line == null;
        const raw_line = maybe_line orelse "";
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");

        const starts_case = line.len > 2 and line[0] == '[' and line[line.len - 1] == ']';
        if (at_end or starts_case) {
            if (current) |*c| {
                if (!have_args) {
                    try diag.print(gpa, "{s}: case '{s}' has no args:", .{ path, c.name });
                    return error.BadCaseFile;
                }
                c.covers = try covers.toOwnedSlice(gpa);
                c.env = try env.toOwnedSlice(gpa);
                c.blobs = try blobs.toOwnedSlice(gpa);
                try out.append(gpa, c.*);
            }
            if (at_end) break;
            covers = .empty;
            env = .empty;
            blobs = .empty;
            have_args = false;
            current = .{ .name = try gpa.dupe(u8, line[1 .. line.len - 1]), .source = path };
            continue;
        }

        if (line.len == 0 or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            try diag.print(gpa, "{s}:{d}: expected 'key: value'", .{ path, line_no });
            return error.BadCaseFile;
        };
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const c = &(current orelse {
            try diag.print(gpa, "{s}:{d}: key outside of a [case] block", .{ path, line_no });
            return error.BadCaseFile;
        });

        if (std.mem.eql(u8, key, "desc")) {
            c.desc = try gpa.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "args")) {
            c.args = try splitArgs(gpa, value, path, line_no, diag);
            have_args = true;
        } else if (std.mem.eql(u8, key, "transcript")) {
            c.transcript = try gpa.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "covers")) {
            var t = std.mem.tokenizeAny(u8, value, " \t,");
            while (t.next()) |tok| try covers.append(gpa, try gpa.dupe(u8, tok));
        } else if (std.mem.eql(u8, key, "env")) {
            const eq = std.mem.indexOfScalar(u8, value, '=') orelse {
                try diag.print(gpa, "{s}:{d}: env: needs NAME=VALUE", .{ path, line_no });
                return error.BadCaseFile;
            };
            try env.append(gpa, .{
                .name = try gpa.dupe(u8, value[0..eq]),
                .value = try gpa.dupe(u8, value[eq + 1 ..]),
            });
        } else if (std.mem.eql(u8, key, "blob") or std.mem.eql(u8, key, "text")) {
            var t = std.mem.tokenizeAny(u8, value, " \t");
            const dest = t.next() orelse {
                try diag.print(gpa, "{s}:{d}: {s}: needs <dest> <fixture>", .{ path, line_no, key });
                return error.BadCaseFile;
            };
            const fixture = t.next() orelse {
                try diag.print(gpa, "{s}:{d}: {s}: needs <dest> <fixture>", .{ path, line_no, key });
                return error.BadCaseFile;
            };
            try blobs.append(gpa, .{
                .dest = try gpa.dupe(u8, dest),
                .fixture = try gpa.dupe(u8, fixture),
                .kind = if (std.mem.eql(u8, key, "blob")) .hex else .text,
            });
        } else if (std.mem.eql(u8, key, "registry")) {
            if (std.mem.eql(u8, value, "default")) {
                c.registry = .default;
            } else if (std.mem.eql(u8, value, "none")) {
                c.registry = .none;
            } else {
                try diag.print(gpa, "{s}:{d}: registry: must be 'default' or 'none'", .{ path, line_no });
                return error.BadCaseFile;
            }
        } else if (std.mem.eql(u8, key, "timeout_ms")) {
            c.timeout_ms = std.fmt.parseUnsigned(u32, value, 10) catch {
                try diag.print(gpa, "{s}:{d}: timeout_ms: not a number", .{ path, line_no });
                return error.BadCaseFile;
            };
        } else {
            try diag.print(gpa, "{s}:{d}: unknown case key '{s}'", .{ path, line_no, key });
            return error.BadCaseFile;
        }
    }
}

/// Split an `args:` line. Supports double quotes so that arguments containing
/// spaces (`sunoem led get "Front Panel"`) can be expressed.
fn splitArgs(
    gpa: std.mem.Allocator,
    value: []const u8,
    path: []const u8,
    line_no: usize,
    diag: *std.ArrayList(u8),
) Error![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    var i: usize = 0;
    var in_arg = false;
    while (i < value.len) : (i += 1) {
        const ch = value[i];
        switch (ch) {
            ' ', '\t' => {
                if (in_arg) {
                    try args.append(gpa, try gpa.dupe(u8, buf.items));
                    buf.clearRetainingCapacity();
                    in_arg = false;
                }
            },
            '"' => {
                in_arg = true;
                i += 1;
                while (i < value.len and value[i] != '"') : (i += 1) try buf.append(gpa, value[i]);
                if (i >= value.len) {
                    try diag.print(gpa, "{s}:{d}: unterminated quote in args:", .{ path, line_no });
                    return error.BadCaseFile;
                }
            },
            else => {
                in_arg = true;
                try buf.append(gpa, ch);
            },
        }
    }
    if (in_arg) try args.append(gpa, try gpa.dupe(u8, buf.items));
    return args.toOwnedSlice(gpa);
}
