//! Port of `lib/log.c` and `include/ipmitool/log.h`.
//!
//! Selected with `zig build -Dzig-modules=log`, which drops `lib/log.c` from
//! the compile and links this module plus `log_varargs.c` instead.  Every
//! ipmitool translation unit calls `lprintf()`, so this is a link-time
//! substitution the rest of the tree never notices.
//!
//! Two things are worth knowing before reading on:
//!
//! * **The exports are gated.**  Other Zig modules import this file for the
//!   `Level` constants, and an unconditional `@export` here would collide with
//!   `lib/log.c` whenever some *other* module is selected on its own.  So the
//!   `@export` calls live in `exportSymbols()`, which `src/zig/exports.zig`
//!   invokes at comptime only when `log` is in `-Dzig-modules`.
//!
//! * **`lprintf()` and `lperror()` are variadic**, and Zig 0.16 cannot define a
//!   C variadic function on aarch64 (`std.builtin.VaList` is a `@compileError`
//!   under the LLVM backend, ziglang/zig#15389).  `log_varargs.c` keeps the two
//!   `va_start` trampolines; they immediately hand the `va_list` to
//!   `ipmitool_zig_lvprintf`/`ipmitool_zig_lvperror` below, so all observable
//!   behaviour is here.  See doc/zig-migration/varargs-trampoline.md.
//!
//! Allocation: `logInit` takes an allocator explicitly, and the exported
//! `log_init`/`log_halt` pass `std.heap.c_allocator` so the program name stays
//! `malloc`ed exactly as C had it.  Ownership is unchanged: `log_init`
//! allocates, `log_halt` frees, and no allocation crosses the C ABI boundary.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");

/// `LOG_NAME_DEFAULT`.
pub const name_default = "ipmitool";

/// `LOG_MSG_LENGTH`.
pub const msg_length = 1024;

/// syslog priorities, plus the two aliases `log.h` adds.
pub const Level = struct {
    pub const emerg: c_int = c.LOG_EMERG;
    pub const alert: c_int = c.LOG_ALERT;
    pub const crit: c_int = c.LOG_CRIT;
    pub const err: c_int = c.LOG_ERR;
    pub const warning: c_int = c.LOG_WARNING;
    pub const notice: c_int = c.LOG_NOTICE;
    pub const info: c_int = c.LOG_INFO;
    pub const debug: c_int = c.LOG_DEBUG;

    /// `LOG_ERROR` in `log.h`.
    pub const @"error": c_int = c.LOG_ERR;
    /// `LOG_WARN` in `log.h`.
    pub const warn: c_int = c.LOG_WARNING;
};

comptime {
    if (Level.notice != 5) @compileError("unexpected LOG_NOTICE value");
    if (Level.debug != 7) @compileError("unexpected LOG_DEBUG value");
}

/// `va_list` as it appears in a C prototype, taken from the bridge's view of
/// `vsnprintf` so that it is right on every target: x86_64 decays the array
/// type to a pointer, aarch64 passes the descriptor struct by value.
const VaList = @typeInfo(@TypeOf(c.vsnprintf)).@"fn".params[3].type.?;

/// `struct logpriv_s`.  Private, unlike in C: `lib/log.c` gave the `logpriv`
/// global external linkage, but no other translation unit references it.
const LogPriv = struct {
    /// Owned copy of the program name; `null` when the duplication failed,
    /// which C also survives.
    name: ?[:0]u8,
    daemon: bool,
    level: c_int,
};

/// `struct logpriv_s *logpriv`.
///
/// C heap-allocates this and returns silently when `malloc()` fails, which
/// makes the next `lprintf()` dereference NULL; keeping the state inline
/// removes that failure mode without changing any reachable behaviour.
var logpriv: ?LogPriv = null;

/// The allocator behind the exported entry points.  `c_allocator` is a thin
/// wrapper over `malloc`/`free`, which is what `lib/log.c` used and what keeps
/// `log_halt()` a plain `free()` of the same block.
const default_allocator = std.heap.c_allocator;

/// `static char logmsg[LOG_MSG_LENGTH]` inside `lprintf()`.
var printf_msg: [msg_length]u8 = undefined;

/// `static char logmsg[LOG_MSG_LENGTH]` inside `lperror()`.
var perror_msg: [msg_length]u8 = undefined;

/// `log_reinit()`: restore the default configuration after `log_halt()`.
fn reinit(allocator: std.mem.Allocator) void {
    logInit(allocator, null, 0, 0);
}

/// `log_init()`: open the connection to syslog when running as a daemon.
///
/// A second call while logging is already configured is ignored, exactly as in
/// C, so `ipmievd` re-initialising after `fork()` keeps the first setup.
pub fn logInit(
    allocator: std.mem.Allocator,
    name: ?[*:0]const u8,
    isdaemon: c_int,
    verbose: c_int,
) void {
    if (logpriv != null) return;

    const wanted = if (name) |n| std.mem.span(n) else name_default;
    // C reports the failure and carries on with a NULL name.
    const copy: ?[:0]u8 = allocator.dupeZ(u8, wanted) catch blk: {
        _ = c.fprintf(c.stderr, "ipmitool: malloc failure\n");
        break :blk null;
    };

    logpriv = .{
        .name = copy,
        .daemon = isdaemon != 0,
        .level = verbose + Level.notice,
    };

    if (logpriv.?.daemon) {
        c.openlog(if (copy) |n| n.ptr else null, c.LOG_CONS, c.LOG_LOCAL4);
    }
}

/// `log_halt()`: stop syslog logging and release the state.
pub fn logHalt(allocator: std.mem.Allocator) void {
    if (logpriv) |*priv| {
        if (priv.name) |name| {
            allocator.free(name);
            priv.name = null;
        }

        if (priv.daemon) c.closelog();

        logpriv = null;
    }
}

