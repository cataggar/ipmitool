//! The transport fixture harness.
//!
//! Runs the real `ipmitool` binary against the deterministic model BMC in
//! `Bmc.zig` over loopback UDP, records every datagram in both directions as a
//! text transcript, and compares that transcript with the checked-in fixture.
//!
//! The same code path both records (`--update`) and checks.  There is no
//! separate replay implementation that could drift away from the recorder, and
//! no frozen response bytes that would stop working the moment a session key
//! depends on a random number the client picked.
//!
//! Usage:
//!   transport-fixtures --binary <ipmitool> [--fixtures-dir D] [--work-dir D]
//!                      [--filter S] [--update] [--list] [-v]

const std = @import("std");
const Io = std.Io;

const Bmc = @import("Bmc.zig");
const Transcript = @import("Transcript.zig");
const cases = @import("cases.zig");

const usage_text =
    \\usage: transport-fixtures [options]
    \\
    \\  --binary PATH        the ipmitool binary under test (required)
    \\  --fixtures-dir DIR   where the .txt fixtures live
    \\  --iana PATH          the trimmed IANA PEN registry fixture
    \\  --work-dir DIR       scratch directory
    \\  --filter SUBSTRING   only run cases whose name contains SUBSTRING
    \\  --update, --accept   rewrite the fixtures instead of comparing
    \\  --list               list the cases and exit
    \\  -v, --verbose        print the transcript of every case
    \\  -h, --help           this text
    \\
;

const shutdown_magic = "\x00transport-fixtures-shutdown";

const Options = struct {
    binary: []const u8 = "",
    fixtures_dir: []const u8 = "tests/transport/fixtures",
    iana: []const u8 = "tests/fixtures/iana/enterprise-numbers",
    work_dir: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    update: bool = false,
    list: bool = false,
    verbose: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;

    // Buffer the whole report and route it by outcome: `zig build` throws away
    // a Run step's stdout but shows its stderr, so a failing case has to print
    // its diff on stderr to be of any use under `zig build test`.
    var report: Io.Writer.Allocating = .init(gpa);
    defer report.deinit();

    const status = dispatch(gpa, io, init, &report.writer);

    var buf: [64 * 1024]u8 = undefined;
    const failed = if (status) |code| code != 0 else |_| true;
    var file = (if (failed) Io.File.stderr() else Io.File.stdout()).writer(io, &buf);
    file.interface.writeAll(report.written()) catch {};
    file.interface.flush() catch {};
    return status;
}

