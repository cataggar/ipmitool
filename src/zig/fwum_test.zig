//! Standalone FWUM safety tests; the module root stays inside src/zig so
//! cmd/fwum.zig can import the usual core and ABI modules unchanged.
test {
    _ = @import("cmd/fwum.zig");
}
