"""Provide real terminal input to a transport fixture after SOL activation.

The binary's stdin is the slave PTY; stdout and stderr remain separate pipes,
so the transport harness can still compare them byte-for-byte.
"""

import os
import pty
import select
import subprocess
import sys
import termios
import time


def main():
    input_bytes = sys.argv[1].encode("latin1")
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        sys.argv[2:], stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    streams = {proc.stdout.fileno(): 1, proc.stderr.fileno(): 2}
    # stdout is a pipe, so libc buffers the activation banner until exit.
    # Wait for the *actual* raw-mode transition instead of racing a timer.
    deadline = time.monotonic() + 10
    while termios.tcgetattr(slave)[3] & (termios.ICANON | termios.ECHO):
        if time.monotonic() > deadline or proc.poll() is not None:
            raise TimeoutError("SOL session did not enter terminal raw mode")
        time.sleep(0.02)
    os.close(slave)
    for part in input_bytes.split(b"\x1e"):
        os.write(master, part)
        time.sleep(0.25)
    while streams:
        ready, _, _ = select.select(list(streams), [], [], 10)
        if not ready:
            raise TimeoutError("SOL PTY fixture timed out waiting for output")
        for fd in ready:
            chunk = os.read(fd, 4096)
            if not chunk:
                del streams[fd]
                continue
            os.write(streams[fd], chunk)
    os.close(master)
    return proc.wait()


if __name__ == "__main__":
    sys.exit(main())
