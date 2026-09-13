from pathlib import Path
import sys

raw = Path(sys.argv[1]).read_bytes().split(b"\0")
args = [item.decode() for item in raw if item]
root = sys.argv[2]
expected = [
    "-d", "--", f"{root}/source-parent",
    "-d", "--", f"{root}/destination-parent",
    "-d", "--", f"{root}/remove-parent",
]
pos = 0
for value in expected:
    try:
        pos = args.index(value, pos) + 1
    except ValueError as e:
        raise SystemExit(f"missing ordered directory fsync argument {value!r}: {args}") from e
