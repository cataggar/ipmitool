//! Syntax-only ratchet for the C bridge in src/zig, including test oracles.
const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const Namespace = union(enum) {
    none,
    bridge,
    module: usize,
};

const Source = struct {
    path: []const u8,
    text: []const u8,
};

const File = struct {
    path: []const u8,
    tree: Ast,
    namespaces: []Namespace,
    aliases: std.StringHashMapUnmanaged(Namespace) = .empty,
    imports: usize = 0,
};

const Measurement = struct {
    path: []const u8,
    refs: usize,
    imports: usize,

    fn clean(self: Measurement) bool {
        return self.refs == 0 and self.imports == 0;
    }
};

const Entry = struct {
    path: []const u8,
    limit: usize,
};

const Violation = union(enum) {
    increase: struct { path: []const u8, actual: usize, limit: usize },
    unknown: []const u8,
    removed: []const u8,
    clean: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    const inventory = args.len == 3 and std.mem.eql(u8, args[1], "--inventory");
    if (!(args.len == 2 or inventory)) {
        std.debug.print("usage: cimport-budget [--inventory] <repository-root>\n", .{});
        std.process.exit(1);
    }
    const root = try std.Io.Dir.cwd().openDir(init.io, args[args.len - 1], .{});
    defer root.close(init.io);
    const sources = try scan(gpa, init.io, root);
    const measured = try measure(gpa, sources);
    if (inventory) {
        var buffer: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writer(init.io, &buffer);
        for (measured) |file| {
            if (!file.clean()) try out.interface.print("{d} {s}\n", .{ file.refs, file.path });
        }
        try out.interface.flush();
        return;
    }
    const text = try root.readFileAlloc(init.io, "doc/zig-migration/cimport-budget.txt", gpa, .limited(1 << 20));
    const budget = parseBudget(gpa, text) catch |err| {
        std.debug.print("cimport-budget: invalid doc/zig-migration/cimport-budget.txt: {t}\n", .{err});
        return err;
    };
    if (validate(budget, measured)) |violation| {
        switch (violation) {
            .increase => |v| std.debug.print("cimport-budget: {s}: {d} bridge references exceed budget {d}\n", .{ v.path, v.actual, v.limit }),
            .unknown => |path| std.debug.print("cimport-budget: {s}: unlisted C bridge import/reference\n", .{path}),
            .removed => |path| std.debug.print("cimport-budget: {s}: stale budget; file is missing\n", .{path}),
            .clean => |path| std.debug.print("cimport-budget: {s}: stale budget; file is now clean, remove its entry\n", .{path}),
        }
        return error.CimportBudgetViolation;
    }
    std.debug.print("cimport-budget: {d} Zig files checked, {d} budget entries\n", .{ measured.len, budget.len });
}

fn excludedComponent(part: []const u8) bool {
    for ([_][]const u8{ ".", "..", ".git", ".zig-cache", ".worktrees", "zig-out" }) |excluded| {
        if (std.mem.eql(u8, part, excluded)) return true;
    }
    return false;
}

fn validPath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "src/zig/") or !std.mem.endsWith(u8, path, ".zig")) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or excludedComponent(part)) return false;
        for (part) |byte| {
            if (std.ascii.isWhitespace(byte) or byte == '\\' or byte == 0) return false;
        }
    }
    return true;
}

