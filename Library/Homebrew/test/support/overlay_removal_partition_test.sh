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
python3 - "${source_files[@]}" <"${BASH_SOURCE[0]%_test.sh}_validator.py"

printf 'overlay removal partition test: PASS\n'
