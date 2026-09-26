"""Compare the original C and selected Zig raw response, including buffered libc output."""

import subprocess
import sys


def expected_output():
    output = bytearray()
    for size in (0, 1, 15, 16, 17, 31, 32, 33, 256, 1024):
        data = bytes((i * 41) & 0xFF for i in range(size))
        rows = [
            b"".join(f" {byte:02x}".encode() for byte in data[i : i + 16])
            for i in range(0, size, 16)
        ]
        output.extend(f"before[{size}]|".encode())
        output.extend(b"\n".join(rows) + b"\n")
        output.extend(f"|after[{size}]\n".encode())
    return bytes(output)


oracle, selected = (
    subprocess.run([binary], capture_output=True, check=True)
    for binary in sys.argv[1:]
)
expected = expected_output()
for name, result in (("C oracle", oracle), ("selected Zig", selected)):
    if result.stderr or result.stdout != expected:
        import difflib

        print(
            f"{name}: unexpected stderr {result.stderr!r}\n"
            + "".join(
                difflib.unified_diff(
                    expected.decode().splitlines(keepends=True),
                    result.stdout.decode().splitlines(keepends=True),
                    fromfile="expected C byte shape",
                    tofile=name,
                )
            ),
            file=sys.stderr,
        )
        sys.exit(1)
assert oracle.stdout == selected.stdout
print("raw response C/Zig stdout parity and mixed libc ordering")
