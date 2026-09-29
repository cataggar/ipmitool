#!/usr/bin/env python3
"""Generate binary event-file inputs for C fgets chunk boundaries."""

from pathlib import Path


def write_hex(name: str, data: bytes) -> None:
    path = Path(__file__).resolve().parent / name
    with path.open("w", encoding="ascii") as out:
        for start in range(0, len(data), 32):
            out.write(" ".join(f"{byte:02x}" for byte in data[start:start + 32]))
            out.write("\n")


def main() -> None:
    event = b"0x04 0x01 0x30 0x01 0x09 0xff 0xff"
    write_hex("split-chunk.hex", b"#" + b"x" * 1022 + event + b"\n")
    write_hex("nul-boundary.hex", event + b"\x00" + b"x" * (1023 - len(event) - 1) + event)


if __name__ == "__main__":
    main()
