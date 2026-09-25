#!/usr/bin/env python3
"""Reject project C objects and the C logger ABI in fully selected archives."""

import pathlib
import subprocess
import sys


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: logging_no_varargs.py ZIG_ARCHIVE CORE_ARCHIVE")

    for archive in sys.argv[1:]:
        members = subprocess.run(
            ["ar", "t", archive], check=True, capture_output=True, text=True
        ).stdout.splitlines()
        non_zig = [
            member for member in members
            if not pathlib.Path(member).name.endswith("_zcu.o")
        ]
        if not members or non_zig:
            raise SystemExit(f"{archive}: expected only Zig objects, found {non_zig or 'none'}")

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
