#!/bin/bash
set -euo pipefail
umask 077

repository="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repository="$(cd "${repository}" && pwd -P)"

# Native macOS Bash 3.2 rejects an empty array expansion under nounset.
# Keep this shell-only check before Ruby bootstrap and gem setup.
output="$(env \
  -u HOMEBREW_OVERLAY \
  -u HOMEBREW_OVERLAY_BASE_PREFIX \
  -u HOMEBREW_OVERLAY_FORCE \
  -u HOMEBREW_OVERLAY_USER_PREFIX \
  HOMEBREW_NO_AUTO_UPDATE=1 \
  /bin/bash "${repository}/bin/brew" --version)"
[[ "${output}" == Homebrew* ]]

output="$(env \
  HOMEBREW_NO_AUTO_UPDATE=1 \
  HOMEBREW_SKIP_INITIAL_GEM_INSTALL=1 \
  "${repository}/bin/brew" ruby -e 'print RUBY_VERSION')"

[[ "${output}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
printf 'overlay disabled-gems runtime boot test: PASS\n'