fn scan(gpa: Allocator, io: std.Io, root: std.Io.Dir) ![]Source {
    const dir = try root.openDir(io, "src/zig", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var sources: std.ArrayList(Source) = .empty;
    while (try walker.next(io)) |item| {
        if (item.kind == .directory) {
            if (excludedComponent(item.basename)) walker.leave(io);
            continue;
        }
        if (!std.mem.endsWith(u8, item.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/zig/{s}", .{item.path});
        if (!validPath(path)) return error.InvalidSourcePath;
        if (item.kind != .file) return error.NonRegularZigSource;
        try sources.append(gpa, .{
            .path = path,
            .text = try item.dir.readFileAlloc(io, item.basename, gpa, .limited(16 << 20)),
        });
    }
    if (sources.items.len == 0) return error.EmptyZigTree;
    std.mem.sort(Source, sources.items, {}, struct {
        fn less(_: void, a: Source, b: Source) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    return sources.toOwnedSlice(gpa);
}

fn identifier(gpa: Allocator, tree: *const Ast, token: Ast.TokenIndex) ![]const u8 {
    const text = tree.tokenSlice(token);
    return if (std.mem.startsWith(u8, text, "@\""))
        try std.zig.string_literal.parseAlloc(gpa, text[1..])
    else
        text;
}

fn string(gpa: Allocator, tree: *const Ast, node: Ast.Node.Index) ![]const u8 {
    if (tree.nodeTag(node) != .string_literal) return error.NonLiteralImport;
    return std.zig.string_literal.parseAlloc(gpa, tree.tokenSlice(tree.nodeMainToken(node)));
}

fn same(a: Namespace, b: Namespace) bool {
    return std.meta.activeTag(a) == std.meta.activeTag(b) and
        (a != .module or a.module == b.module);
}

// Aliases are deliberately file-wide and conservative: shadowing a bridge
// alias must not hide references. Conflicting non-bridge modules are rejected.
fn join(destination: *Namespace, value: Namespace) !bool {
    if (value == .none or same(destination.*, value) or destination.* == .bridge) return false;
    if (destination.* != .none and value != .bridge) return error.AmbiguousNamespaceAlias;
    destination.* = value;
    return true;
}

fn measure(gpa: Allocator, sources: []const Source) ![]Measurement {
    const files = try gpa.alloc(File, sources.len);
    var paths: std.StringHashMapUnmanaged(usize) = .empty;
    for (sources, 0..) |source, i| {
        const text = try gpa.dupeZ(u8, source.text);
        var tree = try Ast.parse(gpa, text, .zig);
        if (tree.errors.len != 0) {
            if (!@import("builtin").is_test)
                std.debug.print("cimport-budget: {s}: malformed Zig source\n", .{source.path});
            tree.deinit(gpa);
            return error.MalformedZig;
        }
        const namespaces = try gpa.alloc(Namespace, tree.nodes.len);
        @memset(namespaces, .none);
        files[i] = .{ .path = source.path, .tree = tree, .namespaces = namespaces };
        try paths.put(gpa, source.path, i);
    }
    for (files) |*file| {
        const tree = &file.tree;
        for (0..tree.nodes.len) |n| {
            const node: Ast.Node.Index = @enumFromInt(n);
            var buffer: [2]Ast.Node.Index = undefined;
            const params = tree.builtinCallParams(&buffer, node) orelse continue;
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) continue;
            if (params.len != 1) return error.NonLiteralImport;
            const imported = try string(gpa, tree, params[0]);
            if (std.mem.eql(u8, imported, "ipmi_c")) {
                file.namespaces[n] = .bridge;
                file.imports += 1;
            } else if (std.mem.endsWith(u8, imported, ".zig")) {
                // Virtual absolute root: normalize relative Zig imports without
                // consulting the process cwd or opening files outside src/zig.
                const path = try std.fs.path.resolvePosix(gpa, &.{
                    "/", std.fs.path.dirname(file.path).?, imported,
                });
                if (paths.get(path[1..])) |i| file.namespaces[n] = .{ .module = i };
            }
        }
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (files) |*file| {
            const tree = &file.tree;
            for (0..tree.nodes.len) |n| {
                const node: Ast.Node.Index = @enumFromInt(n);
                var value: Namespace = .none;
                switch (tree.nodeTag(node)) {
                    .identifier => {
                        const name = try identifier(gpa, tree, tree.nodeMainToken(node));
                        value = file.aliases.get(name) orelse .none;
                    },
                    .grouped_expression => value = file.namespaces[@intFromEnum(tree.nodeData(node).node_and_token[0])],
                    .field_access => {
                        const data = tree.nodeData(node).node_and_token;
                        const lhs = file.namespaces[@intFromEnum(data[0])];
                        if (lhs == .module) {
                            const name = try identifier(gpa, tree, data[1]);
                            value = files[lhs.module].aliases.get(name) orelse .none;
                        }
                    },
                    else => {
                        var buffer: [2]Ast.Node.Index = undefined;
                        if (tree.builtinCallParams(&buffer, node)) |params| {
                            if (params.len == 2 and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@field")) {
                                const lhs = file.namespaces[@intFromEnum(params[0])];
                                if (lhs == .module) {
                                    const name = try string(gpa, tree, params[1]);
                                    value = files[lhs.module].aliases.get(name) orelse .none;
                                }
                            }
                        }
                    },
                }
                changed = try join(&file.namespaces[n], value) or changed;
                if (tree.fullVarDecl(node)) |decl| {
                    if (decl.ast.init_node.unwrap()) |init_node| {
                        const name = try identifier(gpa, tree, decl.ast.mut_token + 1);
                        const entry = try file.aliases.getOrPut(gpa, name);
                        if (!entry.found_existing) entry.value_ptr.* = .none;
                        changed = try join(entry.value_ptr, file.namespaces[@intFromEnum(init_node)]) or changed;
                    }
                }
            }
        }
    }
    const results = try gpa.alloc(Measurement, files.len);
    for (files, 0..) |*file, i| {
        var refs: usize = 0;
        const tree = &file.tree;
        for (0..tree.nodes.len) |n| {
            const node: Ast.Node.Index = @enumFromInt(n);
            if (tree.nodeTag(node) == .field_access) {
                const lhs = file.namespaces[@intFromEnum(tree.nodeData(node).node_and_token[0])];
                if (lhs == .bridge or file.namespaces[n] == .bridge) refs += 1;
            } else {
                var buffer: [2]Ast.Node.Index = undefined;
                if (tree.builtinCallParams(&buffer, node)) |params| {
                    if (params.len == 2 and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@field") and
                        (file.namespaces[@intFromEnum(params[0])] == .bridge or file.namespaces[n] == .bridge))
                        refs += 1;
                }
            }
        }
        results[i] = .{ .path = file.path, .refs = refs, .imports = file.imports };
    }
    return results;
}

fn parseBudget(gpa: Allocator, text: []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidBudgetEntry;
        const number = line[0..space];
        if (number.len == 0) return error.InvalidBudgetEntry;
        for (number) |byte| {
            if (!std.ascii.isDigit(byte)) return error.InvalidBudgetEntry;
        }
        const count = std.fmt.parseInt(usize, number, 10) catch return error.InvalidBudgetEntry;
        const path = line[space + 1 ..];
        if (!validPath(path)) return error.InvalidBudgetPath;
        const entry = try seen.getOrPut(gpa, path);
        if (entry.found_existing) return error.DuplicateBudgetEntry;
        try entries.append(gpa, .{ .path = path, .limit = count });
    }
    return entries.toOwnedSlice(gpa);
}

fn validate(budget: []const Entry, measured: []const Measurement) ?Violation {
    for (measured) |file| {
        var listed = false;
        for (budget) |entry| {
            if (!std.mem.eql(u8, entry.path, file.path)) continue;
            listed = true;
            if (file.clean()) return .{ .clean = file.path };
            if (file.refs > entry.limit) return .{ .increase = .{
                .path = file.path,
                .actual = file.refs,
                .limit = entry.limit,
            } };
            break;
        }
        if (!listed and !file.clean()) return .{ .unknown = file.path };
    }
    for (budget) |entry| {
        var found = false;
        for (measured) |file| {
            if (std.mem.eql(u8, entry.path, file.path)) {
                found = true;
                break;
            }
        }
        if (!found) return .{ .removed = entry.path };
    }
    return null;
}

test "qualified bridge references include types constants tests and direct imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const measured = try measure(arena.allocator(), &.{.{
        .path = "src/zig/example.zig",
        .text =
        \\const libc = @import("ipmi_c");
        \\const T = libc.FILE;
        \\const value = libc.EINVAL;
        \\test "oracle" { _ = libc.printf("oracle"); }
        \\comptime { _ = @import("ipmi_c").printf; }
        ,
    }});
    try std.testing.expectEqual(4, measured[0].refs);
    try std.testing.expectEqual(2, measured[0].imports);
}