fn dispatch(gpa: std.mem.Allocator, io: Io, init: std.process.Init, out: *Io.Writer) !u8 {
    var opts: Options = .{};

    const args = try init.minimal.args.toSlice(gpa);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--binary")) {
            i += 1;
            opts.binary = args[i];
        } else if (std.mem.eql(u8, arg, "--fixtures-dir")) {
            i += 1;
            opts.fixtures_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--iana")) {
            i += 1;
            opts.iana = args[i];
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            i += 1;
            opts.work_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            opts.filter = args[i];
        } else if (std.mem.eql(u8, arg, "--update") or std.mem.eql(u8, arg, "--accept")) {
            opts.update = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            opts.list = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage_text);
            return 0;
        } else {
            try out.print("transport-fixtures: unknown option '{s}'\n\n{s}", .{ arg, usage_text });
            return 2;
        }
    }

    if (opts.list) {
        for (cases.all) |c| try out.print("{s}\t{s}\n", .{ c.name, c.desc });
        try out.print("{d} cases\n", .{cases.all.len});
        return 0;
    }

    if (opts.binary.len == 0) {
        try out.writeAll("transport-fixtures: --binary is required\n");
        return 2;
    }

    const work_root = opts.work_dir orelse ".transport-work";
    Io.Dir.cwd().deleteTree(io, work_root) catch {};
    try Io.Dir.cwd().createDirPath(io, work_root);
    defer Io.Dir.cwd().deleteTree(io, work_root) catch {};

    if (opts.update) try Io.Dir.cwd().createDirPath(io, opts.fixtures_dir);

    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;
    var updated: u32 = 0;

    for (cases.all) |c| {
        if (opts.filter) |f| {
            if (std.mem.indexOf(u8, c.name, f) == null) {
                skipped += 1;
                continue;
            }
        }

        var name_buf: [128]u8 = undefined;
        const fixture_name = c.fixtureName(&name_buf);
        const fixture_path = try std.fs.path.join(gpa, &.{
            opts.fixtures_dir,
            try std.fmt.allocPrint(gpa, "{s}.txt", .{fixture_name}),
        });

        const outcome = runCase(gpa, io, opts, c, work_root, fixture_name) catch |err| {
            failed += 1;
            try out.print("FAIL {s}\n      harness error: {t}\n", .{ c.name, err });
            continue;
        };

        if (outcome.violations != 0) {
            failed += 1;
            try out.print(
                "FAIL {s}\n      the model BMC reported {d} protocol violation(s); see '!!!' below\n",
                .{ c.name, outcome.violations },
            );
            try indentInto(out, outcome.text);
            if (opts.update) try Io.Dir.cwd().writeFile(io, .{
                .sub_path = fixture_path,
                .data = outcome.text,
            });
            continue;
        }

        if (opts.update) {
            const old = Io.Dir.cwd().readFileAlloc(io, fixture_path, gpa, .unlimited) catch "";
            if (!std.mem.eql(u8, old, outcome.text)) {
                try Io.Dir.cwd().writeFile(io, .{ .sub_path = fixture_path, .data = outcome.text });
                updated += 1;
                try out.print("update {s}\n", .{c.name});
            } else {
                try out.print("same   {s}\n", .{c.name});
            }
            passed += 1;
            continue;
        }

        const expected = Io.Dir.cwd().readFileAlloc(io, fixture_path, gpa, .unlimited) catch {
            failed += 1;
            try out.print(
                "FAIL {s}\n      no fixture at {s}; run `zig build gen-transport-fixtures`\n",
                .{ c.name, fixture_path },
            );
            continue;
        };

        if (std.mem.eql(u8, expected, outcome.text)) {
            passed += 1;
            if (opts.verbose) {
                try out.print("ok   {s}\n", .{c.name});
                try indentInto(out, outcome.text);
            }
        } else {
            failed += 1;
            try out.print("FAIL {s}\n      {s}\n", .{ c.name, fixture_path });
            try Transcript.diff(gpa, expected, outcome.text, out);
        }
    }

    try out.print(
        "\ntransport fixtures: {d} passed, {d} failed, {d} skipped{s}\n",
        .{ passed, failed, skipped, if (opts.update) " (update mode)" else "" },
    );
    if (opts.update and updated != 0) try out.print("{d} fixture(s) rewritten\n", .{updated});
    return if (failed == 0) 0 else 1;
}

fn indentInto(out: *Io.Writer, text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (it.index == null and line.len == 0) break;
        try out.print("      {s}\n", .{line});
    }
}

const Outcome = struct {
    text: []const u8,
    violations: u32,
};

const ServeState = struct {
    io: Io,
    socket: *const Io.net.Socket,
    bmc: *Bmc,
    err: ?anyerror = null,
};

fn serve(st: *ServeState) void {
    var buf: [8192]u8 = undefined;
    while (true) {
        var msg = st.socket.receive(st.io, &buf) catch |err| {
            st.err = err;
            return;
        };
        if (std.mem.startsWith(u8, msg.data, shutdown_magic)) return;
        const reply = st.bmc.handle(msg.data) catch |err| {
            st.err = err;
            return;
        };
        if (reply) |r| st.socket.send(st.io, &msg.from, r) catch |err| {
            st.err = err;
            return;
        };
    }
}

fn requestShutdown(io: Io, address: Io.net.IpAddress) void {
    const any: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const s = any.bind(io, .{ .mode = .dgram }) catch return;
    defer s.close(io);
    s.send(io, &address, shutdown_magic) catch {};
}

