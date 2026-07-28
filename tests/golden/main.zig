//! ipmitool golden test harness.
//!
//! Runs a declarative list of cases against an ipmitool binary, feeding the
//! `dummy` interface from recorded transcripts and comparing stdout, stderr,
//! the exit status and the IPMI request log against committed snapshots.
//!
//! See doc/zig-migration/golden-harness.md for the full description.
//!
//! Usage:
//!
//!     zig build test-golden [-- options]
//!     tests/run.sh [options]
//!     zig run tests/golden/main.zig -- [options]
//!
//!     --binary <path>      binary under test (default: $IPMITOOL_BINARY, then
//!                          $IPMITOOL_ORACLE, then tests/oracle/ipmitool)
//!     --candidate <path>   enable differential mode: run --binary and
//!                          --candidate over the same cases and diff them
//!                          against each other instead of against snapshots
//!     --filter <substr>    only run cases whose name contains <substr>
//!     --update, --accept   rewrite snapshots instead of comparing
//!     --list               print the case names and exit
//!     --coverage           print the coverage report and exit
//!     --tests-dir <path>   default: the directory containing this file
//!     --repo <path>        repository root (default: parent of --tests-dir)
//!     --work-dir <path>    scratch root (default: <repo>/.golden-work)
//!     --keep               keep the scratch directories
//!     --allow-uncovered    do not fail when a C command has no case
//!     -v, --verbose        print each case as it runs
//!
//! The report goes to stdout on success and to stderr on failure, so a failing
//! case surfaces its diff through `zig build`, which discards a run step's
//! stdout but reports its stderr.

const std = @import("std");
const Io = std.Io;

const Case = @import("Case.zig");
const DummyBmc = @import("DummyBmc.zig");
const Transcript = @import("Transcript.zig");
const coverage = @import("coverage.zig");
const diff = @import("diff.zig");
const hex = @import("hex.zig");
const snapshot = @import("snapshot.zig");

const version_placeholder = "<VERSION>";
const work_placeholder = "<WORK>";
const binary_placeholder = "<BINARY>";

