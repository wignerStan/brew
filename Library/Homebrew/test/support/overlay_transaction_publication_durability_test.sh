#!/bin/bash
# File-and-directory durability ordering for formula transaction publication and recovery.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=Homebrew/utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

python3 \
  - "${repo}/Library/Homebrew/overlay/core.rb" \
  "${repo}/Library/Homebrew/utils/overlay/core.sh" <"${BASH_SOURCE[0]%_test.sh}_validator_1.py"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-publication-durability.XXXXXX")"
trap 'rm -rf -- "${work}"' EXIT
prefix="${work}/prefix"
mkdir -p "${prefix}/Cellar" "${prefix}/var/homebrew/locks" \
  "${work}/source-parent/item/subdir" "${work}/destination-parent" \
  "${work}/remove-parent/tree/subdir"
printf 'payload\n' >"${work}/source-parent/item/subdir/file"
printf 'remove\n' >"${work}/remove-parent/tree/subdir/file"

export HOMEBREW_PREFIX="${prefix}"
lock_file="$(homebrew-overlay-prepare-mutation-lock "${prefix}")"
exec {mutation_fd}<>"${lock_file}"
flock -x "${mutation_fd}"

sync_log="${work}/sync.log"
sync() {
  printf '%s\0' "$@" >>"${sync_log}"
  command sync "$@"
}

homebrew-overlay-move-durable \
  "${work}/source-parent/item" "${work}/destination-parent/item"
test ! -e "${work}/source-parent/item"
test -f "${work}/destination-parent/item/subdir/file"
homebrew-overlay-remove-tree-durable "${work}/remove-parent/tree"
test ! -e "${work}/remove-parent/tree"

python3 - "${sync_log}" "${work}" <"${BASH_SOURCE[0]%_test.sh}_validator_2.py"

flock -u "${mutation_fd}"
exec {mutation_fd}>&-
printf 'overlay transaction publication durability test: PASS\n'
