#!/usr/bin/env python3
"""Reject a C variadic logger in a fully selected Zig replacement archive."""

import pathlib
import subprocess
import sys


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: logging_no_varargs.py ARCHIVE")

    archive = sys.argv[1]
    members = subprocess.run(
        ["ar", "t", archive], check=True, capture_output=True, text=True
    ).stdout.splitlines()
    if any(pathlib.Path(member).name == "log_varargs.o" for member in members):
        raise SystemExit(f"{archive}: C variadic logger object is still present")

    symbols = subprocess.run(
        ["nm", "-g", "--defined-only", archive],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    if any(
        line.split() and line.split()[-1] in {"lprintf", "lperror"}
        for line in symbols
    ):
        raise SystemExit(f"{archive}: C variadic logger ABI is still defined")


if __name__ == "__main__":
    main()
