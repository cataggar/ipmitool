#!/usr/bin/env python3
"""Copy the original SPD lookup tables into a standalone Zig translation unit."""

import argparse
import re
from pathlib import Path

SOURCE = Path("lib/dimm_spd.c")
DEST = Path("src/zig/cmd/dimm_spd_tables.zig")
TABLE = re.compile(r"const struct valstr (\w+)\[\]\s*=\s*\{(.*?)\n\};", re.S)
ENTRY = re.compile(r'\{\s*(0x[\da-fA-F]+|\d+)\s*,\s*("(?:\\.|[^"\\])*"|NULL)\s*\}')


def generate(source: str) -> str:
    license_text = source[source.index("/*") + 2 : source.index("*/")]
    out = [
        *(f"//{line.removeprefix(' *').rstrip()}" for line in license_text.splitlines()[1:]),
        "",
        "//! JEDEC JEP106 (2003) and SPD decoding tables from `lib/dimm_spd.c`.",
        "//! Regenerate with `python3 tools/gen-spd-tables.py` after changing the C tables.",
        "",
        'const c = @import("ipmi_c");',
        "",
    ]
    names = []
    for name, body in TABLE.findall(source):
        entries = ENTRY.findall(body)
        if len(entries) != body.count("{") or not entries or entries[-1][1] != "NULL":
            raise ValueError(f"cannot transcribe {name} without losing a C entry")
        names.append(name)
        out.append(f"pub const {name} = [_]c.struct_valstr{{")
        for value, text in entries:
            out.append(
                f'    .{{ .val = {value}, .str = {text if text != "NULL" else "null"} }},'
            )
        out.extend(["};", ""])
    if len(names) != 20 or len(set(names)) != len(names):
        raise ValueError(f"expected 20 distinct SPD tables; found {len(names)}")
    out.append("pub fn exportSymbols() void {")
    out.append("    comptime {")
    for name in names:
        out.append(
            f'        @export(&{name}, .{{ .name = "{name}", .linkage = .strong }});'
        )
    out.extend(["    }", "}", ""])
    return "\n".join(out)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify generated tables")
    args = parser.parse_args()
    generated = generate(SOURCE.read_text(encoding="utf-8"))
    if args.check:
        if not DEST.exists() or DEST.read_text(encoding="utf-8") != generated:
            parser.error(f"{DEST} is out of date; regenerate it")
    else:
        DEST.write_text(generated, encoding="utf-8")


if __name__ == "__main__":
    main()
