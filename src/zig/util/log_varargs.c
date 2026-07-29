/*
 * `va_start` trampolines for the Zig port of lib/log.c.
 *
 * `lprintf()` and `lperror()` are the only C variadic *definitions* in
 * ipmitool, and Zig 0.16 cannot express one on every target this build
 * supports: `@cVaStart` resolves `std.builtin.VaList`, which is a
 * `@compileError("disabled due to miscompilations")` for aarch64 under the
 * LLVM backend (ziglang/zig#15389).  aarch64-linux is a first class target
 * here - it is one of the two CI runners - so the port cannot be "Zig on
 * x86_64, C on arm".
 *
 * What is left in C is therefore exactly the part that needs the compiler's
 * variadic support and nothing else: capture the argument list and hand it to
 * Zig.  Everything observable - the verbosity check, the message buffer, the
 * formatting, the syslog/stderr decision and the `strerror(errno)` suffix -
 * lives in src/zig/util/log.zig.
 *
 * This file is compiled into `libipmitool_zig.a` only when `-Dzig-modules=log`
 * is selected; see the `c_shims` field of `zig_modules` in build.zig, and
 * doc/zig-migration/varargs-trampoline.md for the full rationale and for how to
 * delete it once `@cVaStart` works on aarch64.
 */

#include <stdarg.h>

#include <ipmitool/log.h>

/* Implemented by src/zig/util/log.zig. */
void ipmitool_zig_lvprintf(int level, const char *format, va_list args);
void ipmitool_zig_lvperror(int level, const char *format, va_list args);

void lprintf(int level, const char *format, ...)
{
	va_list args;

	va_start(args, format);
	ipmitool_zig_lvprintf(level, format, args);
	va_end(args);
}

void lperror(int level, const char *format, ...)
{
	va_list args;

	va_start(args, format);
	ipmitool_zig_lvperror(level, format, args);
	va_end(args);
}
