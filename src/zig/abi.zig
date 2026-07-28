//! Comptime ABI parity assertions between the Zig header ports and C.
//!
//! Every `extern struct` under `core/`, `intf/` and `util/` mirrors a C
//! declaration in `include/ipmitool/`.  Nothing enforces that by itself, so
//! each mirror ends with a `comptime` block that calls into this file.  The
//! assertions run whenever the module is compiled, which means a header change
//! that is not reflected in the Zig port is a build failure rather than silent
//! memory corruption at run time.
//!
//! Two flavours exist because `translate-c` demotes any struct containing a
//! bitfield to `opaque {}`:
//!
//!   * `assertLayout` compares a mirror against the `@cImport`ed type directly
//!     and needs no maintenance: it walks the mirror's fields and checks size,
//!     alignment and every field offset.  Use it whenever you can.
//!   * `assertOpaqueLayout` compares a mirror against the constants exported by
//!     `src/zig/abi_layout.h`.  Use it only for opaque C types.
//!
//! All numbers on both sides are produced for the *target*, so the assertions
//! stay correct when cross compiling and under either `HAVE_PRAGMA_PACK`
//! setting.  See doc/zig-migration/interop-seams.md.

const std = @import("std");

/// One `name = offset` expectation for `assertOpaqueLayout`.
///
/// `name` may be a dotted path (`"msg.cmd"`), matching the C member designator
/// used in `abi_layout.h`.
pub const FieldOffset = struct {
    name: []const u8,
    offset: comptime_int,
};

/// Layout of a C type that `translate-c` could not represent, as read from
/// `src/zig/abi_layout.h`.
pub const OpaqueLayout = struct {
    size: comptime_int,
    alignment: comptime_int,
    fields: []const FieldOffset,
};

/// Assert that `Mirror` has exactly the layout the C compiler gave `CType`.
///
/// `CType` comes from the `ipmi_c` bridge module.  Field names must match the C
/// names one for one; a mirror that adds, drops or renames a field fails here.
pub fn assertLayout(comptime Mirror: type, comptime CType: type) void {
    comptime {
        const mirror_fields = structFields(Mirror);
        const c_fields = structFields(CType);

        if (@sizeOf(Mirror) != @sizeOf(CType)) @compileError(std.fmt.comptimePrint(
            "ABI drift: @sizeOf({s}) is {d}, C says {d}",
            .{ @typeName(Mirror), @sizeOf(Mirror), @sizeOf(CType) },
        ));
        if (@alignOf(Mirror) != @alignOf(CType)) @compileError(std.fmt.comptimePrint(
            "ABI drift: @alignOf({s}) is {d}, C says {d}",
            .{ @typeName(Mirror), @alignOf(Mirror), @alignOf(CType) },
        ));
        if (mirror_fields.len != c_fields.len) @compileError(std.fmt.comptimePrint(
            "ABI drift: {s} has {d} fields, C has {d}",
            .{ @typeName(Mirror), mirror_fields.len, c_fields.len },
        ));

        for (mirror_fields, c_fields) |mirror_field, c_field| {
            if (!std.mem.eql(u8, mirror_field.name, c_field.name)) {
                @compileError(std.fmt.comptimePrint(
                    "ABI drift: {s} field '{s}' is named '{s}' in C",
                    .{ @typeName(Mirror), mirror_field.name, c_field.name },
                ));
            }

            const mirror_offset = fieldOffset(Mirror, mirror_field.name);
            const c_offset = fieldOffset(CType, c_field.name);
            if (mirror_offset != c_offset) @compileError(std.fmt.comptimePrint(
                "ABI drift: @offsetOf({s}, \"{s}\") is {d}, C says {d}",
                .{ @typeName(Mirror), mirror_field.name, mirror_offset, c_offset },
            ));

            // An opaque C field means the parent would be opaque too, so this
            // only guards against a bridge that changed under our feet.
            if (@typeInfo(c_field.type) == .@"opaque") continue;

            if (@sizeOf(mirror_field.type) != @sizeOf(c_field.type)) {
                @compileError(std.fmt.comptimePrint(
                    "ABI drift: @sizeOf({s}.{s}) is {d}, C says {d}",
                    .{
                        @typeName(Mirror),
                        mirror_field.name,
                        @sizeOf(mirror_field.type),
                        @sizeOf(c_field.type),
                    },
                ));
            }
            if (@alignOf(mirror_field.type) != @alignOf(c_field.type)) {
                @compileError(std.fmt.comptimePrint(
                    "ABI drift: @alignOf({s}.{s}) is {d}, C says {d}",
                    .{
                        @typeName(Mirror),
                        mirror_field.name,
                        @alignOf(mirror_field.type),
                        @alignOf(c_field.type),
                    },
                ));
            }
        }
    }
}

