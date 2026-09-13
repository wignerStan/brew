#!/bin/bash
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
loader="${repo}/Library/Homebrew/utils/overlay.sh"
core="${repo}/Library/Homebrew/utils/overlay/core.sh"

bash -n "${loader}" "${core}"

(
  # shellcheck source=Homebrew/utils/overlay.sh
  source "${loader}"
  declare -F homebrew-overlay-bootstrap >/dev/null
  homebrew-overlay-truthy yes
  ! homebrew-overlay-truthy no
)

set +e
output="$(/bin/bash "${loader}" 2>&1)"
status=$?
set -e

[[ "${status}" -eq 2 ]] || {
  echo "Error: overlay command loader returned ${status}, expected usage status 2" >&2
  exit 1
}
grep -F "Usage: overlay.sh" <<<"${output}" >/dev/null || {
  echo "Error: overlay command loader did not reach the implementation dispatcher" >&2
  exit 1
}

printf 'overlay loader regression: PASS\n'
