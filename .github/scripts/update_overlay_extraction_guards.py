#!/usr/bin/env python3
from pathlib import Path
import subprocess


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return source.replace(old, new, 1)


reinstall_path = Path("Library/Homebrew/test/support/overlay_reinstall_recovery_test.sh")
reinstall = reinstall_path.read_text(encoding="utf-8")
reinstall = replace_once(
    reinstall,
    '''  "${repo}/Library/Homebrew/overlay/reinstall_session.rb" \\
  "${repo}/Library/Homebrew/overlay/core.rb" <<'PY'
''',
    '''  "${repo}/Library/Homebrew/overlay/reinstall_session.rb" \\
  "${repo}/Library/Homebrew/overlay/core.rb" \\
  "${repo}/Library/Homebrew/overlay/durable_fs.rb" <<'PY'
''',
    "reinstall recovery durability module argument",
)
reinstall = replace_once(
    reinstall,
    '''overlay = Path(sys.argv[3]).read_text(encoding="utf-8")
''',
    '''overlay = Path(sys.argv[3]).read_text(encoding="utf-8")
durable_fs = Path(sys.argv[4]).read_text(encoding="utf-8")
''',
    "reinstall recovery durability module reader",
)
reinstall = replace_once(
    reinstall,
    '''assert ".cleanup-#{path.basename}" in overlay
''',
    '''assert ".cleanup-#{path.basename}" in durable_fs
assert "def self.remove_tree_durable!" in durable_fs
assert "def self.remove_tree_durable!" not in overlay
''',
    "reinstall recovery cleanup ownership assertion",
)
reinstall_path.write_text(reinstall, encoding="utf-8")

publication_path = Path(
    "Library/Homebrew/test/support/overlay_transaction_publication_durability_test.sh",
)
publication = publication_path.read_text(encoding="utf-8")
publication = replace_once(
    publication,
    '''python3 \\
  - "${repo}/Library/Homebrew/overlay/core.rb" \\
  "${repo}/Library/Homebrew/utils/overlay/core.sh" <<'PY'
''',
    '''python3 \\
  - "${repo}/Library/Homebrew/overlay/core.rb" \\
  "${repo}/Library/Homebrew/overlay/durable_fs.rb" \\
  "${repo}/Library/Homebrew/utils/overlay/core.sh" <<'PY'
''',
    "publication durability module argument",
)
publication = replace_once(
    publication,
    '''ruby = Path(sys.argv[1]).read_text(encoding="utf-8")
shell = Path(sys.argv[2]).read_text(encoding="utf-8")
''',
    '''ruby = Path(sys.argv[1]).read_text(encoding="utf-8")
durable_fs = Path(sys.argv[2]).read_text(encoding="utf-8")
shell = Path(sys.argv[3]).read_text(encoding="utf-8")
''',
    "publication durability module reader",
)
publication = replace_once(
    publication,
    '''exchange = body(ruby, "    def self.atomic_exchange!(left, right)\\n", "\\n    # Remove a newly created",)
''',
    '''exchange = body(
    durable_fs,
    "    def self.atomic_exchange!(left, right)\\n",
    "\\n    # Remove a newly created",
)
''',
    "atomic exchange ownership assertion",
)
publication = replace_once(
    publication,
    '''tree = body(
    ruby,
    "    def self.fsync_tree!(root)\\n",
''',
    '''tree = body(
    durable_fs,
    "    def self.fsync_tree!(root)\\n",
''',
    "fsync tree ownership assertion",
)
publication = replace_once(
    publication,
    '''for required in (
    "File::NOFOLLOW",
''',
    '''if "def self.atomic_exchange!" in ruby or "def self.fsync_tree!" in ruby:
    raise SystemExit("durable filesystem methods returned to overlay/core.rb")

for required in (
    "File::NOFOLLOW",
''',
    "durability boundary regression assertion",
)
publication_path.write_text(publication, encoding="utf-8")

subprocess.run(
    ["git", "add", "--", str(reinstall_path), str(publication_path)],
    check=True,
)
subprocess.run(["git", "diff", "--cached", "--check"], check=True)
subprocess.run(["git", "commit", "--amend", "--no-edit"], check=True)
