#!/bin/bash
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
ruby_loader="${repo}/Library/Homebrew/overlay.rb"
ruby_impl="${repo}/Library/Homebrew/overlay"
shell_loader="${repo}/Library/Homebrew/utils/overlay.sh"
shell_impl="${repo}/Library/Homebrew/utils/overlay"

[[ "$(wc -l <"${ruby_loader}")" -le 15 ]] || {
  echo "Error: public Ruby overlay loader accumulated implementation" >&2
  exit 1
}
[[ "$(wc -l <"${shell_loader}")" -le 20 ]] || {
  echo "Error: public shell overlay loader accumulated implementation" >&2
  exit 1
}

grep -Fx 'require "overlay/core"' "${ruby_loader}" >/dev/null || {
  echo "Error: public Ruby overlay loader no longer loads overlay/core" >&2
  exit 1
}
grep -F 'overlay/core.sh' "${shell_loader}" >/dev/null || {
  echo "Error: public shell overlay loader no longer loads overlay/core.sh" >&2
  exit 1
}

while IFS= read -r file
do
  case "${file}" in
    "${ruby_loader}" | "${ruby_impl}"/*) continue ;;
  esac
  if grep -Eq 'require[[:space:]]+"overlay/' "${file}"
  then
    echo "Error: Homebrew-owned Ruby code bypasses the public overlay loader: ${file#"${repo}/"}" >&2
    exit 1
  fi
done < <(find "${repo}/Library/Homebrew" -type f -name '*.rb' -print)

while IFS= read -r file
do
  case "${file}" in
    "${shell_loader}" | "${shell_impl}"/* | "${repo}/Library/Homebrew/test/"*) continue ;;
  esac
  if grep -Fq 'overlay/core.sh' "${file}"
  then
    echo "Error: Homebrew-owned shell code bypasses the public overlay loader: ${file#"${repo}/"}" >&2
    exit 1
  fi
done < <(
  find "${repo}/Library/Homebrew" "${repo}/bin" -type f \
    \( -name '*.sh' -o -path "${repo}/bin/brew" \) -print
)

printf 'overlay architecture boundary: PASS\n'
