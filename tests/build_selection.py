#!/usr/bin/env python3
"""Check public build selectors and C fixture guards without compiling ipmitool."""

import argparse
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig", default="zig")
    args = parser.parse_args()
    reduced = [
        "-Dipmishell=false",
        "-Dopenssl=false",
        "-Dinternal-md5=true",
        "-Dintf-lanplus=false",
    ]
    checks = 0

    def check(options, step="--help", expected=None, extra=()):
        nonlocal checks
        command = [args.zig, "build", step, *reduced, *options, *extra]
        result = subprocess.run(command, capture_output=True, text=True)
        output = result.stdout + result.stderr
        if expected is None:
            assert result.returncode == 0, (command, output)
            assert "[default=all]" in output, output
            assert "-Dc-oracle" in output, output
        else:
            assert result.returncode != 0, (command, output)
            assert expected in output, (command, output)
        checks += 1

    for options in (
        [],
        ["-Dzig-modules=all"],
        ["-Dzig-modules=none"],
        ["-Dc-oracle=true"],
        ["-Dc-oracle=true", "-Dzig-modules=none"],
        ["-Dc-oracle=false"],
        ["-Dzig-modules=sdr,sel"],
        ["-Dzig-modules=cli,ipmishell"],
    ):
        check(options)
    for options, error in (
        (["-Dc-oracle=true", "-Dzig-modules=all"], "ConflictingCOracle"),
        (["-Dc-oracle=true", "-Dzig-modules=sdr,sel"], "ConflictingCOracle"),
        (["-Dzig-modules=none,all"], "ConflictingNone"),
        (["-Dzig-modules=sdr,none"], "ConflictingNone"),
        (["-Dzig-modules="], "EmptySelection"),
        (["-Dzig-modules=not-a-module"], "UnknownModule"),
    ):
        check(options, expected=error)
    for options in ([], ["-Dzig-modules=all"], ["-Dzig-modules=sdr,sel"]):
        check(options, "gen-transport-fixtures", "C transport fixtures require")
        check(
            options,
            "test-golden",
            "C golden snapshots require",
            extra=("--", "--update"),
        )
    for options in (["-Dc-oracle=true"], ["-Dzig-modules=none"]):
        check(
            options,
            "gen-transport-fixtures",
            "require both -Dintf-lan=true and -Dintf-lanplus=true",
        )
    print(f"build selection: {checks} CLI checks passed")


if __name__ == "__main__":
    main()
