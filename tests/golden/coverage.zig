//! Command coverage check.
//!
//! The list of top-level commands is read out of the C command table in
//! `src/ipmitool.c` rather than from documentation, so a command that is added
//! (or that a port forgets to register) cannot silently escape the suite.
//!
//! For every command the suite must contain at least one case that runs it and
//! at least one case that runs its `help` path; `covers:` in a case file is
//! what claims the credit.

const std = @import("std");
const Io = std.Io;

pub const Command = struct {
    name: []const u8,
    /// Number of cases whose `covers:` mentions this command.
    cases: u32 = 0,
    /// Number of those cases whose args end in `help`.
    help_cases: u32 = 0,
};

pub const Error = error{BadCommandTable} || std.mem.Allocator.Error;

const table_marker = "ipmitool_cmd_list[]";

/// Extract the command names from `<repo>/src/ipmitool.c`.
pub fn commandTable(
    gpa: std.mem.Allocator,
    io: Io,
    source_path: []const u8,
    diag: *std.ArrayList(u8),
) Error![]Command {
    const text = Io.Dir.cwd().readFileAlloc(io, source_path, gpa, .unlimited) catch {
        try diag.print(gpa, "cannot read the C command table '{s}'", .{source_path});
        return error.BadCommandTable;
    };
    defer gpa.free(text);

    const table_at = std.mem.indexOf(u8, text, table_marker) orelse {
        try diag.print(gpa, "{s}: '{s}' not found", .{ source_path, table_marker });
        return error.BadCommandTable;
    };

    var commands: std.ArrayList(Command) = .empty;
    var lines = std.mem.splitScalar(u8, text[table_at..], '\n');
    _ = lines.next(); // the declaration line itself
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "};")) break;
        if (std.mem.startsWith(u8, line, "{ NULL }")) break;
        if (line.len == 0 or line[0] == '#' or line[0] == '/') continue;
        if (line[0] != '{') continue;
        const first = std.mem.indexOfScalar(u8, line, '"') orelse continue;
        const rest = line[first + 1 ..];
        const second = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        const name = rest[0..second];
        if (name.len == 0) continue;
        try commands.append(gpa, .{ .name = try gpa.dupe(u8, name) });
    }

    if (commands.items.len == 0) {
        try diag.print(gpa, "{s}: command table parsed as empty", .{source_path});
        return error.BadCommandTable;
    }
    return commands.toOwnedSlice(gpa);
}
