"""Byte-compare buffered libc stdout around all three C and Zig LAN+ dumps."""

import subprocess
import sys

sha256, c_exe, zig_exe = sys.argv[1:]
oracle = subprocess.run([c_exe], capture_output=True, check=True)
selected = subprocess.run([zig_exe], capture_output=True, check=True)
assert oracle.stderr == selected.stderr == b""
if oracle.stdout != selected.stdout:
    import difflib

    print(
        "".join(
            difflib.unified_diff(
                oracle.stdout.decode().splitlines(keepends=True),
                selected.stdout.decode().splitlines(keepends=True),
                fromfile="original C",
                tofile="selected Zig",
            )
        ),
        file=sys.stderr,
    )
    sys.exit(1)

out = selected.stdout
assert out.count(b"<<OPEN SESSION RESPONSE\n") == 10
assert out.count(b"<<RAKP 2 MESSAGE\n") == out.count(b"<<RAKP 4 MESSAGE\n") == 10
assert out.count(b"Negotiated authenticatin algorithm") == 5  # only success
assert b"before open[0,0]||after open\n" in out
assert b"before rakp2[0,9,255]||after rakp2\n" in out
assert b"before rakp4[0,9,255]||after rakp4\n" in out
assert b"before open[2,9]|<<OPEN SESSION RESPONSE\n" in out
assert b"Console Session ID                 : 0x89abcdef\n|after open" in out
assert b"before rakp2[2,9,255]|<<RAKP 2 MESSAGE\n" in out
assert b"before rakp4[2,9,255]|<<RAKP 4 MESSAGE\n" in out
assert b"  BMC random number             : 0x00112233445566778899aabbccddeeff\n" in out
assert b"  Key exchange auth code [sha1] : 0x" in out
assert b"  Key exchange auth code [md5]   : 0x" in out
assert b"  Key exchange auth code        : none\n\n" in out
assert b"  Key exchange auth code         : invalid\n" in out
if sha256 == "sha256":
    assert out.count(b"  Key exchange auth code [sha256]: 0x") == 4
    assert b"[sha256]: 0xfff8f1eae3dcd5cec7c0b9b2aba49d968f88817a736c655e575049423b342d26\n" in out
    assert b"[sha256]: 0x00070e151c232a31383f464d545b6269\n" in out
else:
    assert b"[sha256]" not in out
print(f"LAN+ dump C/Zig stdout parity ({sha256})")
