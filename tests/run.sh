#!/bin/sh
# Entry point for the ipmitool golden test harness.
#
#   tests/run.sh                       # run every case against the reference binary
#   tests/run.sh --filter sdr          # run a subset
#   tests/run.sh --update              # regenerate snapshots, then review the diff
#   tests/run.sh --candidate zig-out/bin/ipmitool   # differential mode
#   tests/run.sh --coverage            # command coverage report only
#
# The binary under test is, in order of precedence:
#   --binary <path>, $IPMITOOL_BINARY, $IPMITOOL_ORACLE, tests/oracle/ipmitool
#
# This wrapper exists so the suite can be run before build.zig knows about it.
# See doc/zig-migration/golden-harness.md for the `zig build test` wiring.
set -eu

# shellcheck disable=SC1007 # CDPATH= is a command prefix assignment, not a typo
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")

if ! command -v zig >/dev/null 2>&1; then
	echo "tests/run.sh: zig not found in PATH" >&2
	exit 127
fi

cd "$repo_root"
exec zig run "tests/golden/main.zig" -- \
	--tests-dir "tests" \
	--repo "." \
	"$@"
