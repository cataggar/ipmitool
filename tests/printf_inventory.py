#!/usr/bin/env python3
"""Inventory printf arguments after C macro expansion; never rewrite source."""
import argparse
import ast
import collections
import difflib
import pathlib
import re
import subprocess


CALLS = {
    "printf": 0, "fprintf": 1, "sprintf": 1, "snprintf": 2,
    "lprintf": 1, "lperror": 1, "syslog": 1,
    "vprintf": 0, "vfprintf": 1, "vsprintf": 1, "vsnprintf": 2,
}
TOKEN = re.compile(
    r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|'
    r"'(?:\\.|[^'\\])*'|[A-Za-z_][A-Za-z_0-9]*|[^\s]", re.S
)
SPEC = re.compile(
    r"%(?:[1-9][0-9]*\$)?[-+ #0']*"
    r"(?:\*(?:[1-9][0-9]*\$)?|[0-9]+)?"
    r"(?:\.(?:\*(?:[1-9][0-9]*\$)?|[0-9]*))?"
    r"(?:hh|ll|[hljztL])?[diouxXfFeEgGaAcspn%]"
)
SUPPORTED = re.compile(
    r"%(?:%|[-+ #0]*(?:\*|[0-9]+)?(?:\.(?:\*|[0-9]*))?"
    r"(?:hh|ll|[hljzt])?[diouxX]|-?(?:\*|[0-9]+)?"
    r"(?:\.(?:\*|[0-9]*))?s|-?(?:\*|[0-9]+)?c)"
)
LINE_MARKER = re.compile(r'^#\s+\d+\s+("(?:\\.|[^"\\])*")(?:\s+\d+)*\s*$')


def project_source(source, root):
    """Keep macro-expanded project text, not host-library header declarations."""
    selected, lines = False, []
    root = root.resolve()
    for line in source.splitlines(keepends=True):
        marker = LINE_MARKER.fullmatch(line.rstrip("\n"))
        if marker:
            filename = ast.literal_eval(marker.group(1))
            path = pathlib.Path(filename)
            if not path.is_absolute():
                path = root / path
            try:
                relative = path.resolve().relative_to(root)
            except ValueError:
                selected = False
            else:
                selected = relative.parts[:1] == ("lib",) or relative.parts[:2] == ("include", "ipmitool")
        elif selected:
            lines.append(line)
    return "".join(lines)


def fixed_width_sources(source):
    """Include both promoted and narrow PRI spellings used by Linux headers."""
    for definitions in (
        {"PRIu8": '"u"', "PRId16": '"d"'},
        {"PRIu8": '"hhu"', "PRId16": '"hd"'},
    ):
        yield TOKEN.sub(lambda token: definitions.get(token.group(), token.group()), source)


def formats(source):
    tokens = [m.group() for m in TOKEN.finditer(source)
              if not m.group().startswith(("/*", "//"))]
    for i, token in enumerate(tokens[:-1]):
        if token not in CALLS or tokens[i + 1] != "(":
            continue
        depth, argument, values = 0, 0, []
        for value in tokens[i + 2:]:
            if value == ")" and depth == 0:
                break
            if value == "," and depth == 0:
                if argument == CALLS[token]:
                    break
                argument += 1
                continue
            if argument == CALLS[token]:
                values.append(value)
            if value in ("(", "[", "{"):
                depth += 1
            if value in (")", "]", "}"):
                depth -= 1
        # Adjacent literals concatenate; ternary alternatives stay separate.
        literals, current = [], []
        for value in values + [""]:
            if value.startswith('"'):
                current.append(value[1:-1])
            elif current:
                literals.append("".join(current))
                current = []
        yield values, literals


def inventory(zig, config):
    counts, dynamic = collections.Counter(), set()
    for path in sorted(pathlib.Path("lib").glob("ipmi_*.c")):
        processed = subprocess.run(
            [zig, "cc", "-E", "-std=gnu11", "-DHAVE_CONFIG_H",
             "-Iinclude", "-I" + str(config.parent), str(path)],
            check=True, capture_output=True, text=True,
        ).stdout
        # Also scan unconfigured branches. Macro-dependent arguments are covered
        # by the preprocessed source; their unresolved raw halves are not formats.
        raw = path.read_text()
        for source in (
            project_source(processed, pathlib.Path.cwd()), raw,
            *fixed_width_sources(raw),
        ):
            # Include literal-bearing tables and formats passed through helpers.
            # This conservative superset also catches scanf/strftime overlaps.
            for token in TOKEN.finditer(source):
                if token.group().startswith('"'):
                    counts.update(match.group() for match in SPEC.finditer(token.group()[1:-1]))
            for values, literals in formats(source):
                if not literals:
                    expression = " ".join(values)
                    # Skip function prototypes included by preprocessing.
                    if expression and not expression.startswith(("const ", "__")):
                        dynamic.add(f"{path}: {expression}")
                for literal in literals:
                    counts.update(match.group() for match in SPEC.finditer(literal))
    return counts, dynamic


def render(counts, dynamic):
    supported = sorted(spec for spec in counts if SUPPORTED.fullmatch(spec))
    unsupported = sorted(spec for spec in counts if spec not in supported)
    lines = [
        "// Generated by tests/printf_inventory.py using C preprocessing.",
        "// Counts are intentionally omitted; literal forms are the compatibility gate.",
    ]
    for name, values in (("supported", supported), ("unsupported", unsupported)):
        lines.append(f"pub const {name} = [_][]const u8{{")
        lines.extend(f'    "{value}",' for value in values)
        lines.append("};")
    lines.append("// Dynamic format expressions still require libc/a dedicated migration.")
    lines.extend("// " + value for value in sorted(dynamic))
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--config", type=pathlib.Path, required=True)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    counts, dynamic = inventory(args.zig, args.config)
    result = render(counts, dynamic)
    if args.check:
        expected = args.output.read_text()
        if expected != result:
            print("".join(difflib.unified_diff(
                expected.splitlines(keepends=True), result.splitlines(keepends=True),
                fromfile=str(args.output), tofile="measured project inventory",
            )), end="")
            raise SystemExit("printf inventory changed; regenerate and extend parity tests/scope")
    else:
        args.output.write_text(result)
    print(f"printf inventory: {len(counts)} forms, {len(dynamic)} dynamic expressions")


if __name__ == "__main__":
    main()