const Options = struct {
    binary: []const u8 = "",
    candidate: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    update: bool = false,
    list: bool = false,
    coverage_only: bool = false,
    tests_dir: []const u8 = "tests",
    repo: ?[]const u8 = null,
    work_dir: ?[]const u8 = null,
    keep: bool = false,
    allow_uncovered: bool = false,
    verbose: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;

    // The report is buffered and then routed by outcome: to stdout when the
    // run succeeded, to stderr when it did not.  `zig build` discards a Run
    // step's stdout but surfaces its stderr as the failure diagnostic, so this
    // is what makes a failing case print its diff under `zig build test`
    // instead of just an exit code.
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
    opts.tests_dir = try defaultTestsDir(gpa);

    const args = try init.minimal.args.toSlice(gpa);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--binary")) {
            i += 1;
            opts.binary = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--candidate")) {
            i += 1;
            opts.candidate = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            opts.filter = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--tests-dir")) {
            i += 1;
            opts.tests_dir = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--repo")) {
            i += 1;
            opts.repo = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            i += 1;
            opts.work_dir = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--update") or std.mem.eql(u8, arg, "--accept")) {
            opts.update = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            opts.list = true;
        } else if (std.mem.eql(u8, arg, "--coverage")) {
            opts.coverage_only = true;
        } else if (std.mem.eql(u8, arg, "--keep")) {
            opts.keep = true;
        } else if (std.mem.eql(u8, arg, "--allow-uncovered")) {
            opts.allow_uncovered = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage_text);
            return 0;
        } else {
            try out.print("golden: unknown option '{s}'\n\n{s}", .{ arg, usage_text });
            return 2;
        }
    }

    const repo = opts.repo orelse std.fs.path.dirname(opts.tests_dir) orelse ".";
    const work_root = opts.work_dir orelse try std.fs.path.join(gpa, &.{ repo, ".golden-work" });

    var diag: std.ArrayList(u8) = .empty;
    const ctx: hex.Context = .{
        .gpa = gpa,
        .io = io,
        .fixtures_dir = try std.fs.path.join(gpa, &.{ opts.tests_dir, "fixtures" }),
        .diag = &diag,
    };

    const cases = Case.loadAll(gpa, io, try std.fs.path.join(gpa, &.{ opts.tests_dir, "cases" }), &diag) catch {
        try out.print("golden: {s}\n", .{diag.items});
        return 2;
    };

    if (opts.list) {
        for (cases) |c| try out.print("{s}\t{s}\n", .{ c.name, c.desc });
        try out.print("{d} cases\n", .{cases.len});
        return 0;
    }

    const commands = coverage.commandTable(
        gpa,
        io,
        try std.fs.path.join(gpa, &.{ repo, "src", "ipmitool.c" }),
        &diag,
    ) catch {
        try out.print("golden: {s}\n", .{diag.items});
        return 2;
    };
    creditCoverage(commands, cases);

    if (opts.coverage_only) {
        const covered = try reportCoverage(out, commands, false);
        if (!covered and !opts.allow_uncovered) return 1;
        return 0;
    }

    if (opts.binary.len == 0) {
        opts.binary = defaultBinary(gpa, io, init.environ_map, repo) catch "";
        if (opts.binary.len == 0) {
            try out.writeAll(
                \\golden: no binary under test.
                \\  Pass --binary <path>, or set IPMITOOL_BINARY / IPMITOOL_ORACLE,
                \\  or place the Phase 0 oracle at tests/oracle/ipmitool.
                \\
            );
            return 2;
        }
    }

    Io.Dir.cwd().deleteTree(io, work_root) catch {};
    try Io.Dir.cwd().createDirPath(io, work_root);
    defer if (!opts.keep) Io.Dir.cwd().deleteTree(io, work_root) catch {};

    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;
    var report: std.ArrayList(u8) = .empty;

    for (cases) |c| {
        if (opts.filter) |f| {
            if (std.mem.indexOf(u8, c.name, f) == null) {
                skipped += 1;
                continue;
            }
        }
        if (opts.verbose) {
            try out.print("running {s}\n", .{c.name});
            try out.flush();
        }

        const outcome = runCase(gpa, io, ctx, opts, work_root, c, &report) catch |err| {
            try report.print(gpa, "FAIL {s}: harness error: {t}\n", .{ c.name, err });
            if (diag.items.len != 0) {
                try report.print(gpa, "  {s}\n", .{diag.items});
                diag.clearRetainingCapacity();
            }
            failed += 1;
            continue;
        };
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    if (report.items.len != 0) try out.writeAll(report.items);

    const mode = if (opts.candidate != null)
        "differential"
    else if (opts.update)
        "update"
    else
        "snapshot";
    try out.print("\ngolden [{s}]: {d} passed, {d} failed, {d} filtered out ({d} cases total)\n", .{
        mode, passed, failed, skipped, cases.len,
    });

    const covered_ok = try reportCoverage(out, commands, true);
    if (failed != 0) return 1;
    if (!covered_ok and !opts.allow_uncovered) return 1;
    return 0;
}

const usage_text =
    \\ipmitool golden test harness
    \\
    \\  tests/run.sh [options]
    \\
    \\  --binary <path>      binary under test
    \\  --candidate <path>   differential mode: diff --binary against --candidate
    \\  --filter <substr>    only run matching cases
    \\  --update, --accept   rewrite snapshots
    \\  --list               list cases
    \\  --coverage           print the command coverage report only
    \\  --tests-dir <path>   location of cases/, transcripts/, fixtures/, snapshots/
    \\  --repo <path>        repository root
    \\  --work-dir <path>    scratch root
    \\  --keep               keep scratch directories
    \\  --allow-uncovered    do not fail on uncovered commands
    \\  -v, --verbose        trace each case
    \\
;

fn defaultTestsDir(gpa: std.mem.Allocator) ![]const u8 {
    // This file lives in tests/golden/, so the tests directory is its parent.
    const here = std.fs.path.dirname(@src().file) orelse "tests/golden";
    return std.fs.path.dirname(here) orelse gpa.dupe(u8, "tests");
}

fn defaultBinary(
    gpa: std.mem.Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
    repo: []const u8,
) ![]const u8 {
    if (environ_map.get("IPMITOOL_BINARY")) |v| if (v.len != 0) return gpa.dupe(u8, v);
    if (environ_map.get("IPMITOOL_ORACLE")) |v| if (v.len != 0) return gpa.dupe(u8, v);
    const fallback = try std.fs.path.join(gpa, &.{ repo, "tests", "oracle", "ipmitool" });
    Io.Dir.cwd().access(io, fallback, .{}) catch return "";
    return fallback;
}

