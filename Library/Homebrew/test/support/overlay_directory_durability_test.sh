#!/bin/bash
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# shellcheck source=Homebrew/utils/overlay/core.sh
source "${repo}/Library/Homebrew/utils/overlay/core.sh"

prefix="${work}/prefix"
mkdir -p -- "${prefix}"
log="${work}/fsync.log"

homebrew-overlay-fsync-directory() {
  printf '%s\n' "$1" >>"${log}"
}

homebrew-overlay-safe-mkdir "${prefix}" "${prefix}/durability/first/second"
cat >"${work}/expected" <<EOF
${prefix}
${prefix}/durability
${prefix}/durability/first
EOF
cmp -s "${work}/expected" "${log}"
test -d "${prefix}/durability/first/second"

printf 'overlay directory durability test: PASS\n'
