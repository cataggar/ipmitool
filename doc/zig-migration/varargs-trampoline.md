# Variadic C functions across the Zig seam

`doc/zig-migration/interop-seams.md` is the recipe for porting a module.  This
note records one exception to it that the util-foundations port (issue #8) had
to introduce, plus three smaller conventions the same port established.  Read
it after `interop-seams.md`; everything here is additive.

## The problem: `@cVaStart` is unusable on aarch64

`lib/log.c` defines two C-variadic functions:

```c
void lprintf(int level, const char * format, ...);
void lperror(int level, const char * format, ...);
```

Zig can *call* variadic C functions and it can *define* them with
`@cVaStart`/`@cVaArg`/`@cVaEnd`, but defining one requires
`std.builtin.VaList`, and on aarch64 that type is

```zig
@compileError("disabled due to miscompilations")
```

(<https://github.com/ziglang/zig/issues/15389>).  `ubuntu-24.04-arm` is one of
the required CI runners, so a Zig `lprintf` definition would fail to compile on
half the matrix.

## The fix: a two-line C trampoline

`src/zig/util/log_varargs.c` keeps the `va_start`/`va_end` on the C side and
forwards the resulting `va_list` to Zig:

```c
void lprintf(int level, const char *format, ...)
{
	va_list vptr;
	va_start(vptr, format);
	ipmitool_zig_lvprintf(level, format, vptr);
	va_end(vptr);
}
```

Zig implements `ipmitool_zig_lvprintf` and calls `vfprintf` through the
`ipmi_c` bridge.  Passing an already-created `va_list` around is fine on every
target; only *creating* one in Zig is broken.

Two details matter when you copy this:

* **The parameter type must be derived, not written.**  `c.va_list` is an array
  type on x86-64, and "arrays are not allowed as a parameter type".  Take the
  type from a bridge function that already accepts one:

  ```zig
  pub const VaList = @typeInfo(@TypeOf(c.vsnprintf)).@"fn".params[3].type.?;
  ```

  That resolves to `[*c]c.struct___va_list_tag` on x86-64 and to
  `c.va_list` (a struct) on aarch64.

* **The shim is only compiled when the module is selected.**  `build.zig`'s
  `ZigModule` entries carry a `c_shims` list; `addZigCShims()` adds them to
  `libipmitool_zig` only for the modules named in `-Dzig-modules=`.  Otherwise
  the trampoline's `lprintf` would collide with `lib/log.c`'s.

`interop-seams.md` says the Zig tree contains "exactly two C files"
(`ipmi_c.h`, `abi_layout.h`).  There is now a third, and there will be one more
for every variadic definition we port (`ipmi_sdr.c` and `ipmi_sel.c` have
none, but `ipmi_lanplus.c` does).  Keep such shims tiny: `va_start`, one call,
`va_end`, nothing else.  All logic belongs in Zig.

## Export gating for modules that other Zig modules import

`src/zig/cmd/oem.zig` can `@export` at file scope because nothing else imports
it.  `src/zig/util/log.zig` is different: `helper.zig` and `oem.zig` use
`log.Level`, and `root.zig` imports the whole tree for tests.  A file-scope
`@export` would then emit `lprintf` even in a build where `lib/log.c` is still
the selected implementation, and the link would fail with a duplicate symbol.

Every `src/zig/util/*.zig` module therefore collects its exports in

```zig
pub fn exportSymbols() void {
    @export(&lprintfAbi, .{ .name = "lprintf", .linkage = .strong });
    ...
}
```

and `src/zig/exports.zig` calls it from a `comptime` block, guarded by the
build option:

```zig
comptime {
    if (isSelected("log")) log.exportSymbols();
}
```

`@export` inside a function body is evaluated when the function is
comptime-called, so this both gates the symbols *and* keeps unselected modules
out of semantic analysis.

## `refAllDecls` is not recursive - compile coverage comes from `ipmitool-zig`

`build.zig`'s `abi_tests` compiles `src/zig/root.zig` against libc only, with
none of the ipmitool C objects.  `std.testing.refAllDecls` is shallow, so it
never forces codegen of a port's function bodies; a port can contain a type
error in an untested function and the unit tests will still pass.  Adding tests
for those functions is not an option either, because most of them call
`lprintf` or read `verbose`, which do not exist in the test binary.

What closes that gap is `addSwappedTool`: `zig build test` links `ipmitool-zig`,
an `ipmitool` with **every** entry of `zig_modules` selected, and runs the
golden suite against it.  Selecting a module is what makes `exports.zig`
analyse it, so this both type-checks and differentially tests every port on both
CI architectures.  Add a module to the `zig_modules` table and the coverage
comes for free - including its `c_shims`, which `addSwappedTool` compiles the
same way the main build does.

## Keep `assertCallSignature` out of file scope

`abi.assertCallSignature(@TypeOf(ported), @TypeOf(c.original))` names the C
declaration, and naming it is enough to make the compiler emit a reference to
it.  In a file-scope `comptime` block that happens unconditionally, including
in the `abi_tests` binary, which links `src/zig/root.zig` against libc and
nothing else.

That is invisible with the LLVM backend, which drops unused extern
declarations, and a hard link failure with the self-hosted x86_64 backend that
Zig 0.16 uses for a native Debug build on `ubuntu-latest`:

```
error: undefined symbol: str2short
    note: referenced by root.o:.debug_info
```

So the assertions go inside `exportSymbols()`, next to the `@export` calls they
describe - the same shape `src/zig/cmd/oem.zig` already has.  Then they are
only analysed when the module is selected, at which point the symbol they name
is the one the module itself exports.  Nothing is lost: `zig build test` links
`ipmitool-zig` with every module selected on both CI architectures, so every
assertion still runs on every PR.

## Formatting and locale-sensitive parsing stay in libc

Output parity is the acceptance criterion for the whole migration, so the ports
call `printf`/`fprintf`/`snprintf` through the bridge rather than
`std.fmt`.  The same goes for `strtol`/`strtoul`/`strtod`/`sscanf`/`strftime`:
they honour `LC_NUMERIC`/`LC_TIME` and set `errno` in ways `std.fmt.parseInt`
does not, and several ipmitool code paths depend on the exact `errno`/end-pointer
behaviour.  Zig error sets are used *inside* a module; the exported functions
keep the original C return codes.
