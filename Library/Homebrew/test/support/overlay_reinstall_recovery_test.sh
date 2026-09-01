#!/bin/bash
# Crash recovery for private reinstall backups hidden outside live formula racks.
set -euo pipefail
umask 077

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# The repository root is resolved at runtime, so ShellCheck cannot follow this source statically.
# shellcheck disable=SC1091
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-reinstall-recovery.XXXXXX")"
trap 'exec 20>&- 2>/dev/null || true; rm -rf -- "${work}"' EXIT
base="${work}/base"
prefix="${work}/user"
mkdir -p \
  "${base}/Cellar/foo/1.0/bin" "${base}/opt" "${base}/var/homebrew/linked" \
  "${base}/var/homebrew/locks" \
  "${prefix}/Cellar/.homebrew-overlay-failed" "${prefix}/opt" \
  "${prefix}/var/homebrew/linked" "${prefix}/var/homebrew/locks" \
  "${prefix}/var/homebrew/overlay/transactions/.locks" "${prefix}/var/homebrew/overlay/sync"
printf 'base\n' >"${base}/Cellar/foo/1.0/bin/foo"
ln -s "${base}/Cellar/foo/1.0" "${base}/opt/foo"
ln -s "${base}/Cellar/foo/1.0" "${base}/var/homebrew/linked/foo"
: >"${base}/var/homebrew/locks/overlay-mutation.lock"
chmod 0640 "${base}/var/homebrew/locks/overlay-mutation.lock"

export HOMEBREW_PREFIX="${prefix}"
export HOMEBREW_OVERLAY_BASE_PREFIX="${base}"
export HOMEBREW_OVERLAY=1
export HOMEBREW_OVERLAY_ACTIVE=1

make_control() {
  local id="$1"
  local state="$2"
  local root="${prefix}/Cellar/.homebrew-overlay-failed/${id}"
  mkdir -p "${root}"
  : >"${root}/owner.lock"
  chmod 0600 "${root}/owner.lock"
  printf 'foo\n' >"${root}/formula"
  printf '2.0\n' >"${root}/version"
  printf '%s\n' "${state}" >"${root}/state"
  chmod 0600 "${root}/formula" "${root}/version" "${root}/state"
  printf '%s\n' "${root}"
}

# A crash before moving the old keg leaves only prepared metadata; it is safe
# to discard without touching the live rack.
prepared="$(make_control reinstall-100-1111111111111111 prepared)"
homebrew-overlay-recover-reinstall-backups "${prefix}" "${base}"
test ! -e "${prepared}"

# A backed-up old keg wins when no durable replacement exists.
restore="$(make_control reinstall-101-2222222222222222 backed-up)"
mkdir -p "${restore}/backup/foo/2.0/bin" "${prefix}/Cellar/foo"
printf 'old\n' >"${restore}/backup/foo/2.0/bin/foo"
ln -s "${base}/Cellar/foo/1.0" "${prefix}/Cellar/foo/1.0"
homebrew-overlay-recover-reinstall-backups "${prefix}" "${base}" 2>"${work}/restore.stderr"
grep -q "recovered interrupted overlay reinstall of foo" "${work}/restore.stderr"
grep -qx old "${prefix}/Cellar/foo/2.0/bin/foo"
test ! -e "${restore}"

# A replacement carrying a valid durable base-generation marker wins; the old
# backup is discarded instead of being restored beneath later side effects.
rm -rf -- "${prefix}/Cellar/foo/2.0"
committed="$(make_control reinstall-102-3333333333333333 backed-up)"
mkdir -p "${committed}/backup/foo/2.0/bin" "${prefix}/Cellar/foo/2.0/bin"
printf 'old\n' >"${committed}/backup/foo/2.0/bin/foo"
printf 'new\n' >"${prefix}/Cellar/foo/2.0/bin/foo"
printf '%064d\n' 0 >"${prefix}/Cellar/foo/2.0/.brew-overlay-base-generation"
chmod 0600 "${prefix}/Cellar/foo/2.0/.brew-overlay-base-generation"
homebrew-overlay-recover-reinstall-backups "${prefix}" "${base}"
grep -qx new "${prefix}/Cellar/foo/2.0/bin/foo"
test ! -e "${committed}"

# A live owner is never recovered by its own child synchronizer.
rm -rf -- "${prefix}/Cellar/foo/2.0"
live="$(make_control reinstall-103-4444444444444444 backed-up)"
mkdir -p "${live}/backup/foo/2.0/bin"
printf 'old\n' >"${live}/backup/foo/2.0/bin/foo"
exec 20<>"${live}/owner.lock"
flock -x 20
homebrew-overlay-recover-reinstall-backups "${prefix}" "${base}"
test -d "${live}/backup/foo/2.0"
test ! -e "${prefix}/Cellar/foo/2.0"
flock -u 20
exec 20>&-
homebrew-overlay-recover-reinstall-backups "${prefix}" "${base}" >/dev/null 2>"${work}/live-recovery.stderr"
grep -qx old "${prefix}/Cellar/foo/2.0/bin/foo"
test ! -e "${live}"

# Keep static coverage on the Ruby integration even when the target Homebrew
# development gems are unavailable to this offline shell test.
python3 \
  - "${repo}/Library/Homebrew/reinstall/reinstall.rb" \
  "${repo}/Library/Homebrew/overlay/reinstall_session.rb" \
  "${repo}/Library/Homebrew/overlay/core.rb" <<'PY'
from pathlib import Path
import sys

reinstall = Path(sys.argv[1]).read_text(encoding="utf-8")
session = Path(sys.argv[2]).read_text(encoding="utf-8")
overlay = Path(sys.argv[3]).read_text(encoding="utf-8")
assert "Homebrew::Overlay::ReinstallSession.build" in reinstall
assert "overlay_session.prepare!" in reinstall
assert "overlay_session.rollback!" in reinstall
assert "overlay_session.commit!" in reinstall
assert "Overlay.begin_mutation!" in session
assert "ReinstallBackup.new" in session
assert "committed_replacement?" in session
assert session.index("@keg.unlink") < session.index("ReinstallBackup.new")
assert "class ReinstallBackup" in overlay
assert "Cellar/\".homebrew-overlay-failed\"" not in overlay  # Path composition remains typed, not string interpolation.
assert 'HOMEBREW_CELLAR/".homebrew-overlay-failed"' in overlay
PY

printf 'overlay reinstall recovery test: PASS\n'
