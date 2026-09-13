#!/bin/bash
# Static guard for artifact-backed, fresh-runner, exact-SHA overlay promotion.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"

python3 - \
  "${repo}/.github/workflows/rebase-upstream-overlay.yml" \
  "${repo}/.github/workflows/overlay-validation.yml" <"${BASH_SOURCE[0]%_test.sh}_validator.py"

printf 'overlay rebase workflow test: PASS\n'
