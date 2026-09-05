#!/bin/bash
# Static control-flow guard for mixed local/inherited removal semantics.
# Full CLI/RSpec coverage remains the authoritative target-host check, but this
# offline guard prevents the exact force-uninstall/autoremove regressions found
# by the final audit from silently returning.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"

source_files=(
  "${repo}/Library/Homebrew/uninstall.rb"
  "${repo}/Library/Homebrew/cleanup.rb"
  "${repo}/Library/Homebrew/utils/autoremove.rb"
  "${repo}/Library/Homebrew/keg.rb"
)
python3 - "${source_files[@]}" <<'PY'
from pathlib import Path
import sys

uninstall = Path(sys.argv[1]).read_text(encoding="utf-8")
cleanup = Path(sys.argv[2]).read_text(encoding="utf-8")
autoremove = Path(sys.argv[3]).read_text(encoding="utf-8")
keg = Path(sys.argv[4]).read_text(encoding="utf-8")

uninstall_start = uninstall.index("    def self.uninstall_kegs(")
uninstall_end = uninstall.index("\n    sig {", uninstall_start)
uninstall_method = uninstall[uninstall_start:uninstall_end]
uninstall_order = [
    "if force && Homebrew::Overlay.active?",
    "local_kegs = kegs.reject",
    "local_kegs_by_rack[rack] = local_kegs",
    "kegs_by_rack = local_kegs_by_rack",
    "handle_unsatisfied_dependents(kegs_by_rack",
    "kegs.each do |keg|",
]
positions = [uninstall_method.index(fragment) for fragment in uninstall_order]
