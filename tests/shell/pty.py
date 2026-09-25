#!/usr/bin/env python3
"""Exercise the Zig shell through a real PTY and compare script/CLI with C.

Usage: python3 tests/shell/pty.py zig-out/bin/ipmitool-zig-shell
       [zig-out/bin/ipmitool-c-shell]
The C oracle is built with -Dipmishell=false when readline headers are absent;
its exec/set/echo entry points remain the original src/ipmishell.c.
"""

import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import termios
import unittest

ROOT = Path(__file__).resolve().parents[2]
ZIG = str((ROOT / sys.argv[1]).resolve())
C = str((ROOT / sys.argv[2]).resolve()) if len(sys.argv) > 2 else None
sys.argv[1:] = []
SOCKET = ROOT / ".zig-cache" / f"shell-pty-{os.getpid()}.sock"
SCRIPT = ROOT / ".zig-cache" / f"shell-commands-{os.getpid()}.txt"


def exactly(conn, count):
    data = b""
    while len(data) < count:
        piece = conn.recv(count - len(data))
        if not piece:
            return None
        data += piece
    return data


class Dummy:
    def __enter__(self):
        SOCKET.parent.mkdir(exist_ok=True)
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(SOCKET))
        self.listener.listen()
        self.listener.settimeout(.2)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.serve)
        self.thread.start()
        return self

    def serve(self):
        while not self.stop.is_set():
            try:
                conn, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with conn:
                conn.settimeout(2)
                try:
                    while header := exactly(conn, 16):
                        netfn, lun, command = header[:3]
                        size = int.from_bytes(header[4:6], sys.byteorder)
                        if size and exactly(conn, size) is None:
                            break
                        if netfn == 0x3F and command == 0xFF:
                            break
                        # Match the golden harness's default completion code.
                        conn.sendall(struct.pack(
                            "@BBBBB3xi4xP", netfn | 1, command, 0, lun, 0xC1, 0, 0
                        ))
                except (OSError, TimeoutError):
                    pass

    def __exit__(self, *_):
        self.stop.set()
        self.listener.close()
        self.thread.join(timeout=3)
        SOCKET.unlink(missing_ok=True)
        assert not self.thread.is_alive(), "dummy BMC thread did not stop"


def env():
    return {**os.environ, "IPMI_DUMMY_SOCK": str(SOCKET), "TERM": "xterm", "LC_ALL": "C"}


def cli(binary, *args):
    return subprocess.run(
        [binary, "-I", "dummy", *args],
        capture_output=True, env=env(), timeout=5, check=False,
    )


def pty(inputs, check_terminal=False, terminal="xterm"):
    master, slave = os.openpty()
    proc = subprocess.Popen(
        [ZIG, "-I", "dummy", "shell"], stdin=slave, stdout=slave,
        stderr=slave, env={**env(), "TERM": terminal}, close_fds=True,
    )
    os.close(slave)
    output = bytearray()
    consumed = 0
    try:
        for expected, payload in inputs:
            deadline = time.monotonic() + 5
            while expected not in output[consumed:]:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(f"waiting for {expected!r}; got {bytes(output)!r}")
                readable, _, _ = select.select([master], [], [], remaining)
                if readable:
                    try:
                        chunk = os.read(master, 16384)
                    except OSError:  # EIO is the Linux PTY EOF
                        chunk = b""
                    if not chunk:
                        raise AssertionError(f"shell exited before {expected!r}: {bytes(output)!r}")
                    output.extend(chunk)
            consumed = output.index(expected, consumed) + len(expected)
            if callable(payload):
                payload(proc)
            else:
                os.write(master, payload)
        deadline = time.monotonic() + 5
        while proc.poll() is None and time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], .1)
            if readable:
                try:
                    output.extend(os.read(master, 16384))
                except OSError:
                    break
        status = proc.wait(timeout=2)
        if check_terminal:
            flags = termios.tcgetattr(master)[3]
            assert flags & termios.ECHO and flags & termios.ICANON, "terminal left raw"
        return status, bytes(output)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=2)
        os.close(master)


class ShellTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bmc = Dummy()
        cls.bmc.__enter__()

    @classmethod
    def tearDownClass(cls):
        cls.bmc.__exit__(None, None, None)
        SCRIPT.unlink(missing_ok=True)

    def test_editor_history_cursor_and_cancellation(self):
        status, data = pty([
            (b"ipmitool> ", b"echo first\r"),
            (b"first \r\nipmitool> ", b"\x1b[A\r"),  # previous command
            (b"first \r\nipmitool> ", b"echo abX\x1b[D\x7fc\r"),
            (b"acX \r\nipmitool> ", b"echo ignore\x03"),  # Ctrl-C discards current line
            (b"^C\r\nipmitool> ", b"echo saved\r"),
            (b"saved \r\nipmitool> ", b"\x1b[A\x1b[B" + b"echo done\r"),
            (b"done \r\nipmitool> ", b"echo miX\x1b[H" + b"\x1b[C" * 5 + b"s\x1b[F\x1b[D\x1b[3~le\r"),
            (b"smile \r\nipmitool> ", "echo caféX\x1b[D\x7fe\r".encode()),
            (b"cafeX \r\nipmitool> ", b"exit\r"),
        ])
        self.assertEqual(status, 0, data)
        self.assertEqual(data.count(b"first \r\n"), 2)
        self.assertNotIn(b"ignore \r\n", data)
        self.assertIn(b"acX \r\n", data)
        self.assertIn(b"saved \r\n", data)
        self.assertIn(b"smile \r\n", data)
        self.assertIn(b"cafeX \r\n", data)

    def test_shared_cli_dispatch_and_help(self):
        def run(binary):
            return subprocess.run(
                [binary, "-I", "dummy", "shell"],
                input=b"help\necho via-shell\nnot-a-command\nexit\n",
                capture_output=True, env=env(), timeout=5, check=False,
            )

        zig = run(ZIG)
        self.assertEqual(zig.returncode, 0, zig.stderr)
        self.assertIn(b"Commands:", zig.stderr)
        self.assertIn(b"via-shell ", zig.stdout)
        self.assertIn(b"Invalid command: not-a-command", zig.stderr)
        if C:
            oracle = run(C)
            self.assertEqual(
                (zig.returncode, zig.stdout, zig.stderr),
                (oracle.returncode, oracle.stdout, oracle.stderr),
            )

    def test_eof_and_malformed_command(self):
        status, data = pty([
            (b"ipmitool> ", b"echo 'oops\r"),
            (b"UnterminatedQuote\r\nipmitool> ", b"\x04"),
        ])
        self.assertNotEqual(status, 0)
        self.assertIn(b"Invalid command line", data)

    def test_external_signal_restores_terminal(self):
        status, data = pty([
            (b"ipmitool> ", lambda proc: os.kill(proc.pid, signal.SIGTERM)),
        ], check_terminal=True)
        self.assertEqual(status, -signal.SIGTERM, data)

    def test_output_failure_reports_error_and_restores_terminal(self):
        master, slave = os.openpty()
        proc = None
        try:
            with open("/dev/full", "wb") as full:
                proc = subprocess.Popen(
                    [ZIG, "-I", "dummy", "shell"], stdin=slave, stdout=full,
                    stderr=subprocess.PIPE, env=env(), close_fds=True,
                )
            os.close(slave)
            slave = -1
            os.write(master, b"exit\r")
            _, stderr = proc.communicate(timeout=5)
            self.assertNotEqual(proc.returncode, 0, stderr)
            self.assertIn(b"shell: Io", stderr)
            flags = termios.tcgetattr(master)[3]
            self.assertTrue(flags & termios.ECHO and flags & termios.ICANON, "terminal left raw")
        finally:
            if proc is not None and proc.poll() is None:
                proc.kill()
                proc.wait(timeout=2)
            if slave != -1:
                os.close(slave)
            os.close(master)

    def test_redraw_failure_reports_error_and_restores_terminal(self):
        master, slave = os.openpty()
        proc = None
        try:
            proc = subprocess.Popen(
                [ZIG, "-I", "dummy", "shell"], stdin=slave, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, env=env(), close_fds=True,
                restore_signals=False,  # Ignore SIGPIPE so write returns EPIPE.
            )
            os.close(slave)
            slave = -1
            self.assertTrue(select.select([proc.stdout], [], [], 5)[0], "shell did not write prompt")
            self.assertEqual(proc.stdout.read(len(b"ipmitool> ")), b"ipmitool> ")
            proc.stdout.close()
            os.write(master, b"x\x7fexit\r")
            status = proc.wait(timeout=5)
            stderr = proc.stderr.read()
            self.assertNotEqual(status, 0, stderr)
            self.assertIn(b"shell: Io", stderr)
            flags = termios.tcgetattr(master)[3]
            self.assertTrue(flags & termios.ECHO and flags & termios.ICANON, "terminal left raw")
        finally:
            if proc is not None:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=2)
                proc.stdout.close()
                proc.stderr.close()
            if slave != -1:
                os.close(slave)
            os.close(master)

    def test_dumb_terminal_editing(self):
        status, data = pty([
            (b"ipmitool> ", b"echo ac\x1b[Db\r"),
            (b"abc \r\nipmitool> ", b"exit\r"),
        ], terminal="dumb")
        self.assertEqual(status, 0, data)
        self.assertNotIn(b"\x1b[2K", data)
        self.assertIn(b"abc ", data)

    def test_set_exec_and_environment(self):
        SCRIPT.write_text(
            "# script\n"
            "echo 'two words' \"plain value\" # ignored\n"
            "set csv\nset verbose bad\nset localaddr 0x20\n"
            "echo done\n",
            encoding="utf-8",
        )
        zig = cli(ZIG, "exec", str(SCRIPT))
        self.assertNotEqual(zig.returncode, 0)
        self.assertIn(b"two words plain value", zig.stdout)
        self.assertIn(b"done ", zig.stdout)
        self.assertIn(b"invalid", zig.stderr)
        if C:
            oracle = cli(C, "exec", str(SCRIPT))
            self.assertEqual(
                (zig.returncode, zig.stdout, zig.stderr),
                (oracle.returncode, oracle.stdout, oracle.stderr),
            )
        # C's quote parser replaces literal ~ with a space within quotes.
        # The Zig tokenizer deliberately keeps it instead.
        SCRIPT.write_text("echo 'literal~ value'\n", encoding="utf-8")
        self.assertIn(b"literal~ value ", cli(ZIG, "exec", str(SCRIPT)).stdout)
        SCRIPT.write_text("echo '#quoted' # trailing\n", encoding="utf-8")
        self.assertIn(b"#quoted ", cli(ZIG, "exec", str(SCRIPT)).stdout)
        for args in [
            ("echo", "hello", "world"), ("set", "csv", "bad"),
            ("set", "port", "65536"), ("set", "localaddr", "0x20"),
            ("set", "targetaddr", "0xff"), ("set", "host", "example.com"),
            ("set", "privlvl", "invalid"), ("set", "privlvl", "ADMINISTRATOR"),
            ("set", "authtype", "invalid"), ("set", "authtype", "MD5"),
            ("set", "user", "operator"), ("set", "pass", "test"),
            ("set", "verbose"), ("set", "csv"), ("set", "csv", "2"),
            ("set", "port", "623"), ("set", "targetaddr", "bad"),
            ("set", "hostname"), ("set", "unknown", "value"),
            ("set", "help"), ("set",), ("exec",),
        ]:
            with self.subTest(args=args):
                zig = cli(ZIG, *args)
                if C:
                    oracle = cli(C, *args)
                    self.assertEqual(
                        (zig.returncode, zig.stdout, zig.stderr),
                        (oracle.returncode, oracle.stdout, oracle.stderr),
                        args,
                    )

    def test_redirected_input_eof_and_status(self):
        run = subprocess.run(
            [ZIG, "-I", "dummy", "shell"], input=b"echo piped\nnot-a-command\n",
            capture_output=True, env=env(), timeout=5, check=False,
        )
        self.assertNotEqual(run.returncode, 0)
        self.assertIn(b"piped ", run.stdout)
        self.assertIn(b"Invalid command: not-a-command", run.stderr)
        last = subprocess.run(
            [ZIG, "-I", "dummy", "shell"], input=b"echo unterminated",
            capture_output=True, env=env(), timeout=5, check=False,
        )
        self.assertEqual(last.returncode, 0, last.stderr)
        self.assertIn(b"unterminated ", last.stdout)

    def test_script_truncation_and_unknown_command(self):
        SCRIPT.write_text("echo " + "a" * 2050 + "\necho after\n", encoding="utf-8")
        zig = cli(ZIG, "exec", str(SCRIPT))
        self.assertNotEqual(zig.returncode, 0)
        self.assertIn(b"exceeds 2047 bytes", zig.stderr)
        self.assertIn(b"after ", zig.stdout)
        SCRIPT.write_text("echo " + "a" * 2042, encoding="utf-8")
        zig = cli(ZIG, "exec", str(SCRIPT))
        self.assertEqual(zig.returncode, 0)
        self.assertNotIn(b"exceeds 2047", zig.stderr)
        SCRIPT.write_text("not-a-command\n", encoding="utf-8")
        zig = cli(ZIG, "exec", str(SCRIPT))
        self.assertNotEqual(zig.returncode, 0)
        self.assertIn(b"Invalid command: not-a-command", zig.stderr)
        SCRIPT.write_text("echo 'unfinished\necho after\n", encoding="utf-8")
        zig = cli(ZIG, "exec", str(SCRIPT))
        self.assertNotEqual(zig.returncode, 0)
        self.assertIn(b"UnterminatedQuote", zig.stderr)
        self.assertIn(b"after ", zig.stdout)


if __name__ == "__main__":
    unittest.main()
