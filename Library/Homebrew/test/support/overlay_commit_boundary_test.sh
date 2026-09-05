#!/bin/bash
set -euo pipefail

repository="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repository="$(cd "${repository}" && pwd -P)"

python3 - \
  "${repository}/Library/Homebrew/formula_installer.rb" \
  "${repository}/Library/Homebrew/overlay/install_session.rb" \
  "${repository}/Library/Homebrew/overlay/core.rb" <<'PY'
from pathlib import Path
import sys

installer = Path(sys.argv[1]).read_text(encoding="utf-8")
session = Path(sys.argv[2]).read_text(encoding="utf-8")
core = Path(sys.argv[3]).read_text(encoding="utf-8")

finish_start = installer.index("  def finish\n")
finish_end = installer.index("\n  sig { returns(String) }\n  def summary", finish_start)
finish = installer[finish_start:finish_end]

ordered = [
    "@overlay_install_session.publish!",
    "fix_dynamic_linkage(keg) if fix_linkage",
    "@overlay_install_session.commit!(keg)",
    "link(keg)",
    "install_service",
    "formula.install_etc_var",
]
positions = [finish.index(fragment) for fragment in ordered]
