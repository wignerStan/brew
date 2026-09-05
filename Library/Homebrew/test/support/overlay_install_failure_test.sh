#!/bin/bash
# Failed non-transaction installs must not retain their mutation lock or dirty marker.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-install-failure.XXXXXX")"
trap 'exec 20>&- 21>&- 2>/dev/null || true; rm -rf -- "${work}"' EXIT

base="${work}/base"
prefix="${work}/user"
mkdir -p \
  "${base}/Cellar/foo/1.0/bin" "${base}/opt" "${base}/var/homebrew/linked" \
  "${prefix}/Cellar" "${prefix}/bin" "${prefix}/sbin" "${prefix}/include" \
  "${prefix}/lib" "${prefix}/share" "${prefix}/Frameworks" "${prefix}/opt" \
  "${prefix}/var/homebrew/linked" "${prefix}/var/homebrew/overlay/transactions/.locks" \
  "${prefix}/var/homebrew/overlay/sync"
printf 'base\n' >"${base}/Cellar/foo/1.0/bin/foo"
ln -s '../Cellar/foo/1.0' "${base}/opt/foo"
ln -s '../../../Cellar/foo/1.0' "${base}/var/homebrew/linked/foo"
homebrew-overlay-ensure-generation "${base}"
homebrew-overlay-ensure-generation "${prefix}"

export HOMEBREW_PREFIX="${prefix}"
export HOMEBREW_OVERLAY_BASE_PREFIX="${base}"
export HOMEBREW_OVERLAY=1
export HOMEBREW_OVERLAY_ACTIVE=1
unset HOMEBREW_OVERLAY_MUTATION_OWNER HOMEBREW_OVERLAY_FINALIZE_MUTATION \
  HOMEBREW_OVERLAY_MUTATION_LOCK_FD HOMEBREW_OVERLAY_OWNER_TRANSACTION_ID \
  HOMEBREW_OVERLAY_OWNER_TRANSACTION_LOCK_FD
homebrew-overlay-sync --force

# Model the exact no-keg failure state: the Ruby owner has already locked and
# dirtied the prefix, but the formula never created a local realization.
mutation_lock="$(homebrew-overlay-mutation-lock-file "${prefix}")"
exec 20<>"${mutation_lock}"
flock -x 20
homebrew-overlay-mark-generation-dirty "${prefix}"
dirty_file="$(homebrew-overlay-generation-dirty-file "${prefix}")"
test -f "${dirty_file}"
test ! -e "${prefix}/Cellar/no-keg"

# The owning failure cleanup must reconcile the empty change, clear the marker,
# and release the descriptor when the Ruby process closes it.
HOMEBREW_OVERLAY_MUTATION_LOCK_FD=20 \
  HOMEBREW_OVERLAY_FINALIZE_MUTATION=1 \
  homebrew-overlay-sync --force
test ! -e "${dirty_file}"
exec 20>&-
exec 21<>"${mutation_lock}"
flock -x -n 21
flock -u 21
exec 21>&-

# Guard the FormulaInstaller delegation and InstallSession cleanup ordering
# independently of RSpec, which is unavailable in the offline continuation runtime.
python3 - \
  "${repo}/Library/Homebrew/formula_installer.rb" \
  "${repo}/Library/Homebrew/overlay/install_session.rb" <<'PY'
from pathlib import Path
import sys

installer = Path(sys.argv[1]).read_text(encoding="utf-8")
session = Path(sys.argv[2]).read_text(encoding="utf-8")

assert "@overlay_install_session = T.let(" in installer
assert "Homebrew::Overlay::InstallSession.new" in installer

install_start = installer.index("  def install\n")
install_end = installer.index("  sig { void }\n  def check_conflicts", install_start)
install = installer[install_start:install_end]
start = install.index("@overlay_install_session.start!(formula)")
rescue = install.index("  rescue Exception", start)
abort = install.index("@overlay_install_session.abort!", rescue)
close = install.index("@overlay_install_session.close!", abort)
assert start < rescue < abort < close

finish_start = installer.index("  def finish\n")
finish_end = installer.index("  sig { returns(String) }\n  def summary", finish_start)
finish = installer[finish_start:finish_end]
publish = finish.index("@overlay_install_session.publish!")
commit = finish.index("@overlay_install_session.commit!(keg)", publish)
finish_rescue = finish.index("  rescue Exception", commit)
finish_abort = finish.index("@overlay_install_session.abort!", finish_rescue)
finish_ensure = finish.index("  ensure", finish_abort)
finish_close = finish.index("@overlay_install_session.close!", finish_ensure)
assert publish < commit < finish_rescue < finish_abort < finish_ensure < finish_close

assert "@mutation_owned = T.let(false, T::Boolean)" in session
start_method_start = session.index("      def start!(formula)\n")
start_method_end = session.index(
    "      sig { returns(T::Hash[String, String]) }\n"
    "      def build_environment\n",
    start_method_start,
)
start_method = session[start_method_start:start_method_end]
begin_mutation = start_method.index("Overlay.begin_mutation!")
own_mutation = start_method.index("@mutation_owned = true", begin_mutation)
assert begin_mutation < own_mutation

abort_method_start = session.index("      def abort!\n")
abort_method_end = session.index(
    "      sig { void }\n      def close!\n",
    abort_method_start,
)
abort_method = session[abort_method_start:abort_method_end]
rollback = abort_method.index("rollback_uncommitted_local_keg!")
abort_ensure = abort_method.index("ensure", rollback)
finalize = abort_method.index("finalize_failed_mutation!", abort_ensure)
assert rollback < abort_ensure < finalize

helper_start = session.index("      def finalize_failed_mutation!\n")
helper_end = session.index(
    "      sig { void }\n      def restore_failure_scope!\n",
    helper_start,
)
helper = session[helper_start:helper_end]
assert "return unless @mutation_owned" in helper
assert "Overlay.mutation_active?" in helper
assert "Overlay.sync!(mutation: true)" in helper
assert "@mutation_owned = false" in helper
PY

printf 'overlay failed-install mutation test: PASS\n'
