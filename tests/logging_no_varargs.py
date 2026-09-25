#!/usr/bin/env python3
"""Reject project C objects and the C logger ABI in fully selected archives."""

import pathlib
import subprocess
import sys


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: logging_no_varargs.py ZIG_ARCHIVE CORE_ARCHIVE")

    expected_roots = (
        {"exports.o", "libipmitool_zig_zcu.o"},
        {"empty-core.o", "libipmitool_core_zcu.o"},
    )
    for archive, expected in zip(sys.argv[1:], expected_roots):
        members = subprocess.run(
            ["ar", "t", archive], check=True, capture_output=True, text=True
        ).stdout.splitlines()
        if len(members) != 1 or pathlib.Path(members[0]).name not in expected:
            raise SystemExit(f"{archive}: expected one Zig root object, found {members}")

    symbols = subprocess.run(
        ["nm", "-g", "--defined-only", sys.argv[1]],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    if any(
        line.split() and line.split()[-1] in {"lprintf", "lperror"}
        for line in symbols
    ):
        raise SystemExit(f"{sys.argv[1]}: C variadic logger ABI is still defined")


if __name__ == "__main__":
    main()
