"""Compare C and Zig raw/I2C operations, buffered ordering and failure status."""

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

def expected_i2c_output():
    cases = (
        (0, 0, 0, 0), (1, 0, 0, 0), (0, 1, 1, 0),
        (0, 4, 4, 0), (1, 4, 4, 0), (1, 4, 4, 1),
        (0, 5, 5, 0), (0, 16, 16, 0), (0, 17, 17, 0),
        (0, 8, 3, 0), (1, 8, 3, 0), (1, 8, 3, 1),
    )
    output = bytearray()
    for index, (write, read, size, verbose) in enumerate(cases):
        output.extend(f"before[{index}]|".encode())
        if write and (verbose or not read):
            output.extend(f"Wrote {write} bytes to I2C device A0h\n".encode())
        if read:
            if verbose or not write:
                output.extend(f"Read {size} bytes from I2C device A0h\n".encode())
            if size >= read:
                data = bytes((i * 41) & 255 for i in range(size))
                rows = [
                    b"".join(f" {byte:02x}".encode() for byte in data[i:i + 16])
                    for i in range(0, size, 16)
                ]
                output.extend(b"\n".join(rows) + b"\n")
                if size <= 4:
                    output.extend(b"".join(f"{byte:08b} ".encode() for byte in data) + b"\n")
        status = -1 if read and size < read else 0
        output.extend(f"|status:{status}|after[{index}]\n".encode())
    return bytes(output)


for arguments, expected in (([], expected_output()), (["--i2c"], expected_i2c_output())):
    oracle, selected = (
        subprocess.run([binary, *arguments], capture_output=True, check=True)
        for binary in sys.argv[1:]
    )
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
if sys.platform.startswith("linux"):
    with open("/dev/full", "wb", buffering=0) as full:
        failed = subprocess.run(
            [sys.argv[2], "--i2c-failure"], stdout=full, stderr=subprocess.PIPE
        )
    assert failed.returncode == 1, failed
    assert not failed.stderr, failed.stderr
print("raw/I2C C/Zig output/status parity, mixed libc ordering and delayed flush failure")
