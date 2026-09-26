"""Byte-compare the original and selected OpenIPMI verbose diagnostics."""

import subprocess
import sys

oracle = subprocess.run([sys.argv[1]], capture_output=True, check=True)
selected = subprocess.run([sys.argv[2]], capture_output=True, check=True)
assert oracle.stdout == selected.stdout == b""
if oracle.stderr != selected.stderr:
    import difflib

    print(
        "".join(
            difflib.unified_diff(
                oracle.stderr.decode().splitlines(keepends=True),
                selected.stderr.decode().splitlines(keepends=True),
                fromfile="original C",
                tofile="selected Zig",
            )
        ),
        file=sys.stderr,
    )
    sys.exit(1)

text = selected.stderr
assert text.count(b"OpenIPMI Request Message Header:\n") == 6
assert text.count(b"Converting message:\n") == 1
assert text.count(b"Encapsulated message:\n") == 1
assert text.count(b"Got message:  type      = 1\n") == 2
assert text.count(b"Decapsulated  message:\n") == 1
assert b"before[2,0]|[logger:9]|after[2,0]\n" in text
assert b"before[3,0]|OpenIPMI Request Message Header:\n" in text
assert b"  cmd       = 0x94\nOpenIPMI Request Message Data (4 bytes)\n 17 4e 92 db\n[logger:9]|after[3,0]\n" in text
assert b"Converting message:\n  netfn     = 0x2c\n  cmd       = 0x94\n  data_len  = 4\n  data      = 174e92db\n" in text
assert b"Encapsulated message:\n  netfn     = 0x6\n  cmd       = 0x34\n  data_len  = 12\n  data      = fd3cb311ff0094174e92db9b\n" in text
assert b"Got message:  type      = 1\n  channel   = 0xffffffd6\n" in text
assert b"  msgid     = 7\n  netfn     = 0x2d\n" in text
assert b"  data_len  = 7\n  data      = 005b6dc2397788\n" in text
print("OpenIPMI C/Zig buffered stderr parity (direct and bridged, v2/v3/v4/v5)")
