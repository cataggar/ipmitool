//! Syntax-only ratchet for the C bridge in src/zig, including test oracles.
const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const Namespace = union(enum) {
    none,
    standard,
    bridge,
    module: usize,
    container: struct { file: usize, node: Ast.Node.Index },
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
    this_targets: std.ArrayList(struct { node: Ast.Node.Index, container: Ast.Node.Index }) = .empty,
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
        switch (a) {
            .module => a.module == b.module,
            .container => std.meta.eql(a.container, b.container),
            else => true,
        };
}

// Aliases are deliberately file-wide and conservative: shadowing a bridge
// alias must not hide references. Conflicting non-bridge modules are rejected.
fn join(destination: *Namespace, value: Namespace) !bool {
    if (value == .none or same(destination.*, value) or destination.* == .bridge) return false;
    if (value == .standard and destination.* != .none) return false;
    if (destination.* != .none and destination.* != .standard and value != .bridge) return error.AmbiguousNamespaceAlias;
    destination.* = value;
    return true;
}

fn memberNamespace(gpa: Allocator, files: []const File, namespace: Namespace, name: []const u8) !Namespace {
    switch (namespace) {
        .module => |i| return files[i].aliases.get(name) orelse .none,
        .container => |container| {
            const file = &files[container.file];
            var buffer: [2]Ast.Node.Index = undefined;
            for (file.tree.fullContainerDecl(&buffer, container.node).?.ast.members) |member| {
                const decl = file.tree.fullVarDecl(member) orelse continue;
                const member_name = try identifier(gpa, &file.tree, decl.ast.mut_token + 1);
                if (!std.mem.eql(u8, name, member_name)) continue;
                if (decl.ast.init_node.unwrap()) |init_node|
                    return file.namespaces[@intFromEnum(init_node)];
            }
            return .none;
        },
        else => return .none,
    }
}

fn reachesBridge(files: []const File, namespace: Namespace, visited: []bool) bool {
    const index = switch (namespace) {
        .bridge => return true,
        .module => |index| index,
        .container => |container| container.file,
        .none, .standard => return false,
    };
    if (visited[index]) return false;
    visited[index] = true;
    if (files[index].imports != 0) return true;
    for (files[index].namespaces) |dependency| {
        if (reachesBridge(files, dependency, visited)) return true;
    }
    return false;
}

fn isRefAllDecls(gpa: Allocator, file: *const File, node: Ast.Node.Index) !bool {
    const tree = &file.tree;
    if (tree.nodeTag(node) != .field_access) return false;
    const function = tree.nodeData(node).node_and_token;
    const name = tree.tokenSlice(function[1]);
    if (!std.mem.eql(u8, name, "refAllDecls") and !std.mem.eql(u8, name, "refAllDeclsRecursive")) return false;
    if (tree.nodeTag(function[0]) != .field_access) return false;
    const testing = tree.nodeData(function[0]).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(testing[1]), "testing") or
        file.namespaces[@intFromEnum(testing[0])] != .standard) return false;

    // Unlike bridge taint, a trusted void-returning consumer must have exact
    // provenance. File-wide alias merging cannot bless a shadowed std name.
    const base = testing[0];
    if (tree.nodeTag(base) != .identifier)
        return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(base)), "@import");
    const base_name = try identifier(gpa, tree, tree.nodeMainToken(base));
    var found = false;
    for (0..tree.nodes.len) |n| {
        const candidate: Ast.Node.Index = @enumFromInt(n);
        var proto_buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&proto_buffer, candidate)) |proto| {
            var params = proto.iterate(tree);
            while (params.next()) |param| {
                if (param.name_token) |token| {
                    if (std.mem.eql(u8, base_name, try identifier(gpa, tree, token))) return false;
                }
            }
        }
        const decl = tree.fullVarDecl(candidate) orelse continue;
        const name_token = decl.ast.mut_token + 1;
        if (!std.mem.eql(u8, base_name, try identifier(gpa, tree, name_token))) continue;
        if (tree.tokenTag(decl.ast.mut_token) != .keyword_const) return false;
        const init_node = decl.ast.init_node.unwrap() orelse return false;
        if (file.namespaces[@intFromEnum(init_node)] != .standard or
            !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init_node)), "@import")) return false;
        found = true;
    }
    return found;
}

fn namespaceWrapperError(file: *const File, node: Ast.Node.Index) error{UnsupportedNamespaceWrapper} {
    if (!@import("builtin").is_test) {
        std.debug.print(
            "cimport-budget: {s}: unsupported namespace wrapper at byte {d}; use direct/conditional import aliases\n",
            .{ file.path, file.tree.tokenStart(file.tree.nodeMainToken(node)) },
        );
    }
    return error.UnsupportedNamespaceWrapper;
}

