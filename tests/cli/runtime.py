#!/usr/bin/env python3
"""Compare C and Zig frontends on paths requiring a terminal or live signal."""

import argparse
import os
import pty
import select
import shutil
import signal
import socket
import subprocess
import time


def environment(home):
    return {
        "PATH": "/usr/bin:/bin",
        "HOME": home,
        "LC_ALL": "C",
        "LANG": "C",
        "TZ": "UTC",
        "TERM": "dumb",
        "COLUMNS": "80",
    }


def exit_code(status):
    return os.waitstatus_to_exitcode(status)


def run_pty(binary, args, env, answer=None, interrupt=False):
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(binary, [binary, *args], env)
    output = bytearray()
    sent = False
    deadline = time.monotonic() + 8
    try:
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.1)[0]:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                output += chunk
            if not sent and (b"Password: " in output or b"Key: " in output):
                if interrupt:
                    os.kill(pid, signal.SIGINT)
                else:
                    os.write(fd, answer + b"\n")
                sent = True
        else:
            os.kill(pid, signal.SIGKILL)
            raise AssertionError("PTY frontend did not exit within 8 seconds")
    finally:
        os.close(fd)
        _, status = os.waitpid(pid, 0)
    if not sent:
        raise AssertionError("password/key prompt was not printed")
    return exit_code(status), bytes(output)


def run_signal(binary, env, work, password=None):
    path = os.path.join(work, "s")
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(path)
        listener.listen(1)
        listener.settimeout(8)
        args = [binary, "-I", "dummy"]
        if password is not None:
            args += ["-P", password]
        args += ["mc", "info"]
        child = subprocess.Popen(
            args,
            env={**env, "IPMI_DUMMY_SOCK": path},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            with listener.accept()[0] as connection:
                connection.settimeout(8)
                # The first PICMG discovery request has a 16-byte header plus
                # one byte of payload. Wait until the client is blocked in
                # recv() before sending SIGINT to its installed handler.
                request = bytearray()
                while len(request) < 17:
                    chunk = connection.recv(17 - len(request))
                    if not chunk:
                        raise AssertionError("dummy interface closed before its first request")
                    request += chunk
                if bytes(request[:3]) != b"\x2c\x00\x00":
                    raise AssertionError(f"unexpected first dummy request: {request[:3]!r}")
                if password is not None:
                    with open(f"/proc/{child.pid}/cmdline", "rb") as cmdline:
                        argv = cmdline.read().split(b"\0")
                    if argv[argv.index(b"-P") + 1] != b"X" * len(password):
                        raise AssertionError("frontend exposed the -P password in argv")
                child.send_signal(signal.SIGINT)
                stdout, stderr = child.communicate(timeout=8)
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()
    return child.returncode, stdout, stderr


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--oracle", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--daemon-oracle", required=True)
    parser.add_argument("--daemon-candidate", required=True)
    parser.add_argument("--work-dir", required=True)
    opts = parser.parse_args()
    oracle = os.path.abspath(opts.oracle)
    candidate = os.path.abspath(opts.candidate)
    work = os.path.abspath(opts.work_dir)
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    try:
        home = os.path.join(work, "home")
        os.makedirs(home)
        env = environment(home)
        # Symlinks ensure both executables see the same argv[0]/progname.
        paths = []
        for idx, binary in enumerate((oracle, candidate)):
            link_dir = os.path.join(work, str(idx))
            os.mkdir(link_dir)
            link = os.path.join(link_dir, "ipmitool")
            os.symlink(binary, link)
            paths.append(link)
        daemon_paths = []
        for idx, binary in enumerate((opts.daemon_oracle, opts.daemon_candidate)):
            link_dir = os.path.join(work, f"d{idx}")
            os.mkdir(link_dir)
            link = os.path.join(link_dir, "ipmievd")
            os.symlink(os.path.abspath(binary), link)
            daemon_paths.append(link)
        password_file = os.path.join(work, "password")
        with open(password_file, "w", encoding="ascii") as password:
            password.write("secret\n")
        os.chmod(password_file, 0o600)
        has_all_options = b"Prompt for remote password" in subprocess.run(
            [paths[0], "-h"], env=env, capture_output=True, timeout=8
        ).stderr

        checks = [
            ("version", lambda binary: subprocess.run(
                [binary, "-V"], env=env, capture_output=True, timeout=8
            )),
            ("help", lambda binary: subprocess.run(
                [binary, "-h"], env=env, capture_output=True, timeout=8
            )),
            ("unknown flag", lambda binary: subprocess.run(
                [binary, "-Q"], env=env, capture_output=True, timeout=8
            )),
            ("missing flag argument", lambda binary: subprocess.run(
                [binary, "-H"], env=env, capture_output=True, timeout=8
            )),
            ("device failure", lambda binary: subprocess.run(
                [binary, "-I", "open", "-d", "253", "mc", "info"],
                env=env, capture_output=True, timeout=8
            )),
            ("LAN address failure", lambda binary: subprocess.run(
                [binary, "-I", "lan", "-H", "bad host!", "-f", password_file, "mc", "info"],
                env=env, capture_output=True, timeout=8
            )),
            ("SIGINT at interface", lambda binary: run_signal(binary, env, work)),
        ]
        if has_all_options:
            checks.extend([
                ("password prompt", lambda binary: run_pty(
                    binary, ["-a", "-V"], env, answer=b"secret"
                )),
                ("key prompt", lambda binary: run_pty(
                    binary, ["-Y", "-V"], env, answer=b"secret"
                )),
                ("SIGINT at prompt", lambda binary: run_pty(
                    binary, ["-a", "-V"], env, interrupt=True
                )),
                ("password argv masking", lambda binary: run_signal(
                    binary, env, work, password="cliSecretValue"
                )),
            ])
        for name, check in checks:
            def normalize(result):
                if isinstance(result, subprocess.CompletedProcess):
                    return result.returncode, result.stdout, result.stderr
                return result

            expected, actual = (
                tuple(
                    value.replace(paths[idx].encode(), b"<BINARY>")
                    if isinstance(value, bytes) else value
                    for value in normalize(check(path))
                )
                for idx, path in enumerate(paths)
            )
            if expected != actual:
                raise AssertionError(f"{name}: C {expected!r} != Zig {actual!r}")
            if name.startswith("SIGINT") and expected[0] != 255:
                raise AssertionError(f"{name}: expected exit 255, got {expected[0]}")
            if name == "SIGINT at interface" and b"SIGN INT: Close Interface" not in expected[1]:
                raise AssertionError(f"{name}: missing interface-close message")
        for args in (["-V"], ["-h"], ["help"], ["-Q"], ["-d", "-1"]):
            expected, actual = (
                tuple(
                    value.replace(daemon_paths[idx].encode(), b"<BINARY>")
                    if isinstance(value, bytes) else value
                    for value in normalize(subprocess.run(
                        [path, *args], env=env, capture_output=True, timeout=8
                    ))
                )
                for idx, path in enumerate(daemon_paths)
            )
            if expected != actual:
                raise AssertionError(f"daemon {args}: C {expected!r} != Zig {actual!r}")
        print(f"CLI runtime: {len(checks) + 5} C/Zig stream, exit, PTY and signal checks passed")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
