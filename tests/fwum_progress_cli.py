"""Check both CLI fixtures against a committed byte snapshot (including CR)."""
import codecs
from pathlib import Path
import subprocess
import sys

expected = codecs.decode(
    "".join(Path(sys.argv[3]).read_text(encoding="ascii").splitlines()),
    "unicode_escape",
).encode("latin1")
for binary in sys.argv[1:3]:
    result = subprocess.run([binary], capture_output=True, check=False)
    if result.returncode or result.stdout != expected or result.stderr:
        raise SystemExit(
            f"{binary}: exit={result.returncode}\n"
            f"expected stdout={expected!r}\nactual stdout={result.stdout!r}\n"
            f"stderr={result.stderr!r}"
        )
