#!/usr/bin/env python3
import collections
import re
import subprocess
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")
ACTION_ERROR = re.compile(r"^::error file=([^,]+),line=(\d+)(?:,[^:]*)?::(.*)$")
PLAIN_ERROR = re.compile(r"^([^:]+):(\d+):\d+: [A-Z]: (.*)$")
FATAL_UNPARSED = re.compile(
    r"(?:^::error(?::| )|\b(?:fatal|traceback|exception|syntax error|parser crashed|segmentation fault)\b)",
    re.IGNORECASE,
)


def changed_line(ranges, path, lineno):
    return any(start <= lineno <= end for start, end in ranges.get(path, ()))


def parse_style_output(output, ranges, returncode):
    recognized = set()
    changed_errors = set()
    unparsed_fatal = []
    for raw in output.splitlines():
        line = ANSI.sub("", raw)
        match = ACTION_ERROR.match(line)
        if match:
            path, lineno, message = match.group(1), int(match.group(2)), match.group(3)
        else:
            match = PLAIN_ERROR.match(line)
            if not match:
                if returncode != 0 and FATAL_UNPARSED.search(line):
                    unparsed_fatal.append(line)
                continue
            path, lineno, message = match.group(1), int(match.group(2)), match.group(3)
            if not path.startswith(("Library/Homebrew/", ".github/", "bin/")):
                path = f"Library/Homebrew/{path}"
        key = (path, lineno, message)
        recognized.add(key)
        if changed_line(ranges, path, lineno):
            changed_errors.add(key)
    return recognized, changed_errors, unparsed_fatal


def main(argv):
    if len(argv) != 3:
        raise SystemExit("usage: overlay_style_delta_check.py BASE HEAD")
    base, head = argv[1:]
    comparison = f"{base}...{head}"
    filters = ["*.rb", "*.rbi", "*.sh", "*.yml", "*.yaml", "bin/brew"]
    changed = subprocess.check_output(
        [
            "git",
            "diff",
            "--find-renames",
            "--find-copies-harder",
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
        return 0

    patch = subprocess.check_output(
        [
            "git",
            "diff",
            "--find-renames",
            "--find-copies-harder",
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

    recognized, changed_errors, unparsed_fatal = parse_style_output(style.stdout, ranges, style.returncode)
    for path, lineno, message in sorted(changed_errors):
        print(f"{path}:{lineno}: {message}")
    if changed_errors:
        raise SystemExit(f"style reported {len(changed_errors)} offense(s) on changed lines")
    if unparsed_fatal:
        print("\n".join(unparsed_fatal[-40:]))
        raise SystemExit("style failed with unparsed fatal output")
    if style.returncode != 0 and not recognized:
        print("\n".join(style.stdout.splitlines()[-80:]))
        raise SystemExit("style failed without locatable diagnostics")
    print("changed-line style gate: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
