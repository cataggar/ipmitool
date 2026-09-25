"""Exercise ipmievd against the dummy BMC without hardware.

The C oracle supports foreground-only checks here: its pidfile= parser does
not accept a path, so testing its daemon mode would write outside this tree.
"""

import os
import select
import signal
import socket
import struct
import subprocess
import sys
import threading
import time


def wait_for(predicate, label, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.025)
    raise AssertionError(f"timed out waiting for {label}")


def read_exact(connection, length, stopped):
    data = bytearray()
    while len(data) < length:
        try:
            chunk = connection.recv(length - len(data))
        except socket.timeout:
            if stopped.is_set():
                raise EOFError
            continue
        if not chunk:
            raise EOFError
        data.extend(chunk)
    return data


class Bmc:
    def __init__(self, path):
        self.path = path
        self.count = 0
        self.info_count = 0
        self.stopped = threading.Event()
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.bind(path)
        self.socket.listen(4)
        self.socket.settimeout(0.1)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stopped.is_set():
            try:
                connection, _ = self.socket.accept()
            except socket.timeout:
                continue
            with connection:
                connection.settimeout(0.1)
                try:
                    while not self.stopped.is_set():
                        request = read_exact(connection, 16, self.stopped)
                        netfn, cmd = request[0], request[2]
                        size = struct.unpack_from("=H", request, 4)[0]
                        read_exact(connection, size, self.stopped)
                        if netfn == 0x3F and cmd == 0xFF:
                            break
                        self.count += 1
                        info = netfn == 0x0A and cmd == 0x40
                        if info:
                            self.info_count += 1
                        data = bytearray(14) if info else b""
                        if info:
                            data[0] = 0x51
                        response = bytearray(24)
                        response[0] = netfn | 1
                        response[1] = cmd
                        response[4] = 0 if info else 0xC1
                        struct.pack_into("=i", response, 8, len(data))
                        connection.sendall(response + data)
                except (EOFError, BrokenPipeError, ConnectionResetError, socket.timeout):
                    pass

    def close(self):
        self.stopped.set()
        self.thread.join(3)
        self.socket.close()
        os.unlink(self.path)
        assert not self.thread.is_alive(), "BMC server did not stop"


def alive(pid):
    try:
        with open(f"/proc/{pid}/stat", encoding="ascii") as proc:
            return proc.read().split()[2] != "Z"
    except FileNotFoundError:
        return False


def wait_for_foreground(process):
    output = bytearray()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError("foreground listener exited before readiness")
        ready, _, _ = select.select([process.stderr], [], [], 0.1)
        if ready:
            output.extend(os.read(process.stderr.fileno(), 4096))
            if b"Waiting for events..." in output:
                return
    raise AssertionError(f"foreground listener not ready: {output[-300:]!r}")


def run():
    binary = os.path.abspath(sys.argv[1])
    foreground_only = "--foreground-only" in sys.argv[2:]
    cache = os.path.abspath(".zig-cache")
    pidfile = os.path.join(cache, f"p{os.getpid()}")
    sockfile = os.path.join(cache, f"s{os.getpid()}")
    assert len(pidfile) < 64
    bmc = Bmc(sockfile)
    env = {**os.environ, "IPMI_DUMMY_SOCK": sockfile}
    daemon_pid = None
    foreground = None
    try:
        foreground = subprocess.Popen(
            [binary, "-I", "dummy", "sel", "nodaemon", "timeout=1"],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        wait_for_foreground(foreground)
        foreground.send_signal(signal.SIGINT)
        assert foreground.wait(timeout=5) == 0, "foreground SIGINT exit failed"
        foreground.stderr.close()
        foreground = None
        assert not os.path.exists(pidfile), "foreground wrote a PID file"
        if foreground_only:
            return

        for sig in (signal.SIGTERM, signal.SIGQUIT):
            before = bmc.info_count
            parent = subprocess.run(
                [binary, "-I", "dummy", "sel", "daemon", "timeout=1",
                 "pidfile=" + pidfile],
                env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=5, check=True,
            )
            assert parent.returncode == 0
            def pid_ready():
                if not os.path.exists(pidfile):
                    return False
                with open(pidfile, encoding="ascii") as file:
                    return file.read().strip().isdecimal()

            wait_for(pid_ready, "daemon PID file")
            with open(pidfile, encoding="ascii") as file:
                daemon_pid = int(file.read().strip())
            wait_for(lambda: bmc.info_count > before, "daemon SEL request")
            assert alive(daemon_pid), "daemon exited before signal"
            os.kill(daemon_pid, sig)
            wait_for(lambda: not os.path.exists(pidfile), "PID cleanup")
            wait_for(lambda: not alive(daemon_pid), "daemon shutdown")
            daemon_pid = None
    finally:
        if foreground is not None and foreground.poll() is None:
            foreground.kill()
            foreground.wait(timeout=5)
        if daemon_pid is None and os.path.exists(pidfile):
            with open(pidfile, encoding="ascii") as file:
                text = file.read().strip()
            if text.isdecimal():
                daemon_pid = int(text)
        if daemon_pid is not None and alive(daemon_pid):
            os.kill(daemon_pid, signal.SIGKILL)
        if os.path.exists(pidfile):
            os.unlink(pidfile)
        bmc.close()


if __name__ == "__main__":
    run()