fn runCase(
    gpa: std.mem.Allocator,
    io: Io,
    opts: Options,
    c: cases.Case,
    work_root: []const u8,
    fixture_name: []const u8,
) !Outcome {
    const cwd: Io.Dir = .cwd();

    const work = try std.fs.path.join(gpa, &.{ work_root, fixture_name });
    try cwd.createDirPath(io, work);
    const work_abs = try realPath(gpa, io, work);

    // ipmitool takes its program name from basename(argv[0]) and prints it in
    // diagnostics, so always invoke it through a link called `ipmitool`.
    const bin_link = try std.fmt.allocPrint(gpa, "{s}/ipmitool", .{work_abs});
    try cwd.symLink(io, try realPath(gpa, io, opts.binary), bin_link, .{});

    // Without a registry ipmitool prints "IANA PEN registry open failed" and
    // renders every manufacturer as "Unknown", which would make the transcript
    // depend on whatever the machine happens to have installed.  Point $HOME at
    // a scratch directory holding the same trimmed fixture the golden suite
    // uses, so the lookup is controlled rather than scrubbed.
    const registry_dir = try std.fmt.allocPrint(gpa, "{s}/.local/usr/share/misc", .{work_abs});
    try cwd.createDirPath(io, registry_dir);
    try cwd.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(gpa, "{s}/enterprise-numbers", .{registry_dir}),
        .data = try cwd.readFileAlloc(io, opts.iana, gpa, .unlimited),
    });

    const bind_addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const socket = try bind_addr.bind(io, .{ .mode = .dgram });
    defer socket.close(io);
    const port = socket.address.getPort();

    const port_text = try std.fmt.allocPrint(gpa, "{d}", .{port});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa, bin_link);
    for (c.args) |a| {
        try argv.append(gpa, if (std.mem.eql(u8, a, "${port}")) port_text else a);
    }

    var transcript: Transcript = .init(gpa);
    try transcript.print("# case  {s}\n", .{c.name});
    try transcript.print("# desc  {s}\n", .{c.desc});
    try transcript.print("# args  ipmitool", .{});
    for (c.args) |a| try transcript.print(" {s}", .{a});
    try transcript.print("\n", .{});

    var bmc: Bmc = .init(gpa, &transcript, c.bmc);

    var env: std.process.Environ.Map = .init(gpa);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HOME", work_abs);
    try env.put("TZ", "UTC");
    try env.put("LC_ALL", "C");
    try env.put("LANG", "C");
    try env.put("TERM", "dumb");
    try env.put("COLUMNS", "80");

    var state: ServeState = .{ .io = io, .socket = &socket, .bmc = &bmc };
    var future = try io.concurrent(serve, .{&state});

    const result = std.process.run(gpa, io, .{
        .argv = argv.items,
        .environ_map = &env,
        .cwd = .{ .path = work_abs },
        .timeout = .{ .duration = .{
            .raw = .fromMilliseconds(c.timeout_ms),
            .clock = .awake,
        } },
    }) catch |err| {
        requestShutdown(io, socket.address);
        future.await(io);
        return err;
    };
    requestShutdown(io, socket.address);
    future.await(io);

    if (state.err) |err| {
        try transcript.print("  !!! model BMC aborted: {t}\n", .{err});
        bmc.violations += 1;
    }

    switch (result.term) {
        .exited => |code| try transcript.print("exit {d}\n", .{code}),
        .signal => |sig| try transcript.print("exit signal {t}\n", .{sig}),
        .stopped => |sig| try transcript.print("exit stopped {t}\n", .{sig}),
        .unknown => |code| try transcript.print("exit unknown {d}\n", .{code}),
    }
    try transcript.outputBlock("out", try scrub(gpa, result.stdout, work_abs, port_text));
    try transcript.outputBlock("err", try scrub(gpa, result.stderr, work_abs, port_text));

    return .{ .text = transcript.text(), .violations = bmc.violations };
}

fn realPath(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try Io.Dir.cwd().realPathFile(io, path, &buf);
    return gpa.dupe(u8, buf[0..len]);
}

/// The only two things in the tool's output that are not reproducible between
/// runs: the ephemeral port and the scratch directory.  Everything else is
/// controlled, not scrubbed.
fn scrub(gpa: std.mem.Allocator, text: []const u8, work_abs: []const u8, port: []const u8) ![]const u8 {
    var stage = text;
    if (std.mem.indexOf(u8, stage, work_abs) != null) {
        stage = try std.mem.replaceOwned(u8, gpa, stage, work_abs, "{work}");
    }
    if (std.mem.indexOf(u8, stage, port) != null) {
        stage = try std.mem.replaceOwned(u8, gpa, stage, port, "${port}");
    }
    return stage;
}

test {
    _ = Transcript;
    _ = Bmc;
    _ = @import("crypto.zig");
}

test "every case name is unique and fixture-safe" {
    for (cases.all, 0..) |a, ai| {
        try std.testing.expect(a.name.len > 0);
        for (cases.all[ai + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}
