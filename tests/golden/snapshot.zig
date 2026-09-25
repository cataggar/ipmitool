//! Snapshot file format.
//!
//! One `tests/snapshots/<case>.snap` file per case, holding the four things a
//! case asserts on: exit status, stdout, stderr and the IPMI request/response
//! log seen by the dummy BMC. Keeping them in one file makes review and
//! `git diff` of a port PR readable.
//!
//!     #!golden 1
//!     #!case mc_info
//!     #!section exit
//!     0
//!     #!section stdout
//!     Device ID                 : 32
//!     #!section stderr
//!     #!section requests
//!     > netfn=0x06 lun=0x00 cmd=0x01 target_cmd=0x00 data=
//!     < rule=get_device_id ccode=0x00 len=15 data=20 81 ...
//!
//! Section bodies are stored escaped so a snapshot is always valid text:
//! `\` becomes `\\`, and any byte that is not printable ASCII or `\n` becomes
//! `\xNN`. A `#` that would start a `#!` marker line is escaped the same way.
//! A body that does not end in a newline is flagged on the marker line with
//! ` no-final-newline` so snapshots stay byte exact.

const std = @import("std");
const Io = std.Io;

pub const Snapshot = struct {
    exit: []const u8 = "",
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    requests: []const u8 = "",

    pub fn get(s: Snapshot, section: Section) []const u8 {
        return switch (section) {
            .exit => s.exit,
            .stdout => s.stdout,
            .stderr => s.stderr,
            .requests => s.requests,
        };
    }

    pub fn set(s: *Snapshot, section: Section, value: []const u8) void {
        switch (section) {
            .exit => s.exit = value,
            .stdout => s.stdout = value,
            .stderr => s.stderr = value,
            .requests => s.requests = value,
        }
    }
};

pub const Section = enum {
    exit,
    stdout,
    stderr,
    requests,

    pub const all = [_]Section{ .exit, .stdout, .stderr, .requests };
};

pub const Error = error{BadSnapshot} || std.mem.Allocator.Error;

/// Preserve the full reset run while keeping its 98,000-line snapshot
/// reviewable. Only stdout and the request log are summarized; exit and stderr
/// remain literal. Differential runs still compare the original byte streams.
pub fn summarize(gpa: std.mem.Allocator, snap: Snapshot) std.mem.Allocator.Error!Snapshot {
    return .{
        .exit = snap.exit,
        .stdout = try summarizeSection(gpa, snap.stdout, 2, 2),
        .stderr = snap.stderr,
        .requests = try summarizeSection(gpa, snap.requests, 20, 5),
    };
}

fn summarizeSection(
    gpa: std.mem.Allocator,
    body: []const u8,
    first_lines: usize,
    last_lines: usize,
) std.mem.Allocator.Error![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);

    var first_end: usize = 0;
    for (0..first_lines) |_| {
        first_end = if (std.mem.indexOfScalarPos(u8, body, first_end, '\n')) |at| at + 1 else body.len;
        if (first_end == body.len) break;
    }
    var last_start = body.len;
    if (last_start > 0 and body[last_start - 1] == '\n') last_start -= 1;
    for (0..last_lines) |_| {
        last_start = if (std.mem.lastIndexOfScalar(u8, body[0..last_start], '\n')) |at| at else 0;
        if (last_start == 0) break;
    }
    if (last_start > 0) last_start += 1;

    return std.fmt.allocPrint(
        gpa,
        "bytes={d} sha256={s}\nfirst {d} lines:\n{s}...\nlast {d} lines:\n{s}",
        .{ body.len, &hex, first_lines, body[0..first_end], last_lines, body[last_start..] },
    );
}

pub fn render(gpa: std.mem.Allocator, case_name: []const u8, snap: Snapshot) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "#!golden 1\n");
    try out.print(gpa, "#!case {s}\n", .{case_name});
    for (Section.all) |section| {
        const body = snap.get(section);
        const needs_flag = body.len != 0 and body[body.len - 1] != '\n';
        try out.print(gpa, "#!section {t}{s}\n", .{
            section,
            if (needs_flag) " no-final-newline" else "",
        });
        try escapeInto(gpa, &out, body);
        if (needs_flag) try out.append(gpa, '\n');
    }

    return out.toOwnedSlice(gpa);
}

test "compact snapshots detect changes outside the visible samples" {
    const gpa = std.testing.allocator;
    var requests: std.ArrayList(u8) = .empty;
    defer requests.deinit(gpa);
    for (0..40) |i| try requests.print(gpa, "request-{d}\n", .{i});
    const modified_requests = try gpa.dupe(u8, requests.items);
    defer gpa.free(modified_requests);
    const changed_at = std.mem.indexOf(u8, modified_requests, "request-25").?;
    modified_requests[changed_at + "request-".len] = '9';

    const original: Snapshot = .{
        .exit = "0\n",
        .stdout = "first\nsecond\nhidden\nmore\npenultimate\nlast\n",
        .requests = requests.items,
    };
    const changed: Snapshot = .{
        .exit = "0\n",
        .stdout = "first\nsecond\nHIDDEN\nmore\npenultimate\nlast\n",
        .requests = modified_requests,
    };
    const a = try summarize(gpa, original);
    defer gpa.free(a.stdout);
    defer gpa.free(a.requests);
    const b = try summarize(gpa, changed);
    defer gpa.free(b.stdout);
    defer gpa.free(b.requests);
    try std.testing.expect(!std.mem.eql(u8, a.stdout, b.stdout));
    try std.testing.expect(!std.mem.eql(u8, a.requests, b.requests));
    const stdout_header_end = std.mem.indexOfScalar(u8, a.stdout, '\n').? + 1;
    const requests_header_end = std.mem.indexOfScalar(u8, a.requests, '\n').? + 1;
    try std.testing.expectEqualStrings(a.stdout[stdout_header_end..], b.stdout[stdout_header_end..]);
    try std.testing.expectEqualStrings(a.requests[requests_header_end..], b.requests[requests_header_end..]);
    try std.testing.expectEqualStrings(original.exit, a.exit);
    try std.testing.expect(std.mem.indexOf(u8, a.requests, "request-0\n") != null);
}

