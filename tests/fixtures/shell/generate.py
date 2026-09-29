#!/usr/bin/env python3
"""Generate exec line-boundary fixtures as byte-oriented golden inputs."""

from pathlib import Path


def write_hex(name: str, data: bytes) -> None:
    path = Path(__file__).resolve().parent / name
    with path.open("w", encoding="ascii") as out:
        for start in range(0, len(data), 32):
            out.write(" ".join(f"{byte:02x}" for byte in data[start:start + 32]))
            out.write("\n")


def main() -> None:
    write_hex("exec-2047.hex", b"#" + b"x" * 2046 + b"\necho after\n")
    write_hex("exec-2048.hex", b"#" + b"x" * 2046 + b"#\necho after\n")
    write_hex("exec-nul.hex", b"echo before\x00echo hidden\r\necho after\n")
    write_hex(
        "exec-nul-boundary.hex",
        b"echo before\x00" + b"x" * (2047 - len(b"echo before\x00"))
        + b"echo after\n",
    )


if __name__ == "__main__":
    main()