fn checkNamespaceUses(gpa: Allocator, file: *const File) !void {
    const tree = &file.tree;
    const consumed = try gpa.alloc(bool, tree.nodes.len);
    @memset(consumed, false);
    for (0..tree.nodes.len) |n| {
        const node: Ast.Node.Index = @enumFromInt(n);
        if (tree.fullVarDecl(node)) |decl| {
            if (decl.ast.init_node.unwrap()) |init_node| consumed[@intFromEnum(init_node)] = true;
        }
        if (tree.fullIf(node)) |conditional| {
            consumed[@intFromEnum(conditional.ast.then_expr)] = true;
            if (conditional.ast.else_expr.unwrap()) |branch| consumed[@intFromEnum(branch)] = true;
        }
        if (tree.fullSwitch(node)) |selection| {
            for (selection.ast.cases) |case| {
                const branch = tree.fullSwitchCase(case).?.ast.target_expr;
                consumed[@intFromEnum(branch)] = true;
            }
        }
        var call_buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&call_buffer, node)) |call| {
            if (try isRefAllDecls(gpa, file, call.ast.fn_expr)) {
                for (call.ast.params) |param| consumed[@intFromEnum(param)] = true;
            }
        }
        switch (tree.nodeTag(node)) {
            .field_access, .grouped_expression => consumed[@intFromEnum(tree.nodeData(node).node_and_token[0])] = true,
            .@"comptime" => consumed[@intFromEnum(tree.nodeData(node).node)] = true,
            .assign => {
                const data = tree.nodeData(node).node_and_node;
                if (tree.nodeTag(data[0]) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(data[0])), "_"))
                    consumed[@intFromEnum(data[1])] = true;
            },
            else => {},
        }
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.builtinCallParams(&buffer, node)) |params| {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            for ([_][]const u8{
                "@field",    "@as",       "@hasDecl", "@hasField", "@TypeOf",
                "@typeInfo", "@typeName", "@sizeOf",  "@alignOf",  "@offsetOf",
            }) |supported| {
                if (!std.mem.eql(u8, name, supported)) continue;
                for (params) |param| consumed[@intFromEnum(param)] = true;
                break;
            }
        }
    }
    // A namespace value may only flow through expressions analyzed above.
    // In particular, blocks, returns, ordinary call arguments and aggregates
    // must not quietly turn a tracked namespace into an untracked alias.
    for (file.namespaces, 0..) |namespace, n| {
        if (namespace != .none and namespace != .standard and !consumed[n])
            return namespaceWrapperError(file, @enumFromInt(n));
    }
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
    for (files, 0..) |*file, file_index| {
        const tree = &file.tree;
        for (0..tree.nodes.len) |n| {
            const node: Ast.Node.Index = @enumFromInt(n);
            var buffer: [2]Ast.Node.Index = undefined;
            const params = tree.builtinCallParams(&buffer, node) orelse continue;
            if (params.len == 0 and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@This")) {
                // @This follows lexical container scope, not file-wide aliases.
                const token = tree.nodeMainToken(node);
                var enclosing: Ast.Node.Index = .root;
                for (1..tree.nodes.len) |candidate_index| {
                    const candidate: Ast.Node.Index = @enumFromInt(candidate_index);
                    var container_buffer: [2]Ast.Node.Index = undefined;
                    if (tree.fullContainerDecl(&container_buffer, candidate) == null) continue;
                    if (tree.firstToken(candidate) <= token and tree.lastToken(candidate) >= token and
                        (enclosing == .root or tree.firstToken(candidate) > tree.firstToken(enclosing)))
                        enclosing = candidate;
                }
                if (enclosing == .root) {
                    file.namespaces[n] = .{ .module = file_index };
                } else {
                    try file.this_targets.append(gpa, .{ .node = node, .container = enclosing });
                }
                continue;
            }
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) continue;
            if (params.len != 1) return error.NonLiteralImport;
            const imported = try string(gpa, tree, params[0]);
            if (std.mem.eql(u8, imported, "ipmi_c")) {
                file.namespaces[n] = .bridge;
                file.imports += 1;
            } else if (std.mem.eql(u8, imported, "std")) {
                file.namespaces[n] = .standard;
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
        for (files, 0..) |*file, file_index| {
            const tree = &file.tree;
            for (file.this_targets.items) |target|
                changed = try join(&file.namespaces[@intFromEnum(target.node)], file.namespaces[@intFromEnum(target.container)]) or changed;
            for (0..tree.nodes.len) |n| {
                const node: Ast.Node.Index = @enumFromInt(n);
                var value: Namespace = .none;
                switch (tree.nodeTag(node)) {
                    .identifier => {
                        const name = try identifier(gpa, tree, tree.nodeMainToken(node));
                        value = file.aliases.get(name) orelse .none;
                    },
                    .grouped_expression => value = file.namespaces[@intFromEnum(tree.nodeData(node).node_and_token[0])],
                    .@"comptime" => value = file.namespaces[@intFromEnum(tree.nodeData(node).node)],
                    .if_simple, .@"if" => {
                        const conditional = tree.fullIf(node).?;
                        const then_namespace = file.namespaces[@intFromEnum(conditional.ast.then_expr)];
                        _ = try join(&value, then_namespace);
                        var all_standard = then_namespace == .standard;
                        if (conditional.ast.else_expr.unwrap()) |branch| {
                            const else_namespace = file.namespaces[@intFromEnum(branch)];
                            _ = try join(&value, else_namespace);
                            all_standard = all_standard and else_namespace == .standard;
                        } else {
                            all_standard = false;
                        }
                        if (value == .standard and !all_standard) value = .none;
                    },
                    .@"switch", .switch_comma => {
                        var all_standard = true;
                        for (tree.fullSwitch(node).?.ast.cases) |case| {
                            const branch = tree.fullSwitchCase(case).?.ast.target_expr;
                            const namespace = file.namespaces[@intFromEnum(branch)];
                            _ = try join(&value, namespace);
                            all_standard = all_standard and namespace == .standard;
                        }
                        if (value == .standard and !all_standard) value = .none;
                    },
                    .field_access => {
                        const data = tree.nodeData(node).node_and_token;
                        const lhs = file.namespaces[@intFromEnum(data[0])];
                        if (lhs == .module or lhs == .container) {
                            const name = try identifier(gpa, tree, data[1]);
                            value = try memberNamespace(gpa, files, lhs, name);
                        }
                    },
                    else => {
                        var buffer: [2]Ast.Node.Index = undefined;
                        if (tree.builtinCallParams(&buffer, node)) |params| {
                            if (params.len == 2 and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@as"))
                                value = file.namespaces[@intFromEnum(params[1])];
                            if (params.len == 2 and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@field")) {
                                const lhs = file.namespaces[@intFromEnum(params[0])];
                                if ((lhs == .module or lhs == .container) and tree.nodeTag(params[1]) == .string_literal) {
                                    const name = try string(gpa, tree, params[1]);
                                    value = try memberNamespace(gpa, files, lhs, name);
                                }
                            }
                        }
                        var container_buffer: [2]Ast.Node.Index = undefined;
                        if (node != .root) {
                            if (tree.fullContainerDecl(&container_buffer, node)) |container| {
                                for (container.ast.members) |member| {
                                    const decl = tree.fullVarDecl(member) orelse continue;
                                    if (decl.ast.init_node.unwrap()) |init_node| {
                                        const namespace = file.namespaces[@intFromEnum(init_node)];
                                        if (namespace != .none and namespace != .standard) {
                                            value = .{ .container = .{ .file = file_index, .node = node } };
                                            break;
                                        }
                                    }
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
        const visited = try gpa.alloc(bool, files.len);
        for (0..file.tree.nodes.len) |n| {
            const node: Ast.Node.Index = @enumFromInt(n);
            var buffer: [2]Ast.Node.Index = undefined;
            const params = file.tree.builtinCallParams(&buffer, node) orelse continue;
            if (params.len != 2 or
                !std.mem.eql(u8, file.tree.tokenSlice(file.tree.nodeMainToken(node)), "@field") or
                file.tree.nodeTag(params[1]) == .string_literal) continue;
            const lhs = file.namespaces[@intFromEnum(params[0])];
            if (lhs != .module and lhs != .container) continue;
            @memset(visited, false);
            if (reachesBridge(files, lhs, visited)) return namespaceWrapperError(file, node);
        }
        try checkNamespaceUses(gpa, file);
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

test "conditional namespace aliases cannot hide qualified references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "if (@import(\"builtin\").is_test) @import(\"ipmi_c\") else @import(\"ipmi_c\")",
        "if (true) @import(\"std\") else @import(\"ipmi_c\")",
        "if (false) @import(\"ipmi_c\") else @import(\"std\")",
        "switch (@import(\"builtin\").is_test) { true => @import(\"ipmi_c\"), false => @import(\"ipmi_c\") }",
        "switch (0) { 0 => @import(\"std\"), else => @import(\"ipmi_c\") }",
        "switch (0) { 0 => @import(\"ipmi_c\"), else => @import(\"std\") }",
        "if (true) (switch (0) { 0 => @import(\"std\"), else => @import(\"ipmi_c\") }) else @import(\"std\")",
        "@as(type, @import(\"ipmi_c\"))",
        "comptime @import(\"ipmi_c\")",
    }) |expression| {
        const text = try std.fmt.allocPrint(arena.allocator(), "const api = {s}; pub fn f() void {{ _ = api.printf(\"x\"); }}", .{expression});
        const measured = try measure(arena.allocator(), &.{.{
            .path = "src/zig/example.zig",
            .text = text,
        }});
        try std.testing.expectEqual(1, measured[0].refs);
        try std.testing.expect(validate(&.{.{ .path = measured[0].path, .limit = 0 }}, measured).? == .increase);
    }
}

test "unsupported namespace-producing blocks functions and containers fail closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "const api = scope: { break :scope @import(\"ipmi_c\"); };",
        "const api = scope: { if (true) break :scope @import(\"ipmi_c\"); break :scope @import(\"std\"); };",
        "fn bridge() type { return @import(\"ipmi_c\"); } const api = bridge();",
        "const c = @import(\"ipmi_c\"); fn bridge() type { return if (true) c else c; } const api = bridge();",
        "fn identity(comptime T: type) type { return T; } const api = identity(@import(\"ipmi_c\"));",
        "const apis = [_]type{ @import(\"ipmi_c\") }; const api = apis[0];",
        "const api = @import(\"std\").meta.Child(*@import(\"ipmi_c\"));",
        "fn wrapped() type { return struct { pub const api = @import(\"ipmi_c\"); }; } const api = wrapped().api;",
    }) |prefix| {
        const text = try std.fmt.allocPrint(arena.allocator(), "{s} pub fn f() void {{ _ = api.printf(\"x\"); }}", .{prefix});
        try std.testing.expectError(error.UnsupportedNamespaceWrapper, measure(arena.allocator(), &.{.{
            .path = "src/zig/example.zig",
            .text = text,
        }}));
    }
}

test "container and This namespace aliases preserve bridge references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "const wrapped = struct { pub const bridge = @import(\"ipmi_c\"); }; const api = wrapped.bridge;",
        "const c = @import(\"ipmi_c\"); const api = @This().c;",
        "const c = @import(\"ipmi_c\"); const self = @This(); const api = self.c;",
        "const wrapped = struct { pub const bridge = @import(\"ipmi_c\"); pub const self = @This(); }; const api = wrapped.self.bridge;",
    }) |prefix| {
        const text = try std.fmt.allocPrint(arena.allocator(), "{s} pub fn f() void {{ _ = api.printf(\"x\"); }}", .{prefix});
        const measured = try measure(arena.allocator(), &.{.{
            .path = "src/zig/example.zig",
            .text = text,
        }});
        try std.testing.expectEqual(2, measured[0].refs);
        try std.testing.expect(validate(&.{.{ .path = measured[0].path, .limit = 1 }}, measured).? == .increase);
    }
}

test "metadata inspection and real standard refAllDecls remain allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const measured = try measure(arena.allocator(), &.{.{
        .path = "src/zig/example.zig",
        .text =
        \\const actual = @import("std");
        \\const c = @import("ipmi_c");
        \\comptime {
        \\    _ = @hasDecl(c, "printf");
        \\    _ = @typeInfo(c);
        \\    _ = @TypeOf(c);
        \\    _ = c;
        \\    actual.testing.refAllDecls(c);
        \\    actual.testing.refAllDeclsRecursive(@This());
        \\}
        ,
    }});
    try std.testing.expectEqual(0, measured[0].refs);
    try std.testing.expectEqual(1, measured[0].imports);
}

test "refAllDecls lookalikes and mixed standard aliases cannot hide namespaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "fake",
        "if (false) @import(\"std\") else fake",
        "switch (false) { true => @import(\"std\"), false => fake }",
    }) |expression| {
        const text = try std.fmt.allocPrint(arena.allocator(),
            \\const fake = struct {{
            \\    pub const testing = struct {{
            \\        pub fn refAllDecls(comptime T: type) type {{ return T; }}
            \\    }};
            \\}};
            \\const meta = {s};
            \\const api = meta.testing.refAllDecls(@import("ipmi_c"));
            \\pub fn f() void {{ _ = api.printf("x"); }}
        , .{expression});
        try std.testing.expectError(error.UnsupportedNamespaceWrapper, measure(arena.allocator(), &.{.{
            .path = "src/zig/example.zig",
            .text = text,
        }}));
    }
    try std.testing.expectError(error.UnsupportedNamespaceWrapper, measure(arena.allocator(), &.{.{
        .path = "src/zig/example.zig",
        .text =
        \\const actual = @import("std");
        \\const wrapped = struct {
        \\    const actual = struct {
        \\        pub const testing = struct {
        \\            pub fn refAllDecls(comptime T: type) type { return T; }
        \\        };
        \\    };
        \\    const c = @import("ipmi_c");
        \\    pub const api = actual.testing.refAllDecls(c);
        \\};
        \\pub fn f() void { _ = wrapped.api.printf("x"); }
        ,
    }}));
}

