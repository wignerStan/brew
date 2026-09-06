#!/usr/bin/env python3
from pathlib import Path
import subprocess


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return source.replace(old, new, 1)


path = Path("Library/Homebrew/test/support/overlay_reinstall_recovery_test.sh")
source = path.read_text(encoding="utf-8")
source = replace_once(
    source,
    '''  "${repo}/Library/Homebrew/overlay/reinstall_session.rb" \\
  "${repo}/Library/Homebrew/overlay/core.rb" <<'PY'
''',
    '''  "${repo}/Library/Homebrew/overlay/reinstall_session.rb" \\
  "${repo}/Library/Homebrew/overlay/core.rb" \\
  "${repo}/Library/Homebrew/overlay/durable_fs.rb" <<'PY'
''',
    "reinstall recovery durability module argument",
)
source = replace_once(
    source,
    '''overlay = Path(sys.argv[3]).read_text(encoding="utf-8")
''',
    '''overlay = Path(sys.argv[3]).read_text(encoding="utf-8")
durable_fs = Path(sys.argv[4]).read_text(encoding="utf-8")
''',
    "reinstall recovery durability module reader",
)
source = replace_once(
    source,
    '''assert ".cleanup-#{path.basename}" in overlay
''',
    '''assert ".cleanup-#{path.basename}" in durable_fs
assert "def self.remove_tree_durable!" in durable_fs
assert "def self.remove_tree_durable!" not in overlay
''',
    "reinstall recovery cleanup ownership assertion",
)
path.write_text(source, encoding="utf-8")

subprocess.run(["git", "add", "--", str(path)], check=True)
subprocess.run(["git", "diff", "--cached", "--check"], check=True)
subprocess.run(["git", "commit", "--amend", "--no-edit"], check=True)
