#!/bin/sh
# Reproduce the frozen oracle from a historical C-capable revision.
# Optional maintainer action, never a default build/test dependency.
# Usage: sh tools/gen_strings_baseline.sh [--check|--write]
set -eu
cd "$(dirname "$0")/.."

mode=${1:---check}
case "$mode" in
	--check|--write) ;;
	*) echo "usage: $0 [--check|--write]" >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || { echo "unexpected arguments" >&2; exit 1; }

revision=207aa0ddeec2a7192a2edd9559c1bf4bd19a6f21
headers=27308375ae27168e3afce432d977c02984c5c66d
source_sha256=1e645b0d134f8755840c0f93ccae3062155f45843f89746e10971249301da8e9
out=build/strings-baseline
fixtures=src/zig/util/testdata
mkdir -p "$out/pinned"

# Neither the current C sources nor build.zig are used, so this remains usable
# after the last C source/header and its build scaffolding have been deleted.
[ "$(git rev-parse "$revision:include")" = "$headers" ]
git archive "$revision" include lib/ipmi_strings.c | tar -x -C "$out/pinned"
printf '%s  %s\n' "$source_sha256" "$out/pinned/lib/ipmi_strings.c" | sha256sum -c -

for feature in 0 1; do
	config="$out/config-$feature.h"
	{
		printf '#define IANADIR ""\n#define IANAUSERDIR ""\n#define PATH_SEPARATOR "/"\n'
		printf '#define STRINGS_BASELINE_REVISION "%s"\n' "$revision"
		[ "$feature" = 0 ] || printf '#define HAVE_CRYPTO_SHA256 1\n'
	} >"$config"
	"${ZIG:-zig}" cc -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections \
		-I "$out/pinned/include" -I "$out/pinned/lib" -include "$config" \
		tools/dump_strings_baseline.c -o "$out/dump-$feature"
	"$out/dump-$feature" >"$out/strings-c-sha256-$feature.txt"
	if [ "$mode" = --write ]; then
		mkdir -p "$fixtures"
		cp "$out/strings-c-sha256-$feature.txt" "$fixtures/"
	else
		cmp "$out/strings-c-sha256-$feature.txt" "$fixtures/strings-c-sha256-$feature.txt"
	fi
done

(cd "$fixtures" && sha256sum strings-c-sha256-0.txt strings-c-sha256-1.txt)
if [ "$mode" = --check ]; then
	(cd "$fixtures" && sha256sum -c strings-c.SHA256SUMS)
fi
