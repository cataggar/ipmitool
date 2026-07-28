# C/Zig interop seams

This is the contract every later port PR follows. It exists so that replacing
one C translation unit with Zig is a mechanical, reviewable, individually
revertible change instead of an architectural decision.

Related documents: [`baseline-oracle.md`](baseline-oracle.md) for the reference
binaries the golden checks compare against, and issue #2 for the overall plan.

## Module map

The Zig tree mirrors the C tree. Header ports and translation-unit ports are
kept apart, exactly as `include/ipmitool/*.h` and `lib/*.c` are.

| Zig                  | C                                          | Contents |
| -------------------- | ------------------------------------------ | -------- |
| `src/zig/core/`      | `include/ipmitool/ipmi*.h`                 | request/response types, completion codes, session state |
| `src/zig/intf/`      | `include/ipmitool/ipmi_intf.h`, `src/plugins/*` | the transport vtable and the transports |
| `src/zig/cmd/`       | `lib/ipmi_*.c`                             | one module per command translation unit |
| `src/zig/util/`      | `lib/helper.c`, `lib/log.c`, `bswap.h`, `ipmi_time.c`, `ipmi_strings.c` | shared utilities |

Supporting files at the root of `src/zig/`:

| File            | Role |
| --------------- | ---- |
| `ipmi_c.h`      | umbrella header listing which C headers the bridge exposes |
| `abi_layout.h`  | `sizeof`/`alignof`/`offsetof` for C types `translate-c` cannot represent |
| `abi.zig`       | comptime layout and signature assertions |
| `root.zig`      | namespace of every header port; the root of `zig build test` |
| `exports.zig`   | link-time root of `libipmitool_zig.a`; one guarded `@import` per port |

`ipmi_c.h` and `abi_layout.h` are the only two C files the Zig tree owns. They
are build-time scaffolding, never linked into the product, and they are deleted
together with the last C translation unit.

## Naming conventions

Same as the sibling project `azure-sdk-for-zig`:

* types and structs: `PascalCase`
* functions and methods: `camelCase`
* constants: `snake_case`
* files: `snake_case.zig`

Two deliberate exceptions, both driven by the ABI:

* **Struct fields keep their C names.** `Response.session.bEncrypted` looks
  wrong in Zig, but `abi.assertLayout` compares field names one for one and a
  reviewer diffing the header against the port should not have to translate.
* **Exported symbols keep their C names**, declared once in a `comptime` block
  with `@export`, so the Zig function itself can stay `camelCase`:

  ```zig
  comptime {
      @export(&setup, .{ .name = "ipmi_oem_setup", .linkage = .strong });
  }
  ```

Runtime interfaces are function-pointer structs recovered with
`@fieldParentPtr`, which is what `intf.Intf` already is in C and what issue #10
will build the Zig transports on.

## The two-way bridge

### Zig calling C: the `ipmi_c` module

`build.zig` runs `zig translate-c` over `src/zig/ipmi_c.h` with the same include
path, `config.h` and `-D` macros a C translation unit gets, and exposes the
result as the `ipmi_c` module:

```zig
const c = @import("ipmi_c");

c.lprintf(log.Level.notice, "\nOEM Support:");
return c.ipmi_sel_oem_init(filename);
```

Every call into remaining C goes through this module — Zig modules do **not**
declare `extern fn` for C symbols. That rule matters: when the module owning a
symbol is itself ported, an `extern fn` declaration would collide with the new
`@export`, whereas a `c.` call site keeps working until the callee's header is
retired.

Bridge types are spelled differently from the mirrors (`[*c]struct_ipmi_intf`
versus `*Intf`), so call sites cast:

```zig
c.ipmi_intf_session_set_authtype(@ptrCast(intf), authtype_oem);
```

That cast is only safe because of the ABI assertions below; do not add one for a
type that has no mirror assertion.

Exposing another header is one `#include` in `src/zig/ipmi_c.h`.

### C calling Zig: `export` with the original signature

A ported module defines the symbols the C used to define, with identical C ABI
signatures, and `build.zig` drops the `.c` from the compile. The remaining C is
unchanged and unaware — this is a pure link-time substitution.

```zig
fn active(intf: ?*Intf, oemtype: ?[*:0]const u8) callconv(.c) c_int { ... }

comptime {
    abi.assertCallSignature(@TypeOf(active), @TypeOf(c.ipmi_oem_active));
    @export(&active, .{ .name = "ipmi_oem_active", .linkage = .strong });
}
```

