#!/usr/bin/env python3
import collections
import re
import subprocess
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: overlay_style_delta_check.py BASE HEAD")
base, head = sys.argv[1:]
comparison = f"{base}...{head}"
filters = ["*.rb", "*.rbi", "*.sh", "*.yml", "*.yaml", "bin/brew"]
changed = subprocess.check_output(
    [
        "git",
        "diff",
        "--find-renames",
        "--name-only",
        "--diff-filter=ACMR",
        comparison,
        "--",
        *filters,
    ],
    text=True,
).splitlines()
if not changed:
    print("changed-line style gate: PASS (no style-relevant files)")
    raise SystemExit(0)

# Keep the broad style pathspec here instead of narrowing it to destination
# paths. Git needs both sides of a rename in view; otherwise a pure move looks
# like a full-file addition and every pre-existing offense becomes "new".
patch = subprocess.check_output(
    [
        "git",
        "diff",
        "--find-renames",
        "--unified=0",
        "--no-color",
        comparison,
        "--",
        *filters,
    ],
    text=True,
)
style = subprocess.run(
    ["bin/brew", "style", "--display-cop-names", *changed],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    check=False,
)

ranges = collections.defaultdict(list)
current = None
hunk = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
for line in patch.splitlines():
    if line.startswith("+++ b/"):
        current = line[6:]
    elif current:
        match = hunk.match(line)
        if match:
            start = int(match.group(1))
            count = int(match.group(2) or "1")
            if count:
                ranges[current].append((start, start + count - 1))


def changed_line(path, lineno):
    return any(start <= lineno <= end for start, end in ranges.get(path, ()))


ansi = re.compile(r"\x1b\[[0-9;]*m")
action_error = re.compile(r"^::error file=([^,]+),line=(\d+)(?:,[^:]*)?::(.*)$")
plain = re.compile(r"^([^:]+):(\d+):\d+: [A-Z]: (.*)$")
recognized = set()
changed_errors = set()
for raw in style.stdout.splitlines():
    line = ansi.sub("", raw)
    match = action_error.match(line)
    if match:
        path, lineno, message = match.group(1), int(match.group(2)), match.group(3)
    else:
        match = plain.match(line)
        if not match:
            continue
        path, lineno, message = match.group(1), int(match.group(2)), match.group(3)
        if not path.startswith(("Library/Homebrew/", ".github/", "bin/")):
            path = f"Library/Homebrew/{path}"
    key = (path, lineno, message)
    recognized.add(key)
    if changed_line(path, lineno):
        changed_errors.add(key)

for path, lineno, message in sorted(changed_errors):
    print(f"{path}:{lineno}: {message}")
if changed_errors:
    raise SystemExit(f"style reported {len(changed_errors)} offense(s) on changed lines")
if style.returncode != 0 and not recognized:
    print("\n".join(style.stdout.splitlines()[-80:]))
    raise SystemExit("style failed without locatable diagnostics")
print("changed-line style gate: PASS")