const Outcome = enum { pass, fail };

const Run = struct {
    exit: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    requests: []const u8,
    server_error: ?[]const u8,

    fn snap(r: Run) snapshot.Snapshot {
        return .{
            .exit = r.exit,
            .stdout = r.stdout,
            .stderr = r.stderr,
            .requests = r.requests,
        };
    }
};

fn runCase(
    gpa: std.mem.Allocator,
    io: Io,
    ctx: hex.Context,
    opts: Options,
    work_root: []const u8,
    c: Case,
    report: *std.ArrayList(u8),
) !Outcome {
    const snapshot_path = try std.fmt.allocPrint(gpa, "{s}/snapshots/{s}.snap", .{ opts.tests_dir, c.name });

    if (opts.candidate) |candidate| {
        const work_a = try std.fs.path.join(gpa, &.{ work_root, c.name, "a" });
        const work_b = try std.fs.path.join(gpa, &.{ work_root, c.name, "b" });
        const a = try executeCase(gpa, io, ctx, opts, work_a, c, opts.binary);
        const b = try executeCase(gpa, io, ctx, opts, work_b, c, candidate);
        var differs = false;
        var body: std.ArrayList(u8) = .empty;
        for (snapshot.Section.all) |section| {
            const expected = a.snap().get(section);
            const actual = b.snap().get(section);
            if (std.mem.eql(u8, expected, actual)) continue;
            differs = true;
            try diff.write(gpa, &body, @tagName(section), expected, actual);
        }
        if (!differs) return .pass;
        try report.print(gpa, "FAIL {s}: reference and candidate differ ({s})\n", .{ c.name, c.desc });
        try report.appendSlice(gpa, body.items);
        return .fail;
    }

    const work = try std.fs.path.join(gpa, &.{ work_root, c.name });
    const run = try executeCase(gpa, io, ctx, opts, work, c, opts.binary);

    if (run.server_error) |err| {
        try report.print(gpa, "FAIL {s}: dummy BMC error: {s}\n", .{ c.name, err });
        return .fail;
    }

    if (opts.update) {
        const text = try snapshot.render(gpa, c.name, run.snap());
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = snapshot_path, .data = text });
        return .pass;
    }

    const text = Io.Dir.cwd().readFileAlloc(io, snapshot_path, gpa, .unlimited) catch {
        try report.print(gpa,
            \\FAIL {s}: no snapshot at {s}
            \\  run with --update to create it, then review the result before committing
            \\
        , .{ c.name, snapshot_path });
        return .fail;
    };
    var diag: std.ArrayList(u8) = .empty;
    const expected = snapshot.parse(gpa, snapshot_path, text, &diag) catch {
        try report.print(gpa, "FAIL {s}: {s}\n", .{ c.name, diag.items });
        return .fail;
    };

    var body: std.ArrayList(u8) = .empty;
    var differs = false;
    for (snapshot.Section.all) |section| {
        const want = expected.get(section);
        const got = run.snap().get(section);
        if (std.mem.eql(u8, want, got)) continue;
        differs = true;
        try diff.write(gpa, &body, @tagName(section), want, got);
    }
    if (!differs) return .pass;

    try report.print(gpa, "FAIL {s}: {s}\n", .{ c.name, c.desc });
    try report.print(gpa, "  args: {s}\n", .{try joinArgs(gpa, c.args)});
    try report.appendSlice(gpa, body.items);
    return .fail;
}

