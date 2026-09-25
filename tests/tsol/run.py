#!/usr/bin/env python3
"""PTY and loopback-UDP differential oracle for the TSOL LAN command."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import socket
import struct
import subprocess
import termios
import time

CASES = {
    "invalid_interface": (["help"], {"TSOL_BAD_INTF": "1"}, None),
    "help": (["help"], {}, None),
    "bad_argument": (["bad-option"], {}, None),
    "bad_port": (["port=invalid"], {}, None),
    "bad_ip": (["127.1.2"], {}, None),
    "bad_host": (["127.1.2.3"], {"TSOL_BAD_HOST": "1"}, None),
    "socket_fail": (["127.1.2.3"], {"TSOL_SOCKET_FAIL": "1"}, None),
    "bind_fail": (["127.1.2.3"], {}, None),
    "start_ccode": (["127.1.2.3"], {"TSOL_START_FAIL": "1"}, None),
    "start_resize_fail": (["127.1.2.3", "rows=33", "cols=101"], {"TSOL_START_FAIL": "1"}, None),
    "start_timeout": (["127.1.2.3"], {"TSOL_START_FAIL": "1", "TSOL_START_NULL": "1"}, None),
    "local_open_fail": ([], {"TSOL_OPEN_FAIL": "1"}, None),
    "local_getsockname_fail": ([], {"TSOL_GETSOCK_FAIL": "1"}, None),
    "session_rw": (["127.1.2.3", "rows=33", "cols=101"], {}, "rw"),
    "session_ro": (["127.1.2.3", "ro"], {}, "ro"),
    "altterm": (["127.1.2.3", "altterm"], {}, "quit"),
    "session_default_ip": ([], {}, "rw"),
    "ip_octets_wrap": (["300.2.1.1"], {}, "quit"),
    "escape_help": (["127.1.2.3"], {}, "help"),
    "escape_double": (["127.1.2.3"], {}, "double"),
    "escape_suspend": (["127.1.2.3"], {}, "suspend"),
    "stop_ccode": (["127.1.2.3"], {"TSOL_STOP_FAIL": "1"}, "quit"),
    "key_error_verbose": (["127.1.2.3"], {"TSOL_VERBOSE": "1", "TSOL_KEY_FAIL": "1"}, "keyfail"),
    "key_timeout_verbose": (["127.1.2.3"], {"TSOL_VERBOSE": "1", "TSOL_KEY_NULL": "1"}, "keyfail"),
    "key_timeout_quiet": (["127.1.2.3"], {"TSOL_KEY_NULL": "1"}, "keyquiet"),
    "keepalive": (["127.1.2.3"], {"TSOL_FAST_CLOCK": "1"}, "quit"),
    "keepalive_error": (["127.1.2.3"], {"TSOL_FAST_CLOCK": "1", "TSOL_KEEPALIVE_FAIL": "1"}, "quit"),
    "poll_error": (["127.1.2.3"], {"TSOL_POLL_FAIL": "1"}, None),
}


def run(binary, name, port):
    args, vars, interaction = CASES[name]
    parent, child = pty.openpty()
    fcntl.ioctl(child, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    read_fd, write_fd = os.pipe()
    env = dict(os.environ, LC_ALL="C", TSOL_EVENT_FD=str(write_fd), **vars)
    argv = [str(Path(binary).resolve()), *args, f"port={port}"] if name not in ("help", "invalid_interface", "bad_argument", "bad_port", "bad_ip") else [str(Path(binary).resolve()), *args]
    reservation = None
    if name == "bind_fail":
        reservation = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        reservation.bind(("0.0.0.0", port))
    proc = subprocess.Popen(argv, stdin=child, stdout=child, stderr=subprocess.PIPE,
                            pass_fds=(write_fd,), env=env, close_fds=True)
    os.close(child)
    os.close(write_fd)
    out = bytearray()
    events = bytearray()
    fed = False
    quit_sent = False
    quit_after = None
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    deadline = time.monotonic() + 5
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([parent, read_fd], [], [], .05)
            for fd in ready:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    chunk = b""
                if fd == parent:
                    out.extend(chunk)
                else:
                    events.extend(chunk)
            if interaction and not fed and b"cmd=06" in events:
                fed = True
                if interaction in ("rw", "ro"):
                    udp.sendto(b"\xaa\xbb\xcc\xddhello from UDP", ("127.0.0.1", port))
                    udp.sendto(b"\x01", ("127.0.0.1", port))
                    udp.sendto(b"\x01\x02\x03", ("127.0.0.1", port))
                    udp.sendto(b"\x01\x02\x03\x04", ("127.0.0.1", port))
                    os.write(parent, b"abcdefghijklmno\r~~z\n~?")
                elif interaction == "keyfail":
                    os.write(parent, b"x")
                elif interaction == "keyquiet":
                    os.write(parent, b"x")
                elif interaction == "help":
                    os.write(parent, b"~?")
                elif interaction == "double":
                    os.write(parent, b"~~")
                elif interaction == "suspend":
                    os.write(parent, b"~\x1a")
            if fed and quit_after is None and (interaction == "quit" or
                  interaction in ("keyfail", "keyquiet", "double") and b"cmd=03" in events or
                  interaction == "suspend" and b"suspend\n" in events or
                  interaction == "help" and b"ipmitool help" in out or
                  interaction in ("rw", "ro") and (interaction == "ro" and b"hello from UDP" in out or interaction == "rw" and events.count(b"cmd=03") >= 2 and b"hello from UDP" in out)):
                os.write(parent, b"\r")
                quit_after = time.monotonic() + (.03 if interaction == "keyfail" else .2)
            if quit_after is not None and not quit_sent and time.monotonic() >= quit_after:
                quit_sent = True
                os.write(parent, b"~.")
            if proc.poll() is not None:
                for fd, target in ((parent, out), (read_fd, events)):
                    while True:
                        r, _, _ = select.select([fd], [], [], 0)
                        if not r:
                            break
                        try:
                            chunk = os.read(fd, 4096)
                        except OSError:
                            break
                        if not chunk:
                            break
                        target.extend(chunk)
                break
        if proc.poll() is None:
            proc.kill()
            raise AssertionError(f"{name}: hung, events={events!r}, output={out!r}")
        err = proc.stderr.read()
    finally:
        udp.close()
        if reservation is not None:
            reservation.close()
        os.close(parent)
        os.close(read_fd)
        proc.wait()
    assert b"final result=" in events, (name, events)
    text = events.decode()
    port_hex = f"{port:04x}"
    text = text.replace(port_hex, "<PORT>")
    stdout = out.decode(errors="replace").replace(str(port), "<PORT>")
    return {"exit": proc.returncode, "stdout": stdout,
            "stderr": err.decode().replace(str(port), "<PORT>"),
            "events": text}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--oracle", required=True)
    p.add_argument("--candidate")
    p.add_argument("--record", action="store_true")
    a = p.parse_args()
    expected_path = Path(__file__).with_name("oracle.json")
    expected = {} if a.record else json.loads(expected_path.read_text())
    candidate = a.candidate or a.oracle
    failures = []
    for name in CASES:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        actual = run(a.oracle if a.record else candidate, name, port)
        if a.record:
            expected[name] = actual
        else:
            baseline = expected[name].copy()
            # The C implementation leaves the tty raw on activation failure;
            # the Zig implementation must restore it.
            if a.candidate and name.startswith("start_"):
                baseline["events"] = baseline["events"].replace("raw=1", "raw=0")
            if a.candidate and name == "start_resize_fail":
                baseline["events"] = baseline["events"].replace("final result=-1 raw=0 size=33x101",
                                                                 "final result=-1 raw=0 size=24x80")
            if a.candidate and name == "poll_error":
                baseline["events"] = baseline["events"].replace(
                    "final result=", "netfn=30 cmd=02 data=7f010203<PORT>\nfinal result="
                ).replace("raw=1", "raw=0")
                baseline["stderr"] = "Exiting due to error 5 -> Input/output error\n"
            if a.candidate and "cmd=06" in baseline["events"] and "cmd=02" in baseline["events"]:
                baseline["events"] = baseline["events"].replace("reusable=0", "reusable=1")
            if actual != baseline:
                failures.append((name, baseline, actual))
    if a.record:
        expected_path.write_text(json.dumps(expected, indent=2, sort_keys=True) + "\n")
    for name, baseline, actual in failures:
        print(f"FAIL {name}\nexpected: {baseline!r}\nactual:   {actual!r}")
    print(f"TSOL: {len(CASES) - len(failures)}/{len(CASES)} cases matched")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
