"""Compare the Zig event daemon with C and Zig logger selections."""

import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

from process import Bmc, alive, wait_for


ROOT = Path(__file__).resolve().parents[2]
WORK = Path(sys.argv[3]).resolve()


def foreground(binary, env):
    process = subprocess.Popen(
        [binary, "-I", "dummy", "-vv", "sel", "nodaemon", "timeout=30"],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    output = bytearray()
    try:
        deadline = time.monotonic() + 5
        ready_message = b"Waiting for events...\n"
        while ready_message not in output:
            if process.poll() is not None or time.monotonic() >= deadline:
                raise AssertionError(f"listener stopped before readiness: {output!r}")
            ready, _, _ = select.select([process.stderr], [], [], 0.1)
            if ready:
                output.extend(os.read(process.stderr.fileno(), 4096))
        process.send_signal(signal.SIGINT)
        stdout, stderr = process.communicate(timeout=5)
        output.extend(stderr)
        assert process.returncode == 0
        assert b"SEL count is " in output
        assert b"SEL freespace is " in output
        # Another poll can begin between readiness and SIGINT; compare the
        # complete startup trace, not a scheduler-dependent later poll.
        ready_end = output.index(ready_message) + len(ready_message)
        return process.returncode, stdout, bytes(output[:ready_end])
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)


def daemon(binary, label, verbose, env, bmc):
    pidfile = ROOT / ".zig-cache" / f"p{os.getpid()}{label}{verbose}"
    syslog = WORK / f"log-{label}-{verbose}"
    assert len(str(pidfile)) < 64
    assert not pidfile.exists()
    env = {**env, "IPMITOOL_TEST_SYSLOG_PATH": str(syslog)}
    daemon_pid = None
    try:
        args = [binary, "-I", "dummy"]
        if verbose:
            args.append("-vv")
        args.extend(["sel", "daemon", "timeout=30", f"pidfile={pidfile}"])
        parent = subprocess.run(
            args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=5, check=True,
        )
        assert parent.returncode == 0
        wait_for(pidfile.exists, "event daemon PID file")
        daemon_pid = int(pidfile.read_text(encoding="ascii").strip())
        wait_for(lambda: b"Waiting for events..." in syslog.read_bytes() if syslog.exists() else False,
                 "event daemon syslog readiness")
        assert alive(daemon_pid)
        os.kill(daemon_pid, signal.SIGTERM)
        wait_for(lambda: not pidfile.exists(), "event daemon PID cleanup")
        wait_for(lambda: not alive(daemon_pid), "event daemon shutdown")
        daemon_pid = None
        output = syslog.read_bytes()
        assert b"openlog:ipmievd:160\n" in output, output
        assert b"syslog:5:Reading sensors...\n" in output
        assert b"syslog:5:Waiting for events...\n" in output
        if verbose:
            assert b"syslog:7:SEL count is " in output, output
        else:
            assert b"SEL count is " not in output, output
        assert output.endswith(b"closelog\n")
        return output
    finally:
        if daemon_pid is not None and alive(daemon_pid):
            os.kill(daemon_pid, signal.SIGKILL)
        pidfile.unlink(missing_ok=True)
        syslog.unlink(missing_ok=True)


def run(binary, label):
    socket_path = WORK / f"s{label}"
    assert len(str(socket_path)) < 107
    bmc = Bmc(str(socket_path))
    env = {**os.environ, "IPMI_DUMMY_SOCK": str(socket_path), "LC_ALL": "C"}
    results = {}
    try:
        for case, args, expected in (
            ("help", ["sel", "help"], b"Options:"),
            ("daemon-option", ["sel", "daemon=invalid"], b"Invalid daemon setting"),
            ("timeout", ["sel", "timeout=bad"], b"Invalid input given or out of range"),
            ("pid-length", ["sel", "pidfile=" + "x" * 64], b"The pidfile path is too long"),
        ):
            result = subprocess.run(
                [binary, "-I", "dummy", *args], env=env,
                capture_output=True, timeout=5, check=False,
            )
            assert expected in result.stderr, (case, result.stderr)
            results[case] = result.returncode, result.stdout, result.stderr
        results["foreground"] = foreground(binary, env)
        results["daemon"] = daemon(binary, label, False, env, bmc)
        results["daemon-verbose"] = daemon(binary, label, True, env, bmc)
        return results
    finally:
        bmc.close()


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    oracle = Path(sys.argv[1]).resolve()
    candidate = Path(sys.argv[2]).resolve()
    links = []
    try:
        for label, target in (("c", oracle), ("zig", candidate)):
            directory = WORK / label
            directory.mkdir()
            link = directory / "ipmievd"
            link.symlink_to(target)
            links.append(link)
        c_results = run(str(links[0]), "c")
        zig_results = run(str(links[1]), "z")
        assert c_results == zig_results, {
            key: (c_results[key], zig_results[key])
            for key in c_results if c_results[key] != zig_results[key]
        }
    finally:
        for link in links:
            link.unlink(missing_ok=True)
            link.parent.rmdir()


if __name__ == "__main__":
    main()
