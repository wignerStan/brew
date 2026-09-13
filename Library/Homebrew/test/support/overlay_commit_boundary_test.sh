#!/bin/bash
set -euo pipefail

repository="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repository="$(cd "${repository}" && pwd -P)"

python3 - \
  "${repository}/Library/Homebrew/formula_installer.rb" \
  "${repository}/Library/Homebrew/overlay/install_session.rb" \
  "${repository}/Library/Homebrew/overlay/core.rb" <"${BASH_SOURCE[0]%_test.sh}_validator.py"

printf 'overlay commit boundary test: PASS\n'
