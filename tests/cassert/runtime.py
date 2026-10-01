#!/usr/bin/env python3
"""Check assertion diagnostics and SIGABRT from libc-free Zig executables."""

import os
import resource
import signal
import subprocess
import sys


def disable_core_dumps():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def run(binary, stderr=subprocess.PIPE):
    return subprocess.run(
        [binary],
        stdout=subprocess.PIPE,
        stderr=stderr,
        timeout=8,
        check=False,
        preexec_fn=disable_core_dumps,
    )


def main():
    passed, failed, long, unreachable = sys.argv[1:]
    result = run(passed)
    assert (result.returncode, result.stdout, result.stderr) == (0, b"", b""), result

    message = b"assertion.c:42: fixture: Assertion `expression' failed.\n"
    for binary, expected in (
        (failed, message),
        (unreachable, message),
        (long, b"assertion.c:42: fixture: Assertion `" + b"x" * 1024 + b"' failed.\n"),
    ):
        result = run(binary)
        assert result.returncode == -signal.SIGABRT, result
        assert result.stdout == b"", result.stdout
        assert result.stderr == expected, result.stderr

    def close_stderr():
        disable_core_dumps()
        os.close(2)

    result = subprocess.run(
        [failed],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=8,
        check=False,
        preexec_fn=close_stderr,
    )
    assert result.returncode == -signal.SIGABRT, result
    assert result.stdout == b"", result.stdout
    assert result.stderr == b"", result.stderr


if __name__ == "__main__":
    main()