fn executeCase(
    gpa: std.mem.Allocator,
    io: Io,
    ctx: hex.Context,
    opts: Options,
    work: []const u8,
    c: Case,
    binary: []const u8,
) !Run {
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, work) catch {};
    try cwd.createDirPath(io, work);

    const work_abs = try realPath(gpa, io, work);
    const sock_path = try std.fmt.allocPrint(gpa, "{s}/s", .{work_abs});
    if (sock_path.len > Io.net.UnixAddress.max_len) return error.SocketPathTooLong;

    // The IANA PEN registry is looked up in $HOME first (see
    // ipmi_oem_info_init in lib/ipmi_strings.c), which is how the harness
    // makes enterprise name lookups deterministic.
    const home = try std.fmt.allocPrint(gpa, "{s}/home", .{work_abs});
    try cwd.createDirPath(io, home);
    if (c.registry == .default) {
        const registry_dir = try std.fmt.allocPrint(gpa, "{s}/.local/usr/share/misc", .{home});
        try cwd.createDirPath(io, registry_dir);
        const src = try std.fs.path.join(gpa, &.{ ctx.fixtures_dir, "iana", "enterprise-numbers" });
        const dst = try std.fmt.allocPrint(gpa, "{s}/enterprise-numbers", .{registry_dir});
        const data = try cwd.readFileAlloc(io, src, gpa, .unlimited);
        try cwd.writeFile(io, .{ .sub_path = dst, .data = data });
    }

    for (c.blobs) |blob| {
        const dst = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ work_abs, blob.dest });
        const data = switch (blob.kind) {
            .hex => try hex.parseFile(ctx, blob.fixture),
            .text => try cwd.readFileAlloc(
                io,
                try std.fs.path.join(gpa, &.{ ctx.fixtures_dir, blob.fixture }),
                gpa,
                .unlimited,
            ),
        };
        try cwd.writeFile(io, .{ .sub_path = dst, .data = data });
    }

    var transcript = try Transcript.load(
        ctx,
        try std.fs.path.join(gpa, &.{ opts.tests_dir, "transcripts" }),
        c.transcript,
    );

    var env: std.process.Environ.Map = .init(gpa);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HOME", home);
    try env.put("TZ", "UTC");
    try env.put("LC_ALL", "C");
    try env.put("LANG", "C");
    try env.put("TERM", "dumb");
    try env.put("COLUMNS", "80");
    try env.put("IPMI_DUMMY_SOCK", sock_path);
    for (c.env) |e| try env.put(e.name, e.value);

    // ipmitool derives `progname` from basename(argv[0]) (lib/ipmi_main.c) and
    // prints it in usage and getopt errors. Invoke every binary through a
    // symlink named `ipmitool` so a differently named candidate (a wrapper
    // script, zig-out/bin/ipmitool-zig, ...) cannot produce a spurious diff.
    const bin_dir = try std.fmt.allocPrint(gpa, "{s}/bin", .{work_abs});
    try cwd.createDirPath(io, bin_dir);
    const bin_link = try std.fmt.allocPrint(gpa, "{s}/ipmitool", .{bin_dir});
    try cwd.symLink(io, try realPath(gpa, io, binary), bin_link, .{});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa, bin_link);
    for (c.args) |a| try argv.append(gpa, try expandArg(gpa, a, work_abs));

    const address = try Io.net.UnixAddress.init(sock_path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    var state: DummyBmc.State = .{ .gpa = gpa, .transcript = &transcript, .server = &server };
    var future = try io.concurrent(DummyBmc.serve, .{ io, &state });

    const result = std.process.run(gpa, io, .{
        .argv = argv.items,
        .environ_map = &env,
        .cwd = .{ .path = work_abs },
        .timeout = .{ .duration = .{
            .raw = .fromMilliseconds(c.timeout_ms),
            .clock = .awake,
        } },
    }) catch |err| {
        DummyBmc.requestShutdown(io, address);
        _ = future.await(io);
        return err;
    };
    DummyBmc.requestShutdown(io, address);
    const served = future.await(io);

    const exit_text = switch (result.term) {
        .exited => |code| try std.fmt.allocPrint(gpa, "{d}\n", .{code}),
        .signal => |sig| try std.fmt.allocPrint(gpa, "signal {t}\n", .{sig}),
        .stopped => |sig| try std.fmt.allocPrint(gpa, "stopped {t}\n", .{sig}),
        .unknown => |code| try std.fmt.allocPrint(gpa, "unknown {d}\n", .{code}),
    };

    return .{
        .exit = exit_text,
        .stdout = try normalize(gpa, result.stdout, work_abs, binary),
        .stderr = try normalize(gpa, result.stderr, work_abs, binary),
        .requests = try normalize(gpa, served.log, work_abs, binary),
        .server_error = served.err,
    };
}

fn realPath(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try Io.Dir.cwd().realPathFile(io, path, &buf);
    return gpa.dupe(u8, buf[0..len]);
}

fn expandArg(gpa: std.mem.Allocator, arg: []const u8, work_abs: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, arg, "{work}") == null) return arg;
    return std.mem.replaceOwned(u8, gpa, arg, "{work}", work_abs);
}

