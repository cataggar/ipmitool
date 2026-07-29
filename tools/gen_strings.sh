#!/bin/sh
# Regenerate src/zig/util/strings_tables.zig from lib/ipmi_strings.c.
#
# The generated file is committed, so this script is only needed when the C
# tables change.  Running it on a clean tree must leave the tree clean - that
# is the cheapest check that the committed Zig really is what the generator
# produces from the C.
#
# Usage: sh tools/gen_strings.sh

set -eu

cd "$(dirname "$0")/.."
out=build/gen
mkdir -p "$out"

# build.zig writes config.h into the cache; make sure it exists, then use it.
zig build -p "$out/prefix" >/dev/null
cfg=$(find .zig-cache -name config.h | head -1)
[ -n "$cfg" ] || { echo "error: no generated config.h" >&2; exit 1; }

zig translate-c -I include -I "$(dirname "$cfg")" -DHAVE_CONFIG_H=1 \
	'-DDEFAULT_INTF="lan"' -lc src/zig/ipmi_c.h >"$out/ipmi_c.zig"

zig run tools/gen_strings.zig -- \
	lib/ipmi_strings.c "$out/ipmi_c.zig" src/zig/util/strings_tables.zig

zig fmt src/zig/util/strings_tables.zig >/dev/null
