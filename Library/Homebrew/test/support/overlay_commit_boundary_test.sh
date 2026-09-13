#!/bin/bash
set -euo pipefail

repository="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repository="$(cd "${repository}" && pwd -P)"

python3 - \
  "${repository}/Library/Homebrew/formula_installer.rb" \
  "${repository}/Library/Homebrew/overlay/install_session.rb" \
  "${repository}/Library/Homebrew/overlay/core.rb" <<'PY'
from pathlib import Path
import sys

installer = Path(sys.argv[1]).read_text(encoding="utf-8")
session = Path(sys.argv[2]).read_text(encoding="utf-8")
core = Path(sys.argv[3]).read_text(encoding="utf-8")

finish_start = installer.index("  def finish\n")
finish_end = installer.index("\n  sig { returns(String) }\n  def summary", finish_start)
finish = installer[finish_start:finish_end]

ordered = [
    "@overlay_install_session.publish!",
    "fix_dynamic_linkage(keg) if fix_linkage",
    "@overlay_install_session.commit!(keg)",
    "link(keg)",
    "install_service",
    "formula.install_etc_var",
]
positions = [finish.index(fragment) for fragment in ordered]
if positions != sorted(positions) or len(set(positions)) != len(positions):
    raise SystemExit(
        f"overlay package commit boundary is out of order: {list(zip(ordered, positions))}"
    )

installer_required = [
    "matching native Homebrew's installed-but-unlinked/post-install-failed",
    "@overlay_install_session.abort!",
    "@overlay_install_session.close!",
]
for fragment in installer_required:
    if fragment not in installer:
        raise SystemExit(f"missing FormulaInstaller commit-boundary guard: {fragment}")

session_required = [
    "return if package_committed?",
    "return if @base_generation.nil?",
    "return unless Homebrew.failed?",
    "uncommitted package state was discarded",
    "transaction.rollback! if transaction && !transaction.finished?",
    "return if managed? || !@mutation_owned",
]
for fragment in session_required:
    if fragment not in session:
        raise SystemExit(f"missing InstallSession commit-boundary guard: {fragment}")

install_start = installer.index("  def install\n")
install_end = installer.index("\n  sig { void }\n  def check_conflicts", install_start)
install = installer[install_start:install_end]
install_order = [
    "@overlay_install_session.start!(formula)",
    "@overlay_install_session.validate_install!",
]
install_positions = [install.index(fragment) for fragment in install_order]
if install_positions != sorted(install_positions):
    raise SystemExit(
        "overlay install-session validation is out of order: "
        f"{list(zip(install_order, install_positions))}"
    )

start_method_start = session.index("      def start!(formula)\n")
start_method_end = session.index(
    "      sig { returns(T::Hash[String, String]) }\n"
    "      def build_environment\n",
    start_method_start,
)
start_method = session[start_method_start:start_method_end]
isolation_order = [
    "return if @base_generation.nil?",
    "@previous_failed = Homebrew.failed?",
    "Homebrew.failed = false",
]
isolation_positions = [start_method.index(fragment) for fragment in isolation_order]
if isolation_positions != sorted(isolation_positions):
    raise SystemExit(
        "overlay non-raising failure isolation is out of order: "
        f"{list(zip(isolation_order, isolation_positions))}"
    )

validate_start = session.index("      def validate_install!\n")
validate_end = session.index("\n      end", validate_start)
validate = session[validate_start:validate_end]
validate_order = ["verify_base_generation!", "raise_transaction_failure!"]
validate_positions = [validate.index(fragment) for fragment in validate_order]
if validate_positions != sorted(validate_positions):
    raise SystemExit(
        "overlay package validation is out of order: "
        f"{list(zip(validate_order, validate_positions))}"
    )

session_commit_start = session.index("      def commit!(keg)\n")
session_commit_end = session.index(
    "      sig { void }\n      def complete_native_install!\n",
    session_commit_start,
)
session_commit = session[session_commit_start:session_commit_end]
non_transaction_order = [
    "Overlay.record_base_generation!",
    "Overlay.mark_reinstall_committed!",
    "Overlay.bump_generation!",
]
non_transaction_positions = [session_commit.index(fragment) for fragment in non_transaction_order]
if non_transaction_positions != sorted(non_transaction_positions):
    raise SystemExit(
        "non-transaction reinstall commit evidence is out of order: "
        f"{list(zip(non_transaction_order, non_transaction_positions))}"
    )

transaction_commit_start = core.index("      def commit!\n")
transaction_commit_end = core.index(
    "      sig { void }\n      def rollback!\n",
    transaction_commit_start,
)
transaction_commit = core[transaction_commit_start:transaction_commit_end]
transaction_order = [
    'write_state("committing")',
    "Overlay.mark_reinstall_committed!",
    "Overlay.durable_unlink!(marker)",
    'write_state("committed")',
]
transaction_positions = [transaction_commit.index(fragment) for fragment in transaction_order]
if transaction_positions != sorted(transaction_positions):
    raise SystemExit(
        "transaction reinstall commit evidence is out of order: "
        f"{list(zip(transaction_order, transaction_positions))}"
    )
PY

printf 'overlay commit boundary test: PASS\n'
