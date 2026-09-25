#!/usr/bin/env python3
"""Run the C and Zig Sun OEM interactive CLI against the same dummy BMC PTY.

The golden harness has pipe-backed stdin; this uses a real pseudo-terminal so
the termios/select/read/^D path runs as well as the noninteractive path.
"""
import os
import pty
import select
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

SOCKET = Path(".sunoem-cli-pty.sock")
HOME = Path(".sunoem-cli-pty-home")
HANDLE = bytes.fromhex("12 34 56 78")


def read_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise RuntimeError("dummy BMC disconnected during a request")
        data += chunk
    return data


def run(binary):
    requests = []
    failures = []
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        SOCKET.unlink(missing_ok=True)
        server.bind(str(SOCKET))
        server.listen(1)
        server.settimeout(7)

        def bmc():
            try:
                conn, _ = server.accept()
                with conn:
                    conn.settimeout(7)
                    while True:
                        header = read_exact(conn, 16)
                        netfn, lun, cmd = header[:3]
                        length = struct.unpack_from("<H", header, 4)[0]
                        data = read_exact(conn, length)
                        if (netfn, cmd) == (0x3F, 0xFF):
                            return
                        requests.append((netfn, lun, cmd, data))
                        ccode = 0xC1 if netfn == 0x2C else 0
                        reply = b""
                        if cmd == 0x19:
                            if data[1] == 0:
                                reply = b"\x02\x00\x00\x00" + HANDLE + b"\x00"
                            elif data[1] == 4:
                                reply = b"\x02\x01\x00\x00" + HANDLE + b"bye\n\x00"
                            else:
                                reply = b"\x02\x00\x00\x00" + HANDLE + b"\x00"
                        response = struct.pack(
                            "<BBBBB3xi4xQ", netfn | 1, cmd, 0, lun, ccode, len(reply), 0
                        )
                        conn.sendall(response + reply)
            except Exception as exc:
                failures.append(exc)

        worker = threading.Thread(target=bmc)
        worker.start()
        master, slave = pty.openpty()
        env = dict(
            os.environ,
            IPMI_DUMMY_SOCK=str(SOCKET.resolve()),
            HOME=str(HOME.resolve()),
            LC_ALL="C",
            LANG="C",
            TERM="dumb",
        )
        process = subprocess.Popen(
            [str(Path(binary).resolve()), "-I", "dummy", "sunoem", "cli"],
            stdin=slave,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        os.close(slave)
        try:
            readable, _, _ = select.select([process.stdout], [], [], 5)
            if not readable:
                raise RuntimeError("interactive CLI never connected")
            connected = process.stdout.readline()
            if connected != b"Connected. Use ^D to exit.\n":
                raise RuntimeError(f"interactive CLI connection: {connected!r}")
            time.sleep(0.1)  # tcsetattr(TCSAFLUSH) must finish before input.
            os.write(master, b"x\n\x04")
            out, err = process.communicate(timeout=5)
            result = (process.returncode, connected + out, err, requests)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
        worker.join(timeout=8)
        if worker.is_alive() or failures:
            raise RuntimeError(f"dummy BMC failure: {failures!r}")
        return result
    finally:
        server.close()
        SOCKET.unlink(missing_ok=True)


def main():
    if len(sys.argv) != 3:
        print("usage: sunoem_cli_pty.py C_BINARY ZIG_BINARY", file=sys.stderr)
        return 2
    registry = HOME / ".local/usr/share/misc/enterprise-numbers"
    registry.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile("tests/fixtures/iana/enterprise-numbers", registry)
    try:
        baseline, candidate = map(run, sys.argv[1:3])
    finally:
        shutil.rmtree(HOME)
    if baseline != candidate:
        print(f"C: {baseline!r}\nZig: {candidate!r}", file=sys.stderr)
        return 1
    code, out, err, requests = candidate
    if code != 0 or out != b"Connected. Use ^D to exit.\nbye\n" or err:
        print(f"unexpected result: {candidate!r}", file=sys.stderr)
        return 1
    polls = [data for netfn, _, cmd, data in requests if (netfn, cmd) == (0x2E, 0x19)]
    assert len(polls) == 4 and polls[-1][1] == 4
    print("Sun OEM interactive CLI: C/Zig PTY, ^D, output, exit and 4 requests match")
    return 0


if __name__ == "__main__":
    sys.exit(main())
