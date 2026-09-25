//! Readline-free interactive editor and shared shell/script word parser.
//! shell_commands.zig supplies the other src/ipmishell.c entry points.
const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const log = @import("../util/log.zig");

const allocator = std.heap.c_allocator;
pub const max_args = 64;
const prompt = "ipmitool> ";
const handled_signals = [_]c_int{ c.SIGINT, c.SIGTERM, c.SIGHUP, c.SIGQUIT };
var pending_signal: c_int = 0;

fn markSignal(sig: c_int) callconv(.c) void {
    @atomicStore(c_int, &pending_signal, sig, .monotonic);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn out(bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(1, bytes.ptr + offset, bytes.len - offset);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) break;
        offset += @intCast(n);
    }
}

fn columns(bytes: []const u8) usize {
    var n: usize = 0;
    for (bytes) |byte| {
        if (byte & 0xc0 != 0x80) n += 1;
    }
    return n;
}

fn redraw(line: []const u8, cursor: usize, previous: *usize, ansi: bool) void {
    if (ansi) {
        out("\r\x1b[2K" ++ prompt);
    } else {
        out("\r" ++ prompt);
    }
    out(line);
    const width = columns(line);
    if (!ansi) {
        var blanks = previous.* -| width;
        while (blanks > 0) : (blanks -= 1) out(" ");
        // Backspace is supported even by terminals without ANSI escape codes.
        blanks = previous.* -| width;
        var back = columns(line[cursor..]) + blanks;
        while (back > 0) : (back -= 1) out("\x08");
    } else if (cursor < line.len) {
        var buf: [32]u8 = undefined;
        const move = std.fmt.bufPrint(&buf, "\x1b[{d}D", .{columns(line[cursor..])}) catch unreachable;
        out(move);
    }
    previous.* = width;
}

const Editor = struct {
    line: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    history_pos: usize,
    saved: std.ArrayList(u8) = .empty,

    fn deinit(self: *Editor) void {
        self.line.deinit(allocator);
        self.saved.deinit(allocator);
    }

    fn replace(self: *Editor, text: []const u8) !void {
        self.line.clearRetainingCapacity();
        try self.line.appendSlice(allocator, text);
        self.cursor = self.line.items.len;
    }

    fn previous(self: *Editor, history: []const []u8) !void {
        if (self.history_pos == 0) return;
        if (self.history_pos == history.len) {
            self.saved.clearRetainingCapacity();
            try self.saved.appendSlice(allocator, self.line.items);
        }
        self.history_pos -= 1;
        try self.replace(history[self.history_pos]);
    }

    fn next(self: *Editor, history: []const []u8) !void {
        if (self.history_pos == history.len) return;
        self.history_pos += 1;
        try self.replace(if (self.history_pos == history.len) self.saved.items else history[self.history_pos]);
    }

    fn insert(self: *Editor, byte: u8) !void {
        try self.line.insert(allocator, self.cursor, byte);
        self.cursor += 1;
    }

    fn delete(self: *Editor) void {
        if (self.cursor < self.line.items.len) _ = self.line.orderedRemove(self.cursor);
    }

    fn backspace(self: *Editor) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        while (self.cursor > 0 and self.line.items[self.cursor] & 0xc0 == 0x80) self.cursor -= 1;
        self.delete();
        while (self.cursor < self.line.items.len and self.line.items[self.cursor] & 0xc0 == 0x80) self.delete();
    }

    fn left(self: *Editor) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        while (self.cursor > 0 and self.line.items[self.cursor] & 0xc0 == 0x80) self.cursor -= 1;
    }

    fn right(self: *Editor) void {
        if (self.cursor == self.line.items.len) return;
        self.cursor += 1;
        while (self.cursor < self.line.items.len and self.line.items[self.cursor] & 0xc0 == 0x80) self.cursor += 1;
    }
};