fn joinArgs(gpa: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (args, 0..) |a, idx| {
        if (idx != 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, a);
    }
    return out.toOwnedSlice(gpa);
}

/// Scrub the only three things that are genuinely not reproducible between two
/// runs or two machines. Everything else -- locale, time zone, the IANA PEN
/// registry, the IPMI responses -- is *controlled* instead of scrubbed, so a
/// real regression can never hide behind a normalizer.
///
///   1. the ipmitool/ipmievd version, which changes with the source tree
///   2. the absolute path of the per-case scratch directory
///   3. the absolute path of the binary under test, which differs between the
///      reference build and a candidate build in differential mode
fn normalize(gpa: std.mem.Allocator, text: []const u8, work_abs: []const u8, binary: []const u8) ![]const u8 {
    var stage = try scrubVersion(gpa, text);
    if (std.mem.indexOf(u8, stage, work_abs) != null) {
        stage = try std.mem.replaceOwned(u8, gpa, stage, work_abs, work_placeholder);
    }
    if (std.mem.indexOf(u8, stage, binary) != null) {
        stage = try std.mem.replaceOwned(u8, gpa, stage, binary, binary_placeholder);
    }
    return stage;
}

/// Replace the version token in "<progname> version 1.8.19" and nothing else.
fn scrubVersion(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    const needle = " version ";
    var out: std.ArrayList(u8) = .empty;
    var rest = text;
    var found = false;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        const line_start = if (std.mem.lastIndexOfScalar(u8, rest[0..at], '\n')) |n| n + 1 else 0;
        const progname = rest[line_start..at];
        if (!std.mem.eql(u8, progname, "ipmitool") and !std.mem.eql(u8, progname, "ipmievd")) {
            try out.appendSlice(gpa, rest[0 .. at + needle.len]);
            rest = rest[at + needle.len ..];
            continue;
        }
        found = true;
        try out.appendSlice(gpa, rest[0 .. at + needle.len]);
        rest = rest[at + needle.len ..];
        var end: usize = 0;
        while (end < rest.len and rest[end] != '\n' and rest[end] != ' ') end += 1;
        try out.appendSlice(gpa, version_placeholder);
        rest = rest[end..];
    }
    if (!found) return text;
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

fn creditCoverage(commands: []coverage.Command, cases: []const Case) void {
    for (cases) |c| {
        const is_help = c.args.len != 0 and std.mem.eql(u8, c.args[c.args.len - 1], "help");
        for (c.covers) |name| {
            for (commands) |*cmd| {
                if (!std.mem.eql(u8, cmd.name, name)) continue;
                cmd.cases += 1;
                if (is_help) cmd.help_cases += 1;
            }
        }
    }
}

fn reportCoverage(out: *Io.Writer, commands: []const coverage.Command, brief: bool) !bool {
    var covered: u32 = 0;
    var help_covered: u32 = 0;
    var missing: std.ArrayList(u8) = .empty;
    var missing_help: std.ArrayList(u8) = .empty;
    defer missing.deinit(std.heap.page_allocator);
    defer missing_help.deinit(std.heap.page_allocator);

    for (commands) |cmd| {
        if (cmd.cases != 0) covered += 1 else {
            if (missing.items.len != 0) try missing.appendSlice(std.heap.page_allocator, " ");
            try missing.appendSlice(std.heap.page_allocator, cmd.name);
        }
        if (cmd.help_cases != 0) help_covered += 1 else {
            if (missing_help.items.len != 0) try missing_help.appendSlice(std.heap.page_allocator, " ");
            try missing_help.appendSlice(std.heap.page_allocator, cmd.name);
        }
    }

    const total: u32 = @intCast(commands.len);
    try out.print("coverage: {d}/{d} commands ({d}%), {d}/{d} help paths ({d}%)\n", .{
        covered,      total, percent(covered, total),
        help_covered, total, percent(help_covered, total),
    });
    if (!brief or missing.items.len != 0) {
        if (missing.items.len != 0) try out.print("  commands with no case: {s}\n", .{missing.items});
    }
    if (!brief or missing_help.items.len != 0) {
        if (missing_help.items.len != 0) try out.print("  commands with no help case: {s}\n", .{missing_help.items});
    }
    return missing.items.len == 0 and missing_help.items.len == 0;
}

fn percent(part: u32, total: u32) u32 {
    if (total == 0) return 0;
    return part * 100 / total;
}