pub fn parse(gpa: std.mem.Allocator, path: []const u8, text: []const u8, diag: *std.ArrayList(u8)) Error!Snapshot {
    var snap: Snapshot = .{};
    var current: ?Section = null;
    var no_final_newline = false;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    var pending: ?[]const u8 = lines.next();
    while (pending) |line| {
        line_no += 1;
        pending = lines.next();
        const is_last_empty = pending == null and line.len == 0;

        if (first) {
            first = false;
            if (!std.mem.startsWith(u8, line, "#!golden ")) {
                try diag.print(gpa, "{s}: missing '#!golden' header", .{path});
                return error.BadSnapshot;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "#!case ")) continue;
        if (std.mem.startsWith(u8, line, "#!section ")) {
            try flush(gpa, &snap, current, &body, no_final_newline);
            const rest = line["#!section ".len..];
            var t = std.mem.tokenizeAny(u8, rest, " \t\r");
            const name = t.next() orelse {
                try diag.print(gpa, "{s}:{d}: '#!section' without a name", .{ path, line_no });
                return error.BadSnapshot;
            };
            current = std.meta.stringToEnum(Section, name) orelse {
                try diag.print(gpa, "{s}:{d}: unknown section '{s}'", .{ path, line_no, name });
                return error.BadSnapshot;
            };
            no_final_newline = std.mem.indexOf(u8, rest, "no-final-newline") != null;
            continue;
        }
        if (current == null) {
            try diag.print(gpa, "{s}:{d}: content before the first '#!section'", .{ path, line_no });
            return error.BadSnapshot;
        }
        if (is_last_empty) continue;
        try unescapeInto(gpa, &body, line, path, line_no, diag);
        try body.append(gpa, '\n');
    }
    try flush(gpa, &snap, current, &body, no_final_newline);
    return snap;
}

fn flush(
    gpa: std.mem.Allocator,
    snap: *Snapshot,
    section: ?Section,
    body: *std.ArrayList(u8),
    no_final_newline: bool,
) Error!void {
    const s = section orelse return;
    if (no_final_newline and body.items.len > 0) _ = body.pop();
    snap.set(s, try gpa.dupe(u8, body.items));
    body.clearRetainingCapacity();
}

fn escapeInto(gpa: std.mem.Allocator, out: *std.ArrayList(u8), body: []const u8) Error!void {
    var at_line_start = true;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const ch = body[i];
        if (ch == '\\') {
            try out.appendSlice(gpa, "\\\\");
            at_line_start = false;
        } else if (ch == '\n') {
            try out.append(gpa, '\n');
            at_line_start = true;
        } else if (at_line_start and ch == '#' and i + 1 < body.len and body[i + 1] == '!') {
            try out.appendSlice(gpa, "\\x23");
            at_line_start = false;
        } else if (ch == '\t') {
            try out.appendSlice(gpa, "\\t");
            at_line_start = false;
        } else if (ch == ' ' and (i + 1 == body.len or body[i + 1] == '\n')) {
            // Escape trailing whitespace so it survives editors and `git diff`.
            try out.appendSlice(gpa, "\\x20");
            at_line_start = false;
        } else if (ch < 0x20 or ch > 0x7e) {
            try out.print(gpa, "\\x{x:0>2}", .{ch});
            at_line_start = false;
        } else {
            try out.append(gpa, ch);
            at_line_start = false;
        }
    }
}

fn unescapeInto(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
    path: []const u8,
    line_no: usize,
    diag: *std.ArrayList(u8),
) Error!void {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '\\') {
            try out.append(gpa, line[i]);
            continue;
        }
        if (i + 1 >= line.len) {
            try diag.print(gpa, "{s}:{d}: trailing backslash", .{ path, line_no });
            return error.BadSnapshot;
        }
        i += 1;
        switch (line[i]) {
            '\\' => try out.append(gpa, '\\'),
            't' => try out.append(gpa, '\t'),
            'x' => {
                if (i + 2 >= line.len) {
                    try diag.print(gpa, "{s}:{d}: truncated \\xNN escape", .{ path, line_no });
                    return error.BadSnapshot;
                }
                const byte = std.fmt.parseUnsigned(u8, line[i + 1 .. i + 3], 16) catch {
                    try diag.print(gpa, "{s}:{d}: bad \\xNN escape", .{ path, line_no });
                    return error.BadSnapshot;
                };
                try out.append(gpa, byte);
                i += 2;
            },
            else => {
                try diag.print(gpa, "{s}:{d}: unknown escape '\\{c}'", .{ path, line_no, line[i] });
                return error.BadSnapshot;
            },
        }
    }
}