/// Returns an owned line, null at EOF, or Cancelled for Ctrl-C.
fn readLine(intf: *Intf, history: []const []u8) error{ OutOfMemory, Cancelled, Interrupted, Io }!?[]u8 {
    var editor = Editor{ .history_pos = history.len };
    defer editor.deinit();

    var old: c.struct_termios = undefined;
    const interactive = c.isatty(0) == 1 and c.tcgetattr(0, &old) == 0;
    if (interactive) {
        @atomicStore(c_int, &pending_signal, 0, .monotonic);
    }
    var previous: [handled_signals.len]c.__sighandler_t = undefined;
    if (interactive) {
        for (handled_signals, 0..) |sig, i| previous[i] = c.signal(sig, markSignal);
    }
    defer {
        if (interactive) for (handled_signals, 0..) |sig, i| {
            _ = c.signal(sig, previous[i]);
        };
    }
    if (interactive) {
        var raw = old;
        c.cfmakeraw(&raw);
        if (c.tcsetattr(0, c.TCSANOW, &raw) != 0) return error.Io;
    }
    defer {
        if (interactive) _ = c.tcsetattr(0, c.TCSANOW, &old);
    }

    out(prompt);
    var escape: u8 = 0;
    var csi_number: usize = 0;
    var ticks: usize = 0;
    var rendered_columns: usize = 0;
    const ansi = if (c.getenv("TERM")) |term| !eq(std.mem.span(term), "dumb") else false;
    while (true) {
        if (interactive and @atomicLoad(c_int, &pending_signal, .monotonic) != 0) return error.Interrupted;
        if (interactive or intf.keepalive != null) {
            var fd = c.struct_pollfd{ .fd = 0, .events = c.POLLIN, .revents = 0 };
            const ready = c.poll(&fd, 1, 999);
            if (ready < 0) {
                if (std.c._errno().* == c.EINTR) continue;
                return error.Io;
            }
            if (ready == 0) {
                if (intf.keepalive) |keepalive| {
                    ticks += 1;
                    if (ticks >= 30) {
                        ticks = 0;
                        _ = keepalive(intf);
                    }
                }
                continue;
            }
        }
        var byte: u8 = undefined;
        const n = c.read(0, &byte, 1);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n < 0) return error.Io;
        if (n == 0) {
            out("\n");
            return if (editor.line.items.len == 0) null else try allocator.dupe(u8, editor.line.items);
        }
        if (interactive and escape == 1) {
            escape = if (byte == '[' or byte == 'O') 2 else 0;
            csi_number = 0;
            continue;
        }
        if (interactive and escape == 2) {
            if (byte >= '0' and byte <= '9') {
                csi_number = @min(csi_number *| 10 +| (byte - '0'), 1000);
                continue;
            }
            escape = 0;
            switch (byte) {
                'A' => try editor.previous(history),
                'B' => try editor.next(history),
                'C' => editor.right(),
                'D' => editor.left(),
                'H' => editor.cursor = 0,
                'F' => editor.cursor = editor.line.items.len,
                '~' => switch (csi_number) {
                    1, 7 => editor.cursor = 0,
                    3 => editor.delete(),
                    4, 8 => editor.cursor = editor.line.items.len,
                    else => {},
                },
                else => {},
            }
            redraw(editor.line.items, editor.cursor, &rendered_columns, ansi);
            continue;
        }
        if (interactive and byte == 0x1b) {
            escape = 1;
            continue;
        }
        switch (byte) {
            '\r', '\n' => {
                out("\r\n");
                return try allocator.dupe(u8, editor.line.items);
            },
            3 => {
                if (interactive) {
                    out("^C\r\n");
                    return error.Cancelled;
                }
            },
            4 => {
                if (editor.line.items.len == 0) {
                    out("\n");
                    return null;
                }
                if (interactive) editor.delete();
            },
            1 => if (interactive) {
                editor.cursor = 0;
            },
            5 => if (interactive) {
                editor.cursor = editor.line.items.len;
            },
            11 => if (interactive) {
                editor.line.shrinkRetainingCapacity(editor.cursor);
            },
            21 => if (interactive) {
                std.mem.copyForwards(u8, editor.line.items, editor.line.items[editor.cursor..]);
                editor.line.shrinkRetainingCapacity(editor.line.items.len - editor.cursor);
                editor.cursor = 0;
            },
            8, 127 => if (interactive) {
                editor.backspace();
            },
            else => if (byte >= 32 or byte == '\t') try editor.insert(byte),
        }
        if (interactive) redraw(editor.line.items, editor.cursor, &rendered_columns, ansi);
    }
}

