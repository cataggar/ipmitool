#!/usr/bin/env python3
"""Compare the original C and selected Zig registry with identical fake vtables."""
import subprocess
import sys


def run(binary):
    result = subprocess.run([binary], capture_output=True, timeout=15, check=False)
    if result.returncode != 0:
        raise AssertionError(
            f"{binary}: exit={result.returncode}\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
        )
    return result.stdout, result.stderr


def verify(stdout, stderr):
    assert not stderr, stderr
    lines = stdout.decode("utf-8").splitlines()
    names = [line.split("=", 1)[1] for line in lines if line.startswith("table[")]
    default = next(line.split("=", 1)[1] for line in lines if line.startswith("default="))
    assert names and len(names) == len(set(names)) and default in names, names
    expected = [
        f"log(5): \t{name:<12}  {name.replace('-', ' ')} fixture "
        f"{'[default]' if name == default else ''}"
        for name in names
    ]
    listing = ["log(5): Interfaces:", *expected, "log(5): "]
    filtered = ["log(5): Interfaces:", expected[names.index(default)], "log(5): "]
    first = lines.index("log(5): Interfaces:")
    assert lines[first : first + len(listing)] == listing, lines[first : first + len(listing)]
    second = first + len(listing)
    assert lines[second : second + len(filtered)] == filtered, lines[second : second + len(filtered)]
    assert "selection-ok" in lines and "session-ok" in lines
    assert "payload-ok" in lines
    if "lan" in names or "lanplus" in names:
        assert "socket-ok" in lines
    return len(names)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: intf_registry_contract.py C-binary Zig-binary")
    oracle = run(sys.argv[1])
    candidate = run(sys.argv[2])
    count = verify(*oracle)
    if candidate != oracle:
        raise AssertionError(
            "C/Zig registry output differs byte-for-byte:\n"
            f"C:   {oracle!r}\nZig: {candidate!r}"
        )
    print(f"registry: C/Zig byte-exact ({count} enabled interfaces)")


if __name__ == "__main__":
    main()