/// `log_level_set()`: raise or lower the verbosity.
///
/// Faithful to C, this dereferences the state without checking it: `lib/log.c`
/// would segfault when called before `log_init()`, and every caller in the tree
/// initialises logging first.
pub fn logLevelSet(verbose: c_int) void {
    logpriv.?.level = verbose + Level.notice;
}

/// True when a message at `level` would be printed, initialising the log state
/// on first use exactly like `lprintf()` does.
fn enabled(level: c_int) bool {
    if (logpriv == null) reinit(default_allocator);
    return logpriv.?.level >= level;
}

/// `lprintf()` minus the `va_start`, which `log_varargs.c` did.
fn lvprintf(level: c_int, format: [*:0]const u8, args: VaList) callconv(.c) void {
    if (!enabled(level)) return;

    _ = c.vsnprintf(&printf_msg, msg_length, format, args);

    if (logpriv.?.daemon) {
        c.syslog(level, "%s", &printf_msg);
    } else {
        _ = c.fprintf(c.stderr, "%s\n", &printf_msg);
    }
}

/// `lperror()` minus the `va_start`, which `log_varargs.c` did.
///
/// `errno` is read after the message is formatted, in the same order as C, so
/// a `vsnprintf()` that touched it changes the suffix identically.
fn lvperror(level: c_int, format: [*:0]const u8, args: VaList) callconv(.c) void {
    if (!enabled(level)) return;

    _ = c.vsnprintf(&perror_msg, msg_length, format, args);

    const reason = c.strerror(std.c._errno().*);
    if (logpriv.?.daemon) {
        c.syslog(level, "%s: %s", &perror_msg, reason);
    } else {
        _ = c.fprintf(c.stderr, "%s: %s\n", &perror_msg, reason);
    }
}

// ---------------------------------------------------------------------------
// C ABI surface
//
// `lprintf` and `lperror` themselves are in log_varargs.c; the two
// `ipmitool_zig_lv*` symbols below are the seam between it and this file, and
// are the only symbols here that `lib/log.c` did not have.
// ---------------------------------------------------------------------------

fn logInitAbi(name: ?[*:0]const u8, isdaemon: c_int, verbose: c_int) callconv(.c) void {
    logInit(default_allocator, name, isdaemon, verbose);
}

fn logHaltAbi() callconv(.c) void {
    logHalt(default_allocator);
}

fn logLevelSetAbi(verbose: c_int) callconv(.c) void {
    logLevelSet(verbose);
}

/// Called at comptime from `src/zig/exports.zig` when `log` is selected.
///
/// The ABI assertions live here rather than at file scope so that they are
/// only analysed when the module is actually selected - see the note in
/// doc/zig-migration/varargs-trampoline.md.
pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(logInitAbi), @TypeOf(c.log_init));
    abi.assertCallSignature(@TypeOf(logHaltAbi), @TypeOf(c.log_halt));
    abi.assertCallSignature(@TypeOf(logLevelSetAbi), @TypeOf(c.log_level_set));

    @export(&logInitAbi, .{ .name = "log_init", .linkage = .strong });
    @export(&logHaltAbi, .{ .name = "log_halt", .linkage = .strong });
    @export(&logLevelSetAbi, .{ .name = "log_level_set", .linkage = .strong });
    @export(&lvprintf, .{ .name = "ipmitool_zig_lvprintf", .linkage = .strong });
    @export(&lvperror, .{ .name = "ipmitool_zig_lvperror", .linkage = .strong });
}

test "level aliases match log.h" {
    try std.testing.expectEqual(c.LOG_ERROR, Level.@"error");
    try std.testing.expectEqual(c.LOG_WARN, Level.warn);
    try std.testing.expectEqual(@as(c_int, c.LOG_MSG_LENGTH), msg_length);
    try std.testing.expectEqualStrings(c.LOG_NAME_DEFAULT, name_default);
}

test "log_init is idempotent and log_halt resets it" {
    defer logHalt(std.testing.allocator);

    logInit(std.testing.allocator, "unit-test", 0, 0);
    try std.testing.expect(logpriv != null);
    try std.testing.expectEqualStrings("unit-test", logpriv.?.name.?);
    try std.testing.expectEqual(Level.notice, logpriv.?.level);
    try std.testing.expect(!logpriv.?.daemon);

    // A second init is ignored, as in C.
    logInit(std.testing.allocator, "ignored", 1, 4);
    try std.testing.expectEqualStrings("unit-test", logpriv.?.name.?);
    try std.testing.expectEqual(Level.notice, logpriv.?.level);

    logHalt(std.testing.allocator);
    try std.testing.expect(logpriv == null);

    // log_halt() on an already halted log is a no-op.
    logHalt(std.testing.allocator);
    try std.testing.expect(logpriv == null);
}

test "verbosity offsets LOG_NOTICE and gates messages" {
    defer logHalt(std.testing.allocator);

    logInit(std.testing.allocator, null, 0, 2);
    try std.testing.expectEqualStrings(name_default, logpriv.?.name.?);
    try std.testing.expectEqual(Level.notice + 2, logpriv.?.level);
    try std.testing.expect(enabled(Level.info));
    try std.testing.expect(enabled(Level.debug));

    logLevelSet(0);
    try std.testing.expectEqual(Level.notice, logpriv.?.level);
    try std.testing.expect(enabled(Level.notice));
    try std.testing.expect(!enabled(Level.info));
    try std.testing.expect(!enabled(Level.debug));

    logLevelSet(-1);
    try std.testing.expect(!enabled(Level.notice));
    try std.testing.expect(enabled(Level.warning));
}