test "mutable and parameter-shadowed standard aliases are not trusted consumers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        \\const actual = @import("std");
        \\const fake = struct { pub const testing = struct {
        \\    pub fn refAllDecls(comptime T: type) type { return T; }
        \\}; };
        \\fn bridge(comptime actual: type) type {
        \\    return actual.testing.refAllDecls(@import("ipmi_c"));
        \\}
        \\const api = bridge(fake);
        \\pub fn f() void { _ = api.printf("x"); }
        ,
        \\const fake = struct { pub const testing = struct {
        \\    pub fn refAllDecls(comptime T: type) type { return T; }
        \\}; };
        \\fn bridge() type {
        \\    comptime var actual: type = @import("std");
        \\    actual = fake;
        \\    return actual.testing.refAllDecls(@import("ipmi_c"));
        \\}
        \\const api = bridge();
        \\pub fn f() void { _ = api.printf("x"); }
        ,
    }) |text| {
        try std.testing.expectError(error.UnsupportedNamespaceWrapper, measure(arena.allocator(), &.{.{
            .path = "src/zig/example.zig",
            .text = text,
        }}));
    }
}

test "conditional relative module aliases retain reexported bridge namespaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const measured = try measure(arena.allocator(), &.{
        .{
            .path = "src/zig/consumer.zig",
            .text =
            \\const selected = if (@import("builtin").is_test) @import("provider.zig") else @import("provider.zig");
            \\const api = selected.bridge;
            \\pub fn f() void { _ = api.printf("x"); }
            ,
        },
        .{
            .path = "src/zig/provider.zig",
            .text = "pub const bridge = if (true) @import(\"ipmi_c\") else @import(\"ipmi_c\");",
        },
    });
    try std.testing.expectEqual(2, measured[0].refs);
    try std.testing.expectEqual(0, measured[0].imports);
    try std.testing.expect(validate(&.{.{ .path = measured[0].path, .limit = 1 }}, measured).? == .increase);
}