test "comments strings and unrelated fields do not consume budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const measured = try measure(arena.allocator(), &.{.{
        .path = "src/zig/example.zig",
        .text =
        \\//! c.printf and @import("ipmi_c")
        \\/// libc.printf
        \\const text = "c.printf @import(\"ipmi_c\")";
        \\const multi =
        \\    \\c.printf @import("ipmi_c")
        \\;
        \\// const c = @import("ipmi_c"); c.printf("decoy");
        \\const object = .{ .c = 1 };
        \\const value = object.c;
        ,
    }});
    try std.testing.expect(measured[0].clean());
}

test "renamed escaped chained and parenthesized aliases cannot hide calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const measured = try measure(arena.allocator(), &.{.{
        .path = "src/zig/example.zig",
        .text =
        \\const @"lib\x63" = @import("ipmi\x5fc");
        \\const other = (libc);
        \\test "renamed oracle" {
        \\    _ = other.@"printf"("one");
        \\    _ = @field(other, "printf")("two");
        \\}
        ,
    }});
    try std.testing.expectEqual(2, measured[0].refs);
    try std.testing.expectEqual(1, measured[0].imports);
    const budget = [_]Entry{.{ .path = measured[0].path, .limit = 1 }};
    try std.testing.expect(validate(&budget, measured).? == .increase);
}

test "relative reexports and aliases count across files independently of ordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const measured = try measure(arena.allocator(), &.{
        .{
            .path = "src/zig/sub/consumer.zig",
            .text =
            \\const api = @import(".././common.zig");
            \\const renamed = api.bridge;
            \\test "oracle" { _ = renamed.printf(""); _ = api.bridge.FILE; }
            ,
        },
        .{ .path = "src/zig/common.zig", .text = "pub const bridge = @import(\"ipmi_c\");" },
    });
    try std.testing.expectEqual(4, measured[0].refs);
    try std.testing.expectEqual(0, measured[0].imports);
    try std.testing.expectEqual(0, measured[1].refs);
    try std.testing.expectEqual(1, measured[1].imports);
    try std.testing.expect(validate(&.{.{ .path = measured[1].path, .limit = 0 }}, measured).? == .unknown);
}