/// Parse shell words; quoted spaces stay within a word, including empty quotes.
/// Unlike the C ~ substitution, literal tildes are never modified.
pub fn parse(arena: std.mem.Allocator, text: []const u8, comments: bool) !std.ArrayList([*:0]u8) {
    var args: std.ArrayList([*:0]u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
        if (i == text.len or (comments and text[i] == '#')) break;
        if (args.items.len == max_args) return error.TooManyArguments;
        var word: std.ArrayList(u8) = .empty;
        var quote: u8 = 0;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (quote == 0 and ((comments and ch == '#') or std.ascii.isWhitespace(ch))) break;
            if (ch == '\'' or ch == '"') {
                if (quote == 0) {
                    quote = ch;
                    continue;
                }
                if (quote == ch) {
                    quote = 0;
                    continue;
                }
            }
            try word.append(arena, ch);
        }
        if (quote != 0) return error.UnterminatedQuote;
        try args.append(arena, (try arena.dupeZ(u8, word.items)).ptr);
    }
    return args;
}

fn dispatch(intf: *Intf, text: []const u8, comments: bool) c_int {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const args = parse(arena_state.allocator(), text, comments) catch |err| {
        c.lprintf(log.Level.err, "Invalid command line: %s", @errorName(err).ptr);
        return -1;
    };
    if (args.items.len == 0) return 0;
    var argv: [max_args + 1][*c]u8 = @splat(null);
    for (args.items, 0..) |arg, i| argv[i] = arg;
    return c.ipmi_cmd_run(@ptrCast(intf), argv[0], @intCast(args.items.len - 1), &argv[1]);
}

fn shellMain(intf: *Intf, _: c_int, _: [*c][*c]u8) callconv(.c) c_int {
    var history: std.ArrayList([]u8) = .empty;
    defer {
        for (history.items) |entry| allocator.free(entry);
        history.deinit(allocator);
    }
    var rc: c_int = 0;
    while (true) {
        const line = readLine(intf, history.items) catch |err| {
            if (err == error.Cancelled) continue;
            if (err == error.Interrupted) {
                const sig = @atomicLoad(c_int, &pending_signal, .monotonic);
                _ = c.raise(sig);
                return -1;
            }
            c.lprintf(log.Level.err, "shell: %s", @errorName(err).ptr);
            return -1;
        } orelse return rc;
        defer allocator.free(line);
        if (line.len == 0) continue;
        if (eq(line, "quit") or eq(line, "exit")) return 0;
        if (eq(line, "help") or eq(line, "?")) {
            c.ipmi_cmd_print(@ptrCast(intf.cmdlist));
            _ = c.fflush(null);
            continue;
        }
        const saved = allocator.dupe(u8, line) catch return -1;
        history.append(allocator, saved) catch {
            allocator.free(saved);
            return -1;
        };
        rc = dispatch(intf, line, false);
        _ = c.fflush(null);
    }
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(shellMain), @TypeOf(c.ipmi_shell_main));
    @export(&shellMain, .{ .name = "ipmi_shell_main" });
}

test "quoted shell words, comments and malformed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try parse(arena.allocator(), "echo 'a b' \"x~ y\" '' # tail", true);
    try std.testing.expectEqual(@as(usize, 4), args.items.len);
    try std.testing.expectEqualStrings("a b", std.mem.span(args.items[1]));
    try std.testing.expectEqualStrings("x~ y", std.mem.span(args.items[2]));
    try std.testing.expectEqualStrings("", std.mem.span(args.items[3]));
    try std.testing.expectError(error.UnterminatedQuote, parse(arena.allocator(), "echo 'unfinished", false));
}
