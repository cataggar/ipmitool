#!/bin/sh
# Mechanical equivalence proof for the lib/ipmi_strings.c -> Zig port.
#
# Builds ipmitool twice - once entirely from C, once with -Dzig-modules=strings
# - links tools/dump_strings.c against each variant's static archives, and
# diffs the two dumps.  Every entry of every exported lookup table (including
# the sentinel), a val2str()/oemval2str() probe sweep, and the IANA PEN
# registry loader's debug transcript are compared.
#
# Usage: sh tools/dump_strings.sh
# Exits non-zero on any difference.  Artifacts land in build/strings-diff/.

set -eu

cd "$(dirname "$0")/.."
out=build/strings-diff
rm -rf "$out"
mkdir -p "$out"

# Extra `zig build` options, e.g. ZIG_BUILD_FLAGS=-Dopenssl=false to check the
# HAVE_CRYPTO_SHA256 conditional entries of the RMCP+ algorithm tables.
flags=${ZIG_BUILD_FLAGS:-}

# The registry dictionary is looked up under $HOME first, so pointing HOME at a
# fixture makes both variants read the same file regardless of -Diana-dir.
fake_home=$(cd "$out" && pwd)/home
mkdir -p "$fake_home/.local/usr/share/misc"
cat >"$fake_home/.local/usr/share/misc/enterprise-numbers" <<'EOF'
Ignored preamble line
0
  Reserved
    dummy contact
1
  NxNetworks
    someone
343
  Intel Corporation
    someone else
malformed-key-line-without-digit
12634
  PICMG
    contact
4294967295
  Sentinel Collision Inc
    contact
EOF

# Each variant gets its own cache so that the archives below can be found by
# content: a shared cache would also hold archives from every other build
# configuration this tree has ever produced.
echo "== building the all-C variant"
# shellcheck disable=SC2086  # deliberate word splitting of the flag list
zig build $flags --cache-dir "$out/cache-c" -p "$out/c" >/dev/null

echo "== building the -Dzig-modules=strings variant"
# shellcheck disable=SC2086
zig build $flags -Dzig-modules=strings --cache-dir "$out/cache-zig" \
	-p "$out/zig" >/dev/null

# Locate the archives by *content* rather than by cache hash: the all-C core
# archive defines completion_code_vals, the swapped one does not, and the Zig
# archive picks it up instead.
find_ar() {
	cache=$1
	name=$2
	want=$3
	for a in $(find "$cache" -name "$name"); do
		if nm --defined-only "$a" 2>/dev/null |
			grep -qw completion_code_vals; then
			[ "$want" = yes ] && { echo "$a"; return; }
		else
			[ "$want" = no ] && { echo "$a"; return; }
		fi
	done
	echo "error: no $name with completion_code_vals=$want" >&2
	exit 1
}

core_c=$(find_ar "$out/cache-c" libipmitool_core.a yes)
core_swap=$(find_ar "$out/cache-zig" libipmitool_core.a no)
zig_lib=$(find_ar "$out/cache-zig" libipmitool_zig.a yes)
echo "   C  core: $core_c"
echo "   Zig core: $core_swap"
echo "   Zig  lib: $zig_lib"

zig cc -o "$out/dump_c" tools/dump_strings.c "$core_c" -I include -lm
zig cc -o "$out/dump_zig" tools/dump_strings.c "$core_swap" "$zig_lib" \
	-I include -lm

for v in c zig; do
	HOME=$fake_home "$out/dump_$v" --registry \
		>"$out/dump-$v.txt" 2>"$out/log-$v.txt"
	nm -S --defined-only "$out/$v/bin/ipmitool" |
		awk 'NF==4 {print $4, $2}' | sort >"$out/nm-$v.txt"
done

# Symbol sizes must match too: a table that lost entries *behind* its NULL
# terminator would dump identically but shrink here.
grep -v '^probe|\|^oemprobe|' "$out/dump-c.txt" | cut -d'|' -f1 | sort -u \
	>"$out/tables.txt"
: >"$out/sizes.txt"
while read -r sym; do
	sc=$(awk -v n="$sym" '$1==n{print $2; exit}' "$out/nm-c.txt")
	sz=$(awk -v n="$sym" '$1==n{print $2; exit}' "$out/nm-zig.txt")
	printf '%s %s %s\n' "$sym" "${sc:-ABSENT}" "${sz:-ABSENT}" \
		>>"$out/sizes.txt"
	if [ "$sc" != "$sz" ] || [ -z "$sc" ]; then
		echo "error: $sym size ${sc:-ABSENT} != ${sz:-ABSENT}" >&2
		exit 1
	fi
done <"$out/tables.txt"

# The C translation unit must be gone from the swapped binary.
for sym in count_bytes oem_info_list_load oem_info_list_free \
	oem_info_init_from_list ipmi_oem_info_head ipmi_oem_info_tail \
	ipmi_oem_info_dummy; do
	if awk -v n="$sym" '$1==n{found=1} END{exit !found}' "$out/nm-zig.txt"
	then
		echo "error: C-only symbol $sym still linked" >&2
		exit 1
	fi
done

echo "== diffing"
diff -u "$out/dump-c.txt" "$out/dump-zig.txt"
diff -u "$out/log-c.txt" "$out/log-zig.txt"

tables=$(wc -l <"$out/tables.txt")
entries=$(grep -cv '^probe|\|^oemprobe|' "$out/dump-c.txt")
probes=$(grep -c '^probe|\|^oemprobe|' "$out/dump-c.txt")
echo "OK: $tables tables, $entries table entries (sentinels included)," \
	"$probes lookup probes, $(wc -l <"$out/log-c.txt") loader log lines" \
	"- byte-identical between the C and Zig builds;" \
	"all $tables symbol sizes match and no C-only symbol survives"
