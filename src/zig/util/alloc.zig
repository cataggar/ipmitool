//! Ownership-specific defaults, not a process-wide command arena.
const std = @import("std");

/// Only for objects whose C ABI owner calls free/realloc. Do not return memory
/// from private or scratch allocators through those existing ownership APIs.
pub const c_owned = std.heap.c_allocator;
/// Private Zig state must be freed with the same allocator that created it.
pub const private = std.heap.page_allocator;
pub const command_failure: c_int = -1;

/// Optional scratch for borrowed data confined to one synchronous dispatch.
/// The caller owns this root and supplies the backing allocator explicitly.
pub const CommandScratch = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator) CommandScratch {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn allocator(self: *CommandScratch) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *CommandScratch) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

test "command scratch releases allocations and propagates OOM" {
    var scratch = CommandScratch.init(std.testing.allocator);
    defer scratch.deinit();
    const word = try scratch.allocator().dupeZ(u8, "command");
    try std.testing.expectEqualStrings("command", word);

    var failing = CommandScratch.init(std.testing.failing_allocator);
    defer failing.deinit();
    try std.testing.expectError(error.OutOfMemory, failing.allocator().alloc(u8, 1));
    try std.testing.expectEqual(@as(c_int, -1), command_failure);
}
