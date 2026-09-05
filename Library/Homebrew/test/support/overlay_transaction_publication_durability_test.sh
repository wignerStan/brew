#!/bin/bash
# File-and-directory durability ordering for formula transaction publication and recovery.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

python3 \
  - "${repo}/Library/Homebrew/overlay/core.rb" \
  "${repo}/Library/Homebrew/utils/overlay/core.sh" <<'PY'
from pathlib import Path
import sys

ruby = Path(sys.argv[1]).read_text(encoding="utf-8")
shell = Path(sys.argv[2]).read_text(encoding="utf-8")

def body(source: str, start_fragment: str, end_fragment: str) -> str:
    start = source.index(start_fragment)
    end = source.index(end_fragment, start)
    return source[start:end]

def ordered(section: str, fragments: list[str], description: str) -> None:
    positions = [section.index(fragment) for fragment in fragments]