`abi.assertCallSignature` compares the calling convention, the variadic flag,
the argument count and the size/alignment of every argument and of the result
against the `translate-c` view of the real prototype. A header change that the
port does not follow is a compile error.

## The swap flag

```
zig build                        # all C, byte-identical to the oracle
zig build -Dzig-modules=oem      # lib/ipmi_oem.c replaced by src/zig/cmd/oem.zig
zig build -Dzig-modules=oem,raw  # several at once
zig build --help                 # lists the available module names
```

Mechanics, all in `build.zig`:

1. `zig_modules` maps each name to the `.c` it replaces and to its Zig
   implementation.
2. `parseZigModules` splits the option and exits with the list of valid names
   when it sees an unknown one.
3. `addSources` skips any `.c` a selected module replaces, so there is never a
   duplicate symbol; the swap is a substitution, not an override.
4. When at least one module is selected, `src/zig/exports.zig` is compiled into
   `libipmitool_zig.a` and linked after `libipmitool_core.a`.
5. With no selection the Zig library is not built or linked at all, so the
   default build is bit-for-bit the pre-existing all-C build.

`exports.zig` gates each port on a build option, so an unselected module is
never analysed and exports nothing:

```zig
comptime {
    if (selected("oem")) {
        _ = @import("cmd/oem.zig");
    }
}
```

## The ABI parity harness

Each header port is an `extern struct` mirror plus a `comptime` block that
proves it matches C. Because both sides are evaluated for the *target*, the
assertions stay correct when cross compiling, on big endian targets and under
either `HAVE_PRAGMA_PACK` setting. Nothing has to run.

### Faithfully translated types: `assertLayout`

```zig
comptime {
    abi.assertLayout(Intf, c.struct_ipmi_intf);
}
```

`assertLayout` checks `@sizeOf` and `@alignOf` of the struct, that the field
count matches, and for every field that the name, the offset, the size and the
alignment agree. It needs no maintenance: adding a field to the C header fails
the build until the mirror gets it too.

Nested anonymous structs and unions are asserted separately by pulling the C
type out with `@FieldType`:

```zig
abi.assertLayout(Response.Session, @FieldType(c.struct_ipmi_rs, "session"));
```

### Types `translate-c` cannot represent: `assertOpaqueLayout`

`translate-c` demotes any struct containing a bitfield to `opaque {}`, so
`@sizeOf` and `@offsetOf` are unavailable — this hits `struct ipmi_rq`,
`struct ipmi_rq_entry`, and several `ipmi_sdr.h` and `ipmi_sel.h` records.

`src/zig/abi_layout.h` restates their layout as plain `enum` constants, which
`translate-c` does handle:

```c
ABI_SIZEOF_ipmi_rq = sizeof(struct ipmi_rq),
ABI_OFFSETOF_ipmi_rq__msg__cmd = offsetof(struct ipmi_rq, msg.cmd),
```

and the mirror compares against those:

```zig
abi.assertOpaqueLayout(Request, .{
    .size = c.ABI_SIZEOF_ipmi_rq,
    .alignment = c.ABI_ALIGNOF_ipmi_rq,
    .fields = &.{
        .{ .name = "msg.cmd", .offset = c.ABI_OFFSETOF_ipmi_rq__msg__cmd },
    },
});
```

The numbers still come from the C compiler, so this is as target-accurate as
`assertLayout`; it just costs one line of C per field.

### Bitfields

C allocates bitfields from the least significant bit on little endian targets
and from the most significant bit on big endian ones, while a Zig `packed
struct` always starts at the least significant bit of its backing integer. Port
a bitfield group as a `packed struct(uN)` whose declaration order follows the
target:

```zig
pub const NetFnLun = switch (builtin.target.cpu.arch.endian()) {
    .little => packed struct(u8) { netfn: u6, lun: u2 },
    .big => packed struct(u8) { lun: u2, netfn: u6 },
};
```

Bitfield members have no address, so assert the offset of the field that follows
them instead.

### Adding assertions for another header

1. Write the mirror as an `extern struct` in `core/`, `intf/` or `util/`, with
   the C field names, in the C order.
