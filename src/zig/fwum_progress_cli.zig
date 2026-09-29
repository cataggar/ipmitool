const std = @import("std");
const c = @import("ipmi_c");
const fwum = @import("cmd/fwum.zig");
const stdout_io = @import("util/stdout.zig");

pub fn main() !void {
    var previous: c_ulong = std.math.maxInt(c_ulong);
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    if (c.fputs("before|", c.stdout) < 0) return error.COutputFailed;
    try fwum.emitProgress(&stdout.interface, stdout_io.trySyncC, "Read", 0, 100, &previous);
    try fwum.emitProgress(&stdout.interface, stdout_io.trySyncC, "Duplicate", 0, 100, &previous);
    try fwum.emitProgress(&stdout.interface, stdout_io.trySyncC, "Zero total", 0, 0, &previous);
    try fwum.emitProgress(&stdout.interface, stdout_io.trySyncC, "Partial", 1, 3, &previous);
    try fwum.emitProgress(&stdout.interface, stdout_io.trySyncC, "Hi\x00ignored", 1, 2, &previous);
    try fwum.emitProgress(&stdout.interface, stdout_io.trySyncC, "Done", std.math.maxInt(c_ulong), std.math.maxInt(c_ulong), &previous);
    if (c.fputs("after\n", c.stdout) < 0) return error.COutputFailed;
    try stdout_io.trySyncC();
}
