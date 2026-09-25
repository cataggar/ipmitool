"""Real serial PTY emulator: compare Zig and C CLI output and bytes on the wire.

Run with two ipmitool binaries (C oracle first, Zig port second). The device
is a fresh PTY per case; no physical BMC, privileged device, or external Python
package is needed.
"""

import os
import pty
import select
import subprocess
import sys
import time


def checksum(data):
    return -sum(data) & 255


ESCAPE = {0xA0: 0xB0, 0xA5: 0xB5, 0xA6: 0xB6, 0xAA: 0xBA, 0x1B: 0x3B}
UNESCAPE = {v: k for k, v in ESCAPE.items()}


def frame(mode, data):
    if mode == "basic":
        return bytes([0xA0]) + b"".join(
            bytes((0xAA, ESCAPE[b])) if b in ESCAPE else bytes((b,))
            for b in data
        ) + bytes([0xA5])
    return b"[" + bytes(data).hex().encode() + b"]\r\n"


def parse(mode, pending):
    if mode == "terminal":
        start = pending.find(b"[")
        if start < 0:
            pending.clear()
            return None
        if start:
            del pending[:start]
        end = pending.find(b"]\r\n")
        if end < 0:
            return None
        raw = bytes.fromhex(pending[1:end].decode())
        del pending[:end + 3]
        return raw
    start = pending.find(b"\xa0")
    if start < 0:
        pending.clear()
        return None
    if start:
        del pending[:start]
    end = pending.find(b"\xa5", 1)
    if end < 0:
        return None
    raw = bytearray()
    i = 1
    while i < end:
        if pending[i] == 0xAA:
            i += 1
            raw.append(UNESCAPE[pending[i]])
        else:
            raw.append(pending[i])
        i += 1
    del pending[:end + 1]
    return bytes(raw)


def reply(mode, request, payload=b"\x00\xa0\xa5\xaa\x1b\x00"):
    if mode == "terminal":
        return bytes((request[0] | 4, request[1], request[2])) + payload
    sa, netfn, csum1, requester, seq, cmd = request[:6]
    assert checksum(request[:2]) == csum1, request.hex()
    assert checksum(request[3:]) == 0, request.hex()
    head = bytes((requester, netfn | 4))
    tail = bytes((sa, seq, cmd)) + payload
    return head + bytes((checksum(head),)) + tail + bytes((checksum(tail),))