/// Assert that `Mirror` matches the `ABI_*` constants from `abi_layout.h`.
///
/// Used for C types `translate-c` demoted to `opaque {}`; the caller passes the
/// bridge constants so the numbers still come from the C compiler.
pub fn assertOpaqueLayout(comptime Mirror: type, comptime layout: OpaqueLayout) void {
    comptime {
        if (@sizeOf(Mirror) != layout.size) @compileError(std.fmt.comptimePrint(
            "ABI drift: @sizeOf({s}) is {d}, C says {d}",
            .{ @typeName(Mirror), @sizeOf(Mirror), layout.size },
        ));
        if (@alignOf(Mirror) != layout.alignment) @compileError(std.fmt.comptimePrint(
            "ABI drift: @alignOf({s}) is {d}, C says {d}",
            .{ @typeName(Mirror), @alignOf(Mirror), layout.alignment },
        ));
        for (layout.fields) |field| {
            const mirror_offset = offsetOfPath(Mirror, field.name);
            if (mirror_offset != field.offset) @compileError(std.fmt.comptimePrint(
                "ABI drift: offset of {s}.{s} is {d}, C says {d}",
                .{ @typeName(Mirror), field.name, mirror_offset, field.offset },
            ));
        }
    }
}

/// Assert that a Zig replacement function is ABI-compatible with the C function
/// it is exported as.
///
/// This is the C -> Zig half of the bridge: a ported module is only a link-time
/// drop-in if the calling convention, the argument count and the machine
/// representation of every argument and of the result match the original
/// declaration.  Zig and `translate-c` spell the pointer types differently
/// (`*Intf` versus `[*c]struct_ipmi_intf`), so the comparison is by size and
/// alignment rather than by type identity.
pub fn assertCallSignature(comptime Ported: type, comptime Original: type) void {
    comptime {
        const ported = @typeInfo(Ported).@"fn";
        const original = @typeInfo(Original).@"fn";

        const Tag = std.builtin.CallingConvention.Tag;
        if (@as(Tag, ported.calling_convention) != @as(Tag, original.calling_convention)) {
            @compileError(std.fmt.comptimePrint(
                "ABI drift: {s} uses calling convention {s}, C uses {s}",
                .{
                    @typeName(Ported),
                    @tagName(@as(Tag, ported.calling_convention)),
                    @tagName(@as(Tag, original.calling_convention)),
                },
            ));
        }
        if (ported.is_var_args != original.is_var_args) {
            @compileError("ABI drift: variadic mismatch for " ++ @typeName(Ported));
        }
        if (ported.params.len != original.params.len) {
            @compileError(std.fmt.comptimePrint(
                "ABI drift: {s} takes {d} arguments, C takes {d}",
                .{ @typeName(Ported), ported.params.len, original.params.len },
            ));
        }
        for (ported.params, original.params, 0..) |ported_param, original_param, index| {
            assertSameRepr(
                ported_param.type.?,
                original_param.type.?,
                std.fmt.comptimePrint("{s} argument {d}", .{ @typeName(Ported), index }),
            );
        }
        assertSameRepr(
            ported.return_type.?,
            original.return_type.?,
            @typeName(Ported) ++ " return value",
        );
    }
}

fn assertSameRepr(comptime Ported: type, comptime Original: type, comptime what: []const u8) void {
    comptime {
        if ((Ported == void) != (Original == void)) {
            @compileError("ABI drift: void mismatch for " ++ what);
        }
        if (Ported == void) return;
        if (@sizeOf(Ported) != @sizeOf(Original) or @alignOf(Ported) != @alignOf(Original)) {
            @compileError(std.fmt.comptimePrint(
                "ABI drift: {s} is {s} ({d}/{d}), C uses {s} ({d}/{d})",
                .{
                    what,
                    @typeName(Ported),
                    @sizeOf(Ported),
                    @alignOf(Ported),
                    @typeName(Original),
                    @sizeOf(Original),
                    @alignOf(Original),
                },
            ));
        }
    }
}

/// Byte offset of a dotted field path, e.g. `offsetOfPath(Request, "msg.cmd")`.
pub fn offsetOfPath(comptime T: type, comptime path: []const u8) comptime_int {
    comptime {
        var offset: comptime_int = 0;
        var Current = T;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |name| {
            offset += fieldOffset(Current, name);
            Current = @FieldType(Current, name);
        }
        return offset;
    }
}

/// `@offsetOf` rejects unions, where every member starts at zero anyway.
fn fieldOffset(comptime T: type, comptime name: []const u8) comptime_int {
    return switch (@typeInfo(T)) {
        .@"union" => 0,
        else => @offsetOf(T, name),
    };
}

fn structFields(comptime T: type) []const std.builtin.Type.StructField {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.fields,
        .@"union" => |info| unionFields(info.fields),
        else => @compileError("ABI assertions need a struct or union, got " ++ @typeName(T)),
    };
}

/// Presents union fields in the same shape as struct fields; every union member
/// lives at offset zero, which `@offsetOf` already reports.
fn unionFields(comptime fields: []const std.builtin.Type.UnionField) []const std.builtin.Type.StructField {
    comptime {
        var out: [fields.len]std.builtin.Type.StructField = undefined;
        for (fields, &out) |field, *slot| {
            slot.* = .{
                .name = field.name,
                .type = field.type,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = field.alignment,
            };
        }
        const frozen = out;
        return &frozen;
    }
}
