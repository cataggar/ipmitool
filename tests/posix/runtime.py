#!/usr/bin/env python3
"""Run the actual-System probe and audit its ELF for any runtime C provider."""
import subprocess
import sys


def inspect(binary, run):
    headers = subprocess.run(
        ["readelf", "--wide", "--program-headers", binary],
        capture_output=True, text=True, check=True,
    ).stdout
    dynamic = subprocess.run(
        ["readelf", "--wide", "--dynamic", binary],
        capture_output=True, text=True, check=True,
    ).stdout
    undefined = subprocess.run(
        ["nm", "--undefined-only", binary],
        capture_output=True, text=True, check=True,
    ).stdout
    symbols = subprocess.run(
        ["nm", binary], capture_output=True, text=True, check=True,
    ).stdout
    elf_symbols = subprocess.run(
        ["readelf", "--wide", "--symbols", binary],
        capture_output=True, text=True, check=True,
    ).stdout
    relocations = subprocess.run(
        ["readelf", "--wide", "--relocs", binary],
        capture_output=True, text=True, check=True,
    ).stdout
    # Zig's static debug support can leave a null, linker-local _DYNAMIC marker.
    # It cannot resolve from a runtime library; all other undefined names fail.
    markers = set()
    for line in elf_symbols.splitlines():
        fields = line.split()
        if (len(fields) == 8 and fields[2:] ==
                ["0", "NOTYPE", "LOCAL", "HIDDEN", "UND", "_DYNAMIC"]):
            assert int(fields[1], 16) == 0, line
            assert "_DYNAMIC" not in relocations, relocations
            markers.add("_DYNAMIC")
    undefined_names = {line.split()[-1] for line in undefined.splitlines() if line.strip()}
    assert "INTERP" not in headers, headers
    assert "(NEEDED)" not in dynamic, dynamic
    assert not (undefined_names - markers), undefined
    assert "__errno_location" not in symbols, symbols
    assert "__libc_start_main" not in symbols, symbols
    if run:
        result = subprocess.run([binary], capture_output=True, timeout=15, check=False)
        expected = b"posix no-libc: actual partial I/O, errors, EOF and read/write/poll EINTR verified\n"
        assert (result.returncode, result.stdout, result.stderr) == (0, expected, b""), result
    print("posix actual-System: no interpreter, needed libraries or unresolved runtime providers"
          + (" (null linker-local _DYNAMIC marker verified)" if markers else "")
          + ("; syscall/signal probe passed" if run else "; cross-compile audited"))


if __name__ == "__main__":
    mode, binary = sys.argv[1:]
    assert mode in ("--run", "--audit"), mode
    inspect(binary, mode == "--run")