test "namespace-returning functions in another scanned file fail closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedNamespaceWrapper, measure(arena.allocator(), &.{
        .{
            .path = "src/zig/consumer.zig",
            .text =
            \\const api = @import("provider.zig").bridge();
            \\pub fn f() void { _ = api.printf("x"); }
            ,
        },
        .{
            .path = "src/zig/provider.zig",
            .text = "pub fn bridge() type { return @import(\"ipmi_c\"); }",
        },
    }));
}

test "computed fields in bridge-free relative modules remain valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const measured = try measure(arena.allocator(), &.{
        .{
            .path = "src/zig/consumer.zig",
            .text =
            \\const tables = @import("tables.zig");
            \\pub fn value(comptime name: []const u8) u32 { return @field(tables, name); }
            ,
        },
        .{
            .path = "src/zig/tables.zig",
            .text = "const types = @import(\"types.zig\"); pub const code: u32 = 1;",
        },
        .{
            .path = "src/zig/types.zig",
            .text = "const tables = @import(\"tables.zig\"); pub const Value = u32;",
        },
    });
    for (measured) |file| try std.testing.expect(file.clean());
}

test "computed relative module fields cannot conceal reachable bridges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "pub const api = @import(\"ipmi_c\");",
        "pub const nested = @import(\"nested.zig\");",
        "pub const wrapper = struct { pub const api = @import(\"ipmi_c\"); };",
    }) |provider| {
        try std.testing.expectError(error.UnsupportedNamespaceWrapper, measure(arena.allocator(), &.{
            .{
                .path = "src/zig/consumer.zig",
                .text =
                \\const provider = @import("provider.zig");
                \\const name = "api";
                \\const api = @field(provider, name);
                \\pub fn f() void { _ = api.printf("x"); }
                ,
            },
            .{ .path = "src/zig/provider.zig", .text = provider },
            .{ .path = "src/zig/nested.zig", .text = "pub const api = @import(\"ipmi_c\");" },
        }));
    }
}