2. Add `#include <ipmitool/your_header.h>` to `src/zig/ipmi_c.h`.
3. Add `comptime { abi.assertLayout(Mirror, c.struct_your_type); }`.
4. If the build reports the C type as `opaque`, add `ABI_*` constants for it to
   `src/zig/abi_layout.h` and use `abi.assertOpaqueLayout` instead.
5. Reference the new module from `src/zig/root.zig` so `zig build test`
   compiles it.

Headers with ABI assertions today: `ipmi.h`, `ipmi_intf.h`, `ipmi_oem.h`, and
the lookup-table types from `helper.h`. Everything else is still to do; the
recipe above is the whole cost of adding one.

## Recipe: porting one C module

The steps for `lib/ipmi_<name>.c`, in order. One PR per module.

1. **Branch.** `port/<name>`.
2. **Read the C.** Note every exported symbol (`nm` the object, or grep the
   header) and every symbol it calls. The exported set is the contract; the
   called set decides what must exist in `ipmi_c`.
3. **Mirror the types it needs.** Anything from `include/ipmitool/*.h` that is
   not mirrored yet goes into `core/`, `intf/` or `util/` with the ABI
   assertions from the previous section. Do this first — the assertions are what
   make the rest safe.
4. **Write `src/zig/cmd/<name>.zig`.** Keep the C control flow. Reach remaining C
   through `@import("ipmi_c")`, never through `extern fn`. End the file with the
   `comptime` block that pairs `abi.assertCallSignature` with `@export` for every
   symbol the C translation unit exported.
5. **Register the module.** One entry in `zig_modules` in `build.zig`, one
   guarded `@import` in `src/zig/exports.zig`.
6. **Verify.** See the checklist below.
7. **Open the PR** with the parity evidence in the body.

Order the work so that a module is ported only after everything it *exports* to
is still C, i.e. leaves first. `lib/ipmi_oem.c` was chosen as the first port
because it exports three functions, has no state beyond one static table, and
its entire observable behaviour is reachable from `ipmitool -o list`.

## Review checklist for a port PR

* [ ] Every symbol the `.c` exported is exported by the Zig module, with
      `abi.assertCallSignature` against the `ipmi_c` prototype.
* [ ] No symbol the `.c` did *not* export is exported (C `static` functions stay
      private in Zig).
* [ ] The `.c` is removed from the build by the `zig_modules` entry, not by
      deleting it — the C stays in the tree until the whole migration lands, so
      the swap can be flipped back for bisecting.
* [ ] No `.c` or `.h` outside `src/zig/` is modified. If one is, the PR body
      says why.
* [ ] Calls into remaining C go through `@import("ipmi_c")`.
* [ ] Every `@ptrCast` between a mirror and a bridge type is backed by an
      `assertLayout`/`assertOpaqueLayout` on that type.
* [ ] Types are `PascalCase`, functions `camelCase`, files `snake_case.zig`;
      struct fields keep their C names.
* [ ] `zig build` (default) still matches the oracle for `-h` and `-V`.
* [ ] `zig build -Dzig-modules=<name>` links and produces identical output to
      the default build for every code path the module touches.
* [ ] `zig build test` passes with and without the flag.
* [ ] `zig fmt --check` passes over the added files.
* [ ] The golden suite covers at least one command that exercises the module.

## Verifying a port

```bash
# default build: still all C, still matches the oracle
zig build -p zig-out/c
diff <(tail -n +2 <oracle>/ipmitool-h.txt) <(./zig-out/c/bin/ipmitool -h 2>&1 | tail -n +2)

# with the module swapped in
zig build -Dzig-modules=<name> -p zig-out/zig

# differential check of the affected code paths
diff <(./zig-out/c/bin/ipmitool <args> 2>&1) <(./zig-out/zig/bin/ipmitool <args> 2>&1)

# ABI assertions and unit tests, both ways
zig build test
zig build test -Dzig-modules=<name>

zig fmt --check build.zig src/zig/
```

`zig build test` also runs the `-o list` differential check that covers the
`oem` module in both modes; add an equivalent check when porting a module whose
output is not yet covered by the golden suite.

To confirm the substitution actually happened rather than the C silently winning
the link:

```bash
nm zig-out/zig/bin/ipmitool | grep ' T ipmi_<name>_'
```

The C file's `static` helpers must be absent and the public symbols present.