test "budget accepts unchanged and reduced counts and rejects deliberate extra call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const budget = try parseBudget(gpa, "1 src/zig/example.zig\n");
    for ([_][]const u8{
        "const c = @import(\"ipmi_c\"); comptime { _ = c.printf; }",
        "const c = @import(\"ipmi_c\");",
    }) |text| {
        const measured = try measure(gpa, &.{.{ .path = budget[0].path, .text = text }});
        try std.testing.expect(validate(budget, measured) == null);
    }
    const added = try measure(gpa, &.{.{
        .path = budget[0].path,
        .text = "const c = @import(\"ipmi_c\"); test \"extra\" { _ = c.printf(\"\"); _ = c.printf(\"\"); }",
    }});
    try std.testing.expect(validate(budget, added).? == .increase);
}

test "unknown imports even without references and stale removed or clean entries fail" {
    const imported = [_]Measurement{.{ .path = "src/zig/new.zig", .refs = 0, .imports = 1 }};
    try std.testing.expect(validate(&.{}, &imported).? == .unknown);
    const entry = [_]Entry{.{ .path = imported[0].path, .limit = 0 }};
    try std.testing.expect(validate(&entry, &imported) == null);
    try std.testing.expect(validate(&entry, &.{}).? == .removed);
    try std.testing.expect(validate(&entry, &.{.{
        .path = entry[0].path,
        .refs = 0,
        .imports = 0,
    }}).? == .clean);
    try std.testing.expect(validate(&.{}, &.{.{
        .path = "src/zig/clean.zig",
        .refs = 0,
        .imports = 0,
    }}) == null);
}

test "duplicate invalid overflow and noncanonical budget entries fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectError(error.DuplicateBudgetEntry, parseBudget(gpa, "1 src/zig/a.zig\n2 src/zig/a.zig\n"));
    for ([_][]const u8{
        "-1 src/zig/a.zig", "+1 src/zig/a.zig",                            "x src/zig/a.zig", "1",
        " src/zig/a.zig",   "99999999999999999999999999999 src/zig/a.zig",
    }) |text| try std.testing.expectError(error.InvalidBudgetEntry, parseBudget(gpa, text));
    for ([_][]const u8{
        "1  src/zig/a.zig",           "1 /src/zig/a.zig",           "1 src/zig/../a.zig",
        "1 src/zig//a.zig",           "1 src/zig/a.zig extra",      "1 src/zig/a.c",
        "1 src/zig/.worktrees/a.zig", "1 src/zig/.zig-cache/a.zig", "1 src/zig/zig-out/a.zig",
        "1 src/zig/a.zig\r",
    }) |text| try std.testing.expectError(error.InvalidBudgetPath, parseBudget(gpa, text));
}

test "malformed Zig and computed imports fail closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "const c = @import(\"ipmi_c\"", "const s = \"unterminated", "const c = ;", "const a = \x00;" }) |text| {
        try std.testing.expectError(error.MalformedZig, measure(arena.allocator(), &.{.{
            .path = "src/zig/bad.zig",
            .text = text,
        }}));
    }
    try std.testing.expectError(error.NonLiteralImport, measure(arena.allocator(), &.{.{
        .path = "src/zig/bad.zig",
        .text = "const name = \"ipmi_c\"; const c = @import(name);",
    }}));
}

test "scope shadowing cannot conceal a bridge alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const measured = try measure(arena.allocator(), &.{.{
        .path = "src/zig/example.zig",
        .text =
        \\const c = @import("ipmi_c");
        \\test "shadow" { const c = .{ .printf = 0 }; _ = c.printf; }
        \\test "oracle" { _ = c.printf(""); }
        ,
    }});
    try std.testing.expectEqual(2, measured[0].refs);
}

test "ordinary hidden sources are not confused with excluded cache or worktree paths" {
    try std.testing.expect(validPath("src/zig/.hidden.zig"));
    try std.testing.expect(validPath("src/zig/.private/oracle.zig"));
    for ([_][]const u8{ ".git", ".zig-cache", ".worktrees", "zig-out" }) |part| {
        try std.testing.expect(excludedComponent(part));
    }
}

test "conflicting module aliases fail closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.AmbiguousNamespaceAlias, measure(arena.allocator(), &.{
        .{
            .path = "src/zig/example.zig",
            .text =
            \\const api = @import("a.zig");
            \\test "shadow" { const api = @import("b.zig"); _ = api; }
            ,
        },
        .{ .path = "src/zig/a.zig", .text = "" },
        .{ .path = "src/zig/b.zig", .text = "" },
    }));
}