def run(binary, mode, case):
    master, slave = pty.openpty()
    path = os.ttyname(slave)
    os.close(slave)
    extra = ["-t", "0x30", "-b", "0x01"] if case == "bridge" else []
    if case in ("double", "system-double"):
        extra = ["-t", "0x30", "-b", "0x01", "-T", "0x32", "-B", "0x02"]
    if case == "system":
        extra = ["-t", "0x30", "-b", "0x01"]
    device = path + ":9600" + (":S" if case in ("system", "system-double") else "")
    args = ["ipmitool", "-I", "serial-" + mode, "-D", device, "-N", "1", "-R", "2"]
    args += extra + ["raw", "0x2e", "0x91", "0xa0", "0xa5", "0xaa", "0x1b", "0x00"]
    if case == "bad-baud":
        args[args.index("-D") + 1] = path + ":12345"
    if case == "bad-device":
        args[args.index("-D") + 1] = path + "/missing"
    proc = subprocess.Popen(args, executable=binary, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    received = []
    pending = bytearray()
    sent = 0
    last_bridge = None
    deadline = time.monotonic() + 10
    try:
        while proc.poll() is None and time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.05)
            if not ready:
                continue
            try:
                data = os.read(master, 4096)
            except OSError:  # PTY not yet opened, or has closed.
                continue
            pending.extend(data)
            while True:
                packet = parse(mode, pending)
                if packet is None:
                    break
                received.append(packet)
                sent += 1
                cmd = packet[5 if mode == "basic" else 2]
                raw_attempts = sum(
                    p[5 if mode == "basic" else 2] == 0x91 for p in received
                )
                if case == "timeout" and cmd == 0x91:
                    continue
                if case == "retry" and cmd == 0x91 and raw_attempts == 1:
                    continue
                if case == "invalid" and cmd == 0x91 and raw_attempts == 1:
                    corrupt = bytearray(reply(mode, packet))
                    if mode == "basic":
                        corrupt[-1] ^= 1
                    else:
                        corrupt[1] ^= 0x40
                    os.write(master, frame(mode, corrupt))
                    continue
                if case == "malformed" and cmd == 0x91 and raw_attempts == 1:
                    os.write(master, b"\xa0\xaa\x99\xa5" if mode == "basic" else b"[zz]\r\n")
                    continue
                if case == "rejected" and mode == "terminal" and cmd == 0x91 and raw_attempts == 1:
                    os.write(master, b"[ERR 80]\r\n")
                    continue
                if case == "unrelated" and cmd == 0x91:
                    wrong = bytearray(reply(mode, packet))
                    wrong[5 if mode == "basic" else 2] ^= 1
                    if mode == "basic":
                        wrong[-1] = checksum(wrong[3:-1])
                    os.write(master, frame(mode, wrong))
                    time.sleep(0.08)
                if case == "fragmented" and cmd == 0x91:
                    wire = frame(mode, reply(mode, packet))
                    cut = wire.index(b"\xaa") + 1 if mode == "basic" else 5
                    os.write(master, wire[:cut])
                    time.sleep(0.08)
                    os.write(master, wire[cut:])
                    continue
                if case == "wrapped" and mode == "terminal" and cmd == 0x91:
                    wire = frame(mode, reply(mode, packet))
                    os.write(master, wire[:9] + b"\r\n " + wire[9:])
                    continue
                if case in ("system", "system-double") and cmd == 0x33 and last_bridge is not None:
                    outer = last_bridge[7:13] if mode == "basic" else last_bridge[4:10]
                    seq = outer[4] & 0xFC
                    netfn = (outer[1] | 4) | 2
                    if case == "system-double":
                        target = bytes((0x20, 0xbc, checksum((0x20, 0xbc)),
                                        0x30, seq, 0x91, 0, 0x5a))
                        target += bytes((checksum(target[3:]),))
                        mid_data = b"\x00\x41" + target[1:]
                        sa, cmd_inner, channel = 0x32, 0x34, 0x02
                    else:
                        sa, cmd_inner, channel = 0x30, 0x91, 0x01
                        mid_data = b"\x00\x5a"
                    ipmb = bytes((0x20, netfn, checksum((0x20, netfn)),
                                  sa, seq, cmd_inner)) + mid_data
                    ipmb += bytes((checksum(ipmb[3:]),))
                    os.write(master, frame(mode, reply(mode, packet, bytes((0, channel)) + ipmb[1:])))
                    continue
                if case in ("bridge", "double", "system", "system-double") and cmd == 0x34:
                    # First BMC Send Message result is a tracked ACK.  The
                    # addressed response will arrive as a separate packet.
                    os.write(master, frame(mode, reply(mode, packet, b"\x00")))
                    last_bridge = packet
                    inner = packet[7:13] if mode == "basic" else packet[4:10]
                    if case not in ("system", "system-double"):
                        time.sleep(0.08)
                        if case == "double":
                            seq = inner[4]
                            inner_ipmb = bytes((0x20, 0xbc, checksum((0x20, 0xbc)),
                                                0x30, seq, 0x91, 0, 0x5a))
                            inner_ipmb += bytes((checksum(inner_ipmb[3:]),))
                            payload = b"\x00\x41" + inner_ipmb[1:]
                            if mode == "basic":
                                mid = bytes(inner) + bytes((checksum(inner[3:]),))
                                inner_reply = reply(mode, mid, payload)
                            else:
                                inner_reply = bytes((inner[1] | 4, inner[4] & 0xfc, inner[5])) + payload
                        elif mode == "basic":
                            inner_req = bytes(inner) + bytes((checksum(inner[3:]),))
                            inner_reply = reply(mode, inner_req, b"\x00\x5a")
                        else:
                            inner_reply = bytes((inner[1] | 4, inner[4] & 0xfc, inner[5], 0, 0x5a))
                        os.write(master, frame(mode, inner_reply))
                    continue
                os.write(master, frame(mode, reply(mode, packet)))
        if proc.poll() is None:
            proc.kill()
            raise AssertionError(f"CLI timed out: {mode}/{case}")
        out, err = proc.communicate(timeout=2)
        return proc.returncode, out, err, received
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.communicate()
        os.close(master)


def main():
    oracle, zig = sys.argv[1:]
    cases = ("normal", "fragmented", "wrapped", "unrelated", "retry", "invalid", "malformed", "rejected", "timeout",
             "bad-baud", "bad-device", "bridge", "double", "system", "system-double")
    count = 0
    for mode in ("basic", "terminal"):
        for case in cases:
            if mode == "basic" and case in ("wrapped", "rejected"):
                continue
            expected = run(oracle, mode, case)
            actual = run(zig, mode, case)
            assert actual == expected, (
                f"{mode}/{case}\nC: {expected}\nZig: {actual}")
            if case == "normal":
                wire = expected[3][-1]
                if mode == "basic":
                    assert wire[:6] == bytes.fromhex("20b828810c91"), wire.hex()
                else:
                    assert wire[:3] == bytes.fromhex("b80c91"), wire.hex()
                assert expected[0] == 0, expected
            if case in ("fragmented", "wrapped", "unrelated", "retry", "invalid", "malformed", "rejected", "bridge", "double", "system", "system-double"):
                assert actual[0] == 0, actual
                if case in ("bridge", "double", "system", "system-double"):
                    assert actual[1] == b" 5a\n", actual
            if case in ("system", "system-double"):
                assert actual[3][-1][5 if mode == "basic" else 2] == 0x33, actual
            if case == "retry":
                assert sum(p[5 if mode == "basic" else 2] == 0x91 for p in actual[3]) == 2 and actual[0] == 0, actual
            if case == "timeout":
                assert sum(p[5 if mode == "basic" else 2] == 0x91 for p in actual[3]) == 2 and actual[0] != 0, actual
            print("ok", mode, case)
            count += 1
    print(f"serial PTY: {count} oracle comparisons passed")


if __name__ == "__main__":
    main()
