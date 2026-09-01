#!/usr/bin/env python3
from __future__ import annotations

import base64
import sys
from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> None:
    file_path = Path(path)
    source = file_path.read_text(encoding="utf-8")
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    file_path.write_text(source.replace(old, new), encoding="utf-8")


def insert_before_once(path: str, marker: str, insertion: str, label: str) -> None:
    replace_once(path, marker, insertion + marker, label)


def recovery() -> None:
    replace_once(
        "Library/Homebrew/overlay/install_session.rb",
        """        if (transaction = @transaction)
          transaction.commit!
        elsif (generation = @base_generation)
          Overlay.verify_base_generation!(generation)
          Overlay.record_base_generation!(keg.to_path, generation)
          Overlay.verify_base_generation!(generation)
          @local_keg_committed = true
          Overlay.bump_generation!
          @mutation_owned = false
        end
        Overlay.mark_reinstall_committed!(formula_name, formula_version, keg.to_path)
""",
        """        if (transaction = @transaction)
          transaction.commit!
        elsif (generation = @base_generation)
          Overlay.verify_base_generation!(generation)
          Overlay.record_base_generation!(keg.to_path, generation)
          Overlay.verify_base_generation!(generation)
          @local_keg_committed = true
          Overlay.mark_reinstall_committed!(formula_name, formula_version, keg.to_path)
          Overlay.bump_generation!
          @mutation_owned = false
        end
""",
        "install-session reinstall commit ordering",
    )
    replace_once(
        "Library/Homebrew/overlay/install_session.rb",
        "        return if managed?\n\n        Overlay.bump_generation!\n",
        "        return if managed? || !@mutation_owned\n\n        Overlay.bump_generation!\n",
        "outer mutation ownership",
    )
    replace_once(
        "Library/Homebrew/overlay/core.rb",
        """        write_state("committing")
        marker = final_version/TRANSACTION_MARKER
""",
        """        write_state("committing")
        Overlay.mark_reinstall_committed!(formula_name, version, final_version)
        marker = final_version/TRANSACTION_MARKER
""",
        "transaction reinstall commit bridge",
    )

    replace_once(
        "Library/Homebrew/test/formula_installer_spec.rb",
        "      expect(Homebrew::Overlay).to receive(:bump_generation!).ordered\n\n      installer.finish\n",
        "      expect(Homebrew::Overlay).not_to receive(:bump_generation!)\n\n      installer.finish\n",
        "formula-installer outer mutation expectation",
    )

    replace_once(
        "Library/Homebrew/test/overlay/install_session_spec.rb",
        """    allow(Homebrew::Overlay).to receive_messages(
      active?:                     false,
      local_keg_realization?:      false,
      mutation_active?:            false,
      release_base_mutation_lease: nil,
    )
""",
        """    allow(Homebrew::Overlay).to receive_messages(
      active?:                      false,
      local_keg_realization?:       false,
      mark_reinstall_committed!:    nil,
      mutation_active?:             false,
      release_base_mutation_lease:  nil,
    )
""",
        "install-session default stubs",
    )
    replace_once(
        "Library/Homebrew/test/overlay/install_session_spec.rb",
        """    expect(Homebrew::Overlay).to receive(:verify_base_generation!).with(generation).exactly(3).times
    expect(Homebrew::Overlay).to receive(:record_base_generation!).with(keg.to_path, generation)
    expect(Homebrew::Overlay).to receive(:bump_generation!)
    session.commit!(keg)
""",
        """    expect(Homebrew::Overlay).to receive(:verify_base_generation!).with(generation).ordered
    expect(Homebrew::Overlay).to receive(:verify_base_generation!).with(generation).ordered
    expect(Homebrew::Overlay).to receive(:record_base_generation!).with(keg.to_path, generation).ordered
    expect(Homebrew::Overlay).to receive(:verify_base_generation!).with(generation).ordered
    expect(Homebrew::Overlay).to receive(:mark_reinstall_committed!)
      .with("foo", "2.0", keg.to_path)
      .ordered
    expect(Homebrew::Overlay).to receive(:bump_generation!).ordered
    session.commit!(keg)
""",
        "install-session durable ordering spec",
    )
    insert_before_once(
        "Library/Homebrew/test/overlay/install_session_spec.rb",
        "end\n",
        """
  it "leaves an outer writable mutation for its owner to finalize" do
    allow(Homebrew::EnvConfig).to receive(:overlay?).and_return(true)
    allow(Homebrew::Overlay).to receive(:mutation_active?).and_return(true)
    expect(Homebrew::Overlay).not_to receive(:begin_mutation!)

    session = described_class.new
    session.start!(formula)

    expect(session.managed?).to be(false)
    expect(Homebrew::Overlay).not_to receive(:bump_generation!)
    session.complete_native_install!
  end
""",
        "outer mutation ownership spec",
    )

    replace_once(
        "Library/Homebrew/test/overlay/core_spec.rb",
        """    allow(described_class).to receive(:durable_unlink!).and_wrap_original do |original, path|
      events << [:unlink, path]
      original.call(path)
    end

    transaction.publish!
""",
        """    allow(described_class).to receive(:durable_unlink!).and_wrap_original do |original, path|
      events << [:unlink, path]
      original.call(path)
    end
    allow(described_class).to receive(:mark_reinstall_committed!).and_wrap_original do |original, name, version, path|
      events << [:reinstall_commit, name, version, path]
      original.call(name, version, path)
    end

    transaction.publish!
""",
        "transaction event instrumentation",
    )
    replace_once(
        "Library/Homebrew/test/overlay/core_spec.rb",
        """      [:write, base_marker, "#{base_generation}\n"],
      [:write, state_file, "committing\n"],
      [:unlink, final_transaction_marker],
""",
        """      [:write, base_marker, "#{base_generation}\n"],
      [:write, state_file, "committing\n"],
      [:reinstall_commit, "foo", "2.0", transaction.final_version],
      [:unlink, final_transaction_marker],
""",
        "transaction event ordering",
    )

    commit_test = r"""#!/bin/bash
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
"""
    Path("Library/Homebrew/test/support/overlay_commit_boundary_test.sh").write_text(
        commit_test,
        encoding="utf-8",
    )


def workflows() -> None:
    files = {
        ".github/workflows/rebase-upstream-overlay.yml": "bmFtZTogUmViYXNlIGFuZCB2YWxpZGF0ZSBvdmVybGF5IGJyYW5jaAoKb246CiAgd29ya2Zsb3dfZGlzcGF0Y2g6CiAgc2NoZWR1bGU6CiAgICAtIGNyb246ICIxNyA0ICogKiAqIgoKcGVybWlzc2lvbnM6IHt9Cgpjb25jdXJyZW5jeToKICBncm91cDogcmViYXNlLW92ZXJsYXktYnJhbmNoCiAgY2FuY2VsLWluLXByb2dyZXNzOiBmYWxzZQoKZW52OgogIENJOiAiMSIKICBIT01FQlJFV19ERVZFTE9QRVI6ICIxIgogIEhPTUVCUkVXX05PX0FVVE9fVVBEQVRFOiAiMSIKCmpvYnM6CiAgcHJlcGFyZToKICAgIGlmOiBnaXRodWIucmVwb3NpdG9yeSA9PSAnd2FuZ3poZW5nMTU1MzQtYmxpcC9icmV3JwogICAgcnVucy1vbjogdWJ1bnR1LWxhdGVzdAogICAgdGltZW91dC1taW51dGVzOiAzMAogICAgcGVybWlzc2lvbnM6CiAgICAgIGNvbnRlbnRzOiB3cml0ZQogICAgb3V0cHV0czoKICAgICAgY2hhbmdlZDogJHt7IHN0ZXBzLnJlYmFzZS5vdXRwdXRzLmNoYW5nZWQgfX0KICAgICAgYmVmb3JlOiAke3sgc3RlcHMucmViYXNlLm91dHB1dHMuYmVmb3JlIH19CiAgICAgIGFmdGVyOiAke3sgc3RlcHMucmViYXNlLm91dHB1dHMuYWZ0ZXIgfX0KICAgICAgdHJlZTogJHt7IHN0ZXBzLnJlYmFzZS5vdXRwdXRzLnRyZWUgfX0KICAgIHN0ZXBzOgogICAgICAtIG5hbWU6IENoZWNrIG91dCB0aGUgZGVwbG95bWVudCBicmFuY2ggd2l0aG91dCBwZXJzaXN0ZWQgY3JlZGVudGlhbHMKICAgICAgICB1c2VzOiBhY3Rpb25zL2NoZWNrb3V0QDExYmQ3MTkwMWJiZTViMTYzMGNlZWE3M2QyNzU5NzM2NGM5YWY2ODMgIyB2NC4yLjIKICAgICAgICB3aXRoOgogICAgICAgICAgcmVmOiBvdmVybGF5LXN0b3JlCiAgICAgICAgICBmZXRjaC1kZXB0aDogMAogICAgICAgICAgcGVyc2lzdC1jcmVkZW50aWFsczogZmFsc2UKCiAgICAgIC0gbmFtZTogUmViYXNlIG9udG8gY3VycmVudCBIb21lYnJldyBtYWluCiAgICAgICAgaWQ6IHJlYmFzZQogICAgICAgIHNoZWxsOiBiYXNoCiAgICAgICAgcnVuOiB8CiAgICAgICAgICBzZXQgLWV1byBwaXBlZmFpbAoKICAgICAgICAgIGV4cG9ydCBQQVRIPS91c3IvYmluOi9iaW4KICAgICAgICAgIGdpdCBjb25maWcgdXNlci5uYW1lICJnaXRodWItYWN0aW9uc1tib3RdIgogICAgICAgICAgZ2l0IGNvbmZpZyB1c2VyLmVtYWlsICI0MTg5ODI4MitnaXRodWItYWN0aW9uc1tib3RdQHVzZXJzLm5vcmVwbHkuZ2l0aHViLmNvbSIKICAgICAgICAgIGdpdCBjb25maWcgY29yZS5ob29rc1BhdGggL2Rldi9udWxsCiAgICAgICAgICBnaXQgcmVtb3RlIGFkZCB1cHN0cmVhbSBodHRwczovL2dpdGh1Yi5jb20vSG9tZWJyZXcvYnJldy5naXQgMj4vZGV2L251bGwgfHwKICAgICAgICAgICAgZ2l0IHJlbW90ZSBzZXQtdXJsIHVwc3RyZWFtIGh0dHBzOi8vZ2l0aHViLmNvbS9Ib21lYnJldy9icmV3LmdpdAogICAgICAgICAgZ2l0IGZldGNoIC0tcHJ1bmUgb3JpZ2luIG92ZXJsYXktc3RvcmUKICAgICAgICAgIGdpdCBmZXRjaCAtLXBydW5lIHVwc3RyZWFtIG1haW4KICAgICAgICAgIGdpdCBjaGVja291dCAtLWRldGFjaCBvcmlnaW4vb3ZlcmxheS1zdG9yZQoKICAgICAgICAgIGJlZm9yZT0iJChnaXQgcmV2LXBhcnNlIEhFQUQpIgogICAgICAgICAgcHJpbnRmICdiZWZvcmU9JXNcbicgIiR7YmVmb3JlfSIgPj4iJHtHSVRIVUJfT1VUUFVUfSIKICAgICAgICAgIGlmICEgZ2l0IC1jIGNvcmUuaG9va3NQYXRoPS9kZXYvbnVsbCByZWJhc2UgdXBzdHJlYW0vbWFpbjsgdGhlbgogICAgICAgICAgICBnaXQgcmViYXNlIC0tYWJvcnQgfHwgdHJ1ZQogICAgICAgICAgICBlY2hvICJVcHN0cmVhbSByZWJhc2UgaGFzIHNlbWFudGljIGNvbmZsaWN0czsgb3ZlcmxheS1zdG9yZSB3YXMgbGVmdCB1bmNoYW5nZWQuIiA+JjIKICAgICAgICAgICAgZXhpdCAxCiAgICAgICAgICBmaQoKICAgICAgICAgIGFmdGVyPSIkKGdpdCByZXYtcGFyc2UgSEVBRCkiCiAgICAgICAgICB0cmVlPSIkKGdpdCByZXYtcGFyc2UgJ0hFQURee3RyZWV9JykiCiAgICAgICAgICBwcmludGYgJ2FmdGVyPSVzXG4nICIke2FmdGVyfSIgPj4iJHtHSVRIVUJfT1VUUFVUfSIKICAgICAgICAgIHByaW50ZiAndHJlZT0lc1xuJyAiJHt0cmVlfSIgPj4iJHtHSVRIVUJfT1VUUFVUfSIKICAgICAgICAgIGlmIFtbICIke2JlZm9yZX0iID09ICIke2FmdGVyfSIgXV07IHRoZW4KICAgICAgICAgICAgcHJpbnRmICdjaGFuZ2VkPWZhbHNlXG4nID4+IiR7R0lUSFVCX09VVFBVVH0iCiAgICAgICAgICBlbHNlCiAgICAgICAgICAgIHByaW50ZiAnY2hhbmdlZD10cnVlXG4nID4+IiR7R0lUSFVCX09VVFBVVH0iCiAgICAgICAgICBmaQoKICAgICAgLSBuYW1lOiBQdWJsaXNoIHRoZSBpbW11dGFibGUgY2FuZGlkYXRlIHdpdGggdGhlIHJlcG9zaXRvcnkgdG9rZW4KICAgICAgICBpZjogc3RlcHMucmViYXNlLm91dHB1dHMuY2hhbmdlZCA9PSAndHJ1ZScKICAgICAgICBzaGVsbDogYmFzaAogICAgICAgIGVudjoKICAgICAgICAgIEF GVEVSOiAke3sgc3RlcHMucmViYXNlLm91dHB1dHMuYWZ0ZXIgfX0KICAgICAgICAgIEVYUEVDVEVEX1RSRUU6ICR7eyBzdGVwcy5yZWJhc2Uub3V0cHV0cy50cmVlIH19CiAgICAgICAgICBQUkVQQVJFX1RPS0VOOiAke3sgZ2l0aHViLnRva2VuIH19CiAgICAgICAgcnVuOiB8CiAgICAgICAgICBzZXQgLWV1byBwaXBlZmFpbAoKICAgICAgICAgIGV4cG9ydCBQQVRIPS91c3IvYmluOi9iaW4KICAgICAgICAgIHRlc3QgIiQoL3Vzci9iaW4vZ2l0IHJldi1wYXJzZSBIRUFEKSIgPSAiJHtBRlRFUn0iCiAgICAgICAgICB0ZXN0ICIkKC91c3IvYmluL2dpdCByZXYtcGFyc2UgJ0hFQURee3RyZWV9JykiID0gIiR7RVhQRUNURURfVFJFRX0iCgogICAgICAgICAgaXNvbGF0ZWRfaG9tZT0iJChta3RlbXAgLWQpIgogICAgICAgICAgYXNrcGFzcz0iJChta3RlbXApIgogICAgICAgICAgdHJhcCAncm0gLXJmICIke2lzb2xhdGVkX2hvbWV9Ijsgcm0gLWYgIiR7YXNrcGFzc30iJyBFWElUCiAgICAgICAgICBleHBvcnQgSE9NRT0iJHtp c29sYXRlZF9ob21lfSIKICAgICAgICAgIGV4cG9ydCBHSVRfQ09ORklHX05PU1lTVEVNPTEKICAgICAgICAgIGV4cG9ydCBHSVRfQ09ORklHX0dMT0JB TD0vZGV2L251bGwKCiAgICAgICAgICBjYXQgPiIke2Fza3Bhc3N9IiA8PCdBU0tQQVNTJwogICAgICAgICAgIyEvYmluL3NoCiAgICAgICAgICBjYXNlICIkMSIgaW4KICAgICAgICAgICAgKlVzZXJuYW1lKSBwcmludGYgJyVzXG4nIHgtYWNjZXNzLXRva2VuIDs7CiAgICAgICAgICAgICopIHByaW50ZiAnJXNcbicgIiR7UFJFUEFSRV9UT0tFTjo/fSIgOzsKICAgICAgICAgIGVzYWMKICAgICAgICAgIEFTS1BBU1MKICAgICAgICAgIGNobW9kIDA3MDAgIiR7YXNrcGFzc30iCgogICAgICAgICAgdGFyZ2V0X3VybD0iaHR0cHM6Ly9naXRodWIuY29tLyR7R0lUSFVCX1JFUE9TSVRPUll9LmdpdCIKICAgICAgICAgIC91c3IvYmluL2dpdCByZW1vdGUgc2V0LXVybCBvcmlnaW4gIiR7dGFyZ2V0X3VybH0iCiAgICAgICAgICB0ZXN0ICIkKC91c3IvYmluL2dpdCByZW1vdGUgZ2V0LXVybCBvcmlnaW4pIiA9ICIke3RhcmdldF91cmx9IgogICAgICAgICAgY2FuZGlkYXRlX3JlZj1yZWZzL2hlYWRzL2F1dG9tYXRpb24vb3ZlcmxheS1yZWJhc2UtY2FuZGlkYXRlCiAgICAgICAgICBjYW5kaWRhdGVfYmVmb3JlPSIkKAogICAgICAgICAgICBHSVRfQVNLUEFTUz0iJHthc2twYXNzfSIgR0lUX1RFUk1JTkFMX1BST01QVD0wIFwKICAgICAgICAgICAgICAvdXNyL2Jpbi9naXQgbHMtcmVtb3RlIC0taGVhZHMgb3JpZ2luICIke2NhbmRpZGF0ZV9yZWZ9IiB8IC91c3IvYmluL2F3ayAne3ByaW50ICQxfScKICAgICAgICAgICkiCiAgICAgICAgICBHSVRfQVNLUEFTUz0iJHthc2twYXNzfSIgR0lUX1RFUk1JTkFMX1BST01QVD0wIFwKICAgICAgICAgICAgL3Vzci9iaW4vZ2l0IHB1c2ggXAogICAgICAgICAgICAgIC0tZm9yY2Utd2l0aC1sZWFzZT0iJHtjYW5kaWRhdGVfcmVmfToke2NhbmRpZGF0ZV9iZWZvcmV9IiBcCiAgICAgICAgICAgICAgb3JpZ2luICIke0FGVEVSfToke2NhbmRpZGF0ZV9yZWZ9IgoKICB2YWxpZGF0ZToKICAgIG5lZWRzOiBwcmVwYXJlCiAgICBpZjogbmVlZHMucHJlcGFyZS5vdXRwdXRzLmNoYW5nZWQgPT0gJ3RydWUnCiAgICBydW5zLW9uOiB1YnVudHUtbGF0ZXN0CiAgICB0aW1lb3V0LW1pbnV0ZXM6IDE1MAogICAgcGVybWlzc2lvbnM6CiAgICAgIGNvbnRlbnRzOiByZWFkCiAgICBzdGVwczoKICAgICAgLSBuYW1lOiBDaGVjayBvdXQgdGhlIGV4YWN0IHByb3Bvc2VkIFNIQSBvbiBhIGZyZXNoIHJ1bm5lcgogICAgICAgIHVzZXM6IGFjdGlvbnMvY2hlY2tvdXRAMTFiZDcxOTAxYmJlNWIxNjMwY2VlYTczZDI3NTk3MzY0YzlhZjY4MyAjIHY0LjIuMgogICAgICAgIHdpdGg6CiAgICAgICAgICByZWY6ICR7eyBuZWVkcy5wcmVwYXJlLm91dHB1dHMuYWZ0ZXIgfX0KICAgICAgICAgIGZldGNoLWRlcHRoOiAwCiAgICAgICAgICBwZXJzaXN0LWNyZWRlbnRpYWxzOiBmYWxzZQoKICAgICAgLSBuYW1lOiBWZXJpZnkgdGhlIGltbXV0YWJsZSBjYW5kaWRhdGUgYW5kIGNvbXBhcmlzb24gYmFzZQogICAgICAgIHNoZWxsOiBiYXNoCiAgICAgICAgZW52OgogICAgICAgICAgQUZURVI6ICR7eyBuZWVkcy5wcmVwYXJlLm91dHB1dHMuYWZ0ZXIgfX0KICAgICAgICAgIEVYUEVDVEVEX1RSRUU6ICR7eyBuZWVkcy5wcmVwYXJlLm91dHB1dHMudHJlZSB9fQogICAgICAgIHJ1bjogfAogICAgICAgICAgc2V0IC1ldW8gcGlwZWZhaWwKCiAgICAgICAgICBleHBvcnQgUEFUSD0vdXNyL2JpbjovYmluCiAgICAgICAgICAvdXNyL2Jpbi9naXQgY29uZmlnIGNvcmUuaG9va3NQYXRoIC9kZXYvbnVsbAogICAgICAgICAgL3Vzci9iaW4vZ2l0IHJlbW90ZSBhZGQgdXBzdHJlYW0gaHR0cHM6Ly9naXRodWIuY29tL0hvbWVicmV3L2JyZXcuZ2l0IDI+L2Rldi9udWxsIHx8CiAgICAgICAgICAgIC91c3IvYmluL2dpdCByZW1vdGUgc2V0LXVybCB1cHN0cmVhbSBodHRwczovL2dpdGh1Yi5jb20vSG9tZWJyZXcvYnJldy5naXQKICAgICAgICAgIC91c3IvYmluL2dpdCBmZXRjaCAtLXBydW5lIHVwc3RyZWFtIG1haW4KICAgICAgICAgIC91c3IvYmluL2dpdCBmZXRjaCAtLXBydW5lIG9yaWdpbiBhdXRvbWF0aW9uL292ZXJsYXktcmViYXNlLWNhbmRpZGF0ZQogICAgICAgICAgdGVzdCAiJCgvdXNyL2Jpbi9naXQgcmV2LXBhcnNlIEhFQUQpIiA9ICIke0FGVEVSfSIKICAgICAgICAgIHRlc3QgIiQoL3Vzci9iaW4vZ2l0IHJldi1wYXJzZSBGRVRDSF9IRUFEKSIgPSAiJHtBRlRFUn0iCiAgICAgICAgICB0ZXN0ICIkKC91c3IvYmluL2dpdCByZXYtcGFyc2UgJ0hFQURee3RyZWV9JykiID0gIiR7RVhQRUNURURfVFJFRX0iCgogICAgICAtIG5hbWU6IFZhbGlkYXRlIHBhdGNoIGZvcm1hdHRpbmcgYW5kIHNoZWxsIHN5bnRheAogICAgICAgIHNoZWxsOiBiYXNoCiAgICAgICAgcnVuOiB8CiAgICAgICAgICBzZXQgLWV1byBwaXBlZmFpbAogICAgICAgICAgZ2l0IGRpZmYgLS1jaGVjayB1cHN0cmVhbS9tYWluLi4uSEVBRAogICAgICAgICAgYmFzaCAtbiBiaW4vYnJldyBMaWJyYXJ5L0hvbWVicmV3L3V0aWxzL292ZXJsYXkuc2gKICAgICAgICAgIHdoaWxlIElGUz0gcmVhZCAtciB0ZXN0X3NjcmlwdDsgZG8KICAgICAgICAgICAgYmFzaCAtbiAiJHt0ZXN0X3NjcmlwdH0iCiAgICAgICAgICBkb25lIDwgPChmaW5kIExpYnJhcnkvSG9tZWJyZXcvdGVzdC9zdXBwb3J0IC1tYXhkZXB0aCAxIC1uYW1lICdvdmVybGF5Xyouc2gnIC1wcmludCB8IHNvcnQpCiAgICAgICAgICBweXRob24zIC1tIHB5X2NvbXBpbGUgTGlicmFyeS9Ib21lYnJldy90ZXN0L3N1cHBvcnQvb3ZlcmxheV9zdHlsZV9kZWx0YV9jaGVjay5weQoKICAgICAgLSBuYW1lOiBSdW4gY29tcGxldGUgb3ZlcmxheSByZWNvdmVyeSBtYXRyaXgKICAgICAgICBzaGVsbDogYmFzaAogICAgICAgIHJ1bjogfAogICAgICAgICAgc2V0IC1ldW8gcGlwZWZhaWwKICAgICAgICAgIGJhc2ggTGlicmFyeS9Ib21lYnJldy90ZXN0L3N1cHBvcnQvb3ZlcmxheV9maW5hbF9yZXZpZXdfcmVwcm9kdWNlci5zaCAiJFBXRCIKCiAgICAgIC0gbmFtZTogUnVuIGZ1bGwgSG9tZWJyZXcgUlNwZWMgc3VpdGUKICAgICAgICBzaGVsbDogYmFzaAogICAgICAgIHJ1bjogfAogICAgICAgICAgc2V0IC1ldW8gcGlwZWZhaWwKICAgICAgICAgIGJpbi9icmV3IHRlc3RzIC0tbm8tcGFyYWxsZWwKCiAgICAgIC0gbmFtZTogUmVqZWN0IHN0eWxlIG9mZmVuc2VzIG9uIHRoZSByZWJhc2VkIG92ZXJsYXkgZGVsdGEKICAgICAgICBzaGVsbDogYmFzaAogICAgICAgIHJ1bjogfAogICAgICAgICAgc2V0IC1ldW8gcGlwZWZhaWwKICAgICAgICAgIHB5dGhvbjMgTGlicmFyeS9Ib21lYnJldy90ZXN0L3N1cHBvcnQvb3ZlcmxheV9zdHlsZV9kZWx0YV9jaGVjay5weSB1cHN0cmVhbS9tYWluIEhFQUQKCiAgICAgIC0gbmFtZTogUnVuIFNvcmJldAogICAgICAgIHNoZWxsOiBiYXNoCiAgICAgICAgcnVuOiB8CiAgICAgICAgICBzZXQgLWV1byBwaXBlZmFpbAogICAgICAgICAgYmluL2JyZXcgdHlwZWNoZWNrCgogICAgICAtIG5hbWU6IFZlcmlmeSB0aGUgZXhhY3QgdmFsaWRhdGVkIG9iamVjdCBhZnRlciBjYW5kaWRhdGUgZXhlY3V0aW9uCiAgICAgICAgc2hlbGw6IGJhc2gKICAgICAgICBlbnY6CiAgICAgICAgICBBRlRFUjogJHt7IG5lZWRzLnByZXBhcmUub3V0cHV0cy5hZnRlciB9fQogICAgICAgICAgRVhQRUNURURfVFJFRTo gJHt7IG5lZWRzLnByZXBhcmUub3V0cHV0cy50cmVlIH19CiAgICAgICAgcnVuOiB8CiAgICAgICAgICBzZXQgLWV1byBwaXBlZmFpbAogICAgICAgICAgZXhwb3J0IFBBVEg9L3Vzci9iaW46L2JpbgogICAgICAgICAgdGVzdCAiJCgvdXNyL2Jpbi9naXQgcmV2LXBhcnNlIEhFQUQpIiA9ICIke0FGVEVSfSIKICAgICAgICAgIHRlc3QgIiQoL3Vzci9iaW4vZ2l0IHJldi1wYXJzZSAnSEVBRF57dHJlZX0nKSIgPSAiJHtFWFBFQ1RFRF9UUkVFfSIKCiAgcHJvbW90ZToKICAgIG5lZWRzOiBbcHJlcGFyZSwgdmFsaWRhdGVdCiAgICBpZjogbmVlZHMucHJlcGFyZS5vdXRwdXRzLmNoYW5nZWQgPT0gJ3RydWUnICYmIG5lZWRzLnZhbGlkYXRlLnJlc3VsdCA9PSAnc3VjY2VzcycKICAgIHJ1bnMtb246IHVidW50dS1sYXRlc3QKICAgIHRpbWVvdXQtbWludXRlczogMTUKICAgIGVudmlyb25tZW50OiBvdmVybGF5LXByb21vdGlvbgogICAgcGVybWlzc2lvbnM6IHt9CiAgICBzdGVwczoKICAgICAgLSBuYW1lOiBQcm9tb3RlIG9ubHkgdGhlIGV4YWN0IHZhbGlkYXRlZCBvYmplY3Qgb24gYSBmcmVzaCBydW5uZXIKICAgICAgICBzaGVsbDogYmFzaAogICAgICAgIGVudjoKICAgICAgICAgIEJFRk9SRTogJHt7IG5lZWRzLnByZXBhcmUub3V0cHV0cy5iZWZvcmUgfX0KICAgICAgICAgIEF GVEVSOiAke3sgbmVlZHMucHJlcGFyZS5vdXRwdXRzLmFmdGVyIH19CiAgICAgICAgICBFWFBFQ1RFRF9UUkVFOiAke3sgbmVlZHMucHJlcGFyZS5vdXRwdXRzLnRyZWUgfX0KICAgICAgICAgIE9WRVJMQVlfUFJPTU9USU9OX1RPS0VOOiAke3sgc2VjcmV0cy5PVkVSTEFZX1BST01PVElPTl9UT0tFTiB9fQogICAgICAgIHJ1bjogfAogICAgICAgICAgc2V0IC1ldW8gcGlwZWZhaWwKCiAgICAgICAgICBpZiBbWyAteiAiJHtPVkVSTEFZX1BST01PVElPTl9UT0tFTn0iIF1dOyB0aGVuCiAgICAgICAgICAgIGVjaG8gIjo6ZXJyb3I6Ok9WRVJMQVlfUFJPTU9USU9OX1RPS0VOIG11c3QgZ3JhbnQgQ29udGVudHMgYW5kIFdvcmtmbG93cyB3cml0ZSBhY2Nlc3MgdG8gd2FuZ3poZW5nMTU1MzQtYmxpcC9icmV3IgogICAgICAgICAgICBleGl0IDEKICAgICAgICAgIGZpCgogICAgICAgICAgZXhwb3J0IFBBVEg9L3Vzci9iaW46L2JpbgogICAgICAgICAgaXNvbGF0ZWRfaG9tZT0iJChta3RlbXAgLWQpIgogICAgICAgICAgcmVwb3NpdG9yeT0iJChta3RlbXAgLWQpIgogICAgICAgICAgdGVtcGxhdGVfZGlyPSIkKG1rdGVtcCAtZCkiCiAgICAgICAgICBhc2twYXNzPSIkKG1rdGVtcCkiCiAgICAgICAgICB0cmFwICdybSAtcmYgIiR7aXNvbGF0ZWRfaG9tZX0iICIke3JlcG9zaXRvcnl9IiAiJHt0ZW1wbGF0ZV9kaXJ9Ijsgcm0gLWYgIiR7YXNrcGFzc30iJyBFWElUCiAgICAgICAgICBleHBvcnQgSE9NRT0iJHtp c29sYXRlZF9ob21lfSIKICAgICAgICAgIGV4cG9ydCBHSVRfQ09ORklHX05PU1lTVEVNPTEKICAgICAgICAgIGV4cG9ydCBHSVRfQ09ORklHX0dMT0JB TD0vZGV2L251bGwKICAgICAgICAgIGV4cG9ydCBHSVRfVEVNUExBVEVfRElSPSIke3RlbXBsYXRlX2Rpcn0iCgogICAgICAgICAgY2F0ID4iJHthc2twYXNzfSIgPDwnQVNLUEFTUycKICAgICAgICAgICMhL2Jpbi9zaAogICAgICAgICAgY2FzZSAiJDEiIGluCiAgICAgICAgICAgICpVc2VybmFtZSopIHByaW50ZiAnJXNcbicgeC1hY2Nlc3MtdG9rZW4gOzsKICAgICAgICAgICAgKikgcHJpbnRmICclc1xuJyAiJHtPVkVSTEFZX1BST01PVElPTl9UT0tFTjo/fSIgOzsKICAgICAgICAgIGVzYWMKICAgICAgICAgIEFTS1BBU1MKICAgICAgICAgIGNobW9kIDA3MDAgIiR7YXNrcGFzc30iCgogICAgICAgICAgL3Vzci9iaW4vZ2l0IGluaXQgIiR7cmVwb3NpdG9yeX0iCiAgICAgICAgICAvdXNyL2Jpbi9naXQgLUMgIiR7cmVwb3NpdG9yeX0iIGNvbmZpZyBjb3JlLmhvb2tzUGF0aCAvZGV2L251bGwKICAgICAgICAgIC91c3IvYmluL2dpdCAtQyAiJHtyZXBvc2l0b3J5fSIgY29uZmlnIHRyYW5zZmVyLmZzY2tPYmplY3RzIHRydWUKICAgICAgICAgIC91c3IvYmluL2dpdCAtQyAiJHtyZXBvc2l0b3J5fSIgY29uZmlnIGZldGNoLmZzY2tPYmplY3RzIHRydWUKICAgICAgICAgIC91c3IvYmluL2dpdCAtQyAiJHtyZXBvc2l0b3J5fSIgcmVtb3RlIGFkZCBvcmlnaW4gXAogICAgICAgICAgICBodHRwczovL2dpdGh1Yi5jb20vd2FuZ3poZW5nMTU1MzQtYmxpcC9icmV3LmdpdAogICAgICAgICAgdGVzdCAiJCgvdXNyL2Jpbi9naXQgLUMgIiR7cmVwb3NpdG9yeX0iIHJlbW90ZSBnZXQtdXJsIG9yaWdpbikiID0gXAogICAgICAgICAgICAiaHR0cHM6Ly9naXRodWIuY29tL3dhbmd6aGVuZzE1NTM0LWJsaXAvYnJldy5naXQiCgogICAgICAgICAgR0lUX0FTS1BBU1M9IiR7YXNrcGFzc30iIEdJVF9URVJNSU5BTF9QUk9NUFQ9MCBcCiAgICAgICAgICAgIC91c3IvYmluL2dpdCAtQyAiJHtyZXBvc2l0b3J5fSIgXAogICAgICAgICAgICAgIC1jIHByb3RvY29sLmZpbGUuYWxsb3c9bmV2ZXIgXAogICAgICAgICAgICAgIC1jIHByb3RvY29sLmV4dC5hbGxvdz1uZXZlciBcCiAgICAgICAgICAgICAgZmV0Y2ggLS1uby10YWdzIC0tcHJ1bmUgb3JpZ2luIFwKICAgICAgICAgICAgICArcmVmcy9oZWFkcy9hdXRvbWF0aW9uL292ZXJsYXktcmViYXNlLWNhbmRpZGF0ZTpyZWZzL3JlbW90ZXMvb3JpZ2luL2NhbmRpZGF0ZSBcCiAgICAgICAgICAgICAgK3JlZnMvaGVhZHMvb3ZlcmxheS1zdG9yZTpyZWZzL3JlbW90ZXMvb3JpZ2luL292ZXJsYXktc3RvcmUKCiAgICAgICAgICB0ZXN0ICIkKC91c3IvYmluL2dpdCAtQyAiJHtyZXBvc2l0b3J5fSIgcmV2LXBhcnNlIHJlZnMvcmVtb3Rlcy9vcmlnaW4vY2FuZGlkYXRlKSIgPSAiJHtBRlRFUn0iCiAgICAgICAgICB0ZXN0ICIkKC91c3IvYmluL2dpdCAtQyAiJHtyZXBvc2l0b3J5fSIgcmV2LXBhcnNlIHJlZnMvcmVtb3Rlcy9vcmlnaW4vb3ZlcmxheS1zdG9yZSkiID0gIiR7QkVGT1JFfSIKICAgICAgICAgIHRlc3QgIiQoL3Vzci9iaW4vZ2l0IC1DICIke3JlcG9zaXRvcnl9IiByZXYtcGFyc2UgIiR7QUZURVJ9Xnt0cmVlfSIpIiA9ICIke0VYUEVDVEVEX1RSRUV9IgoKICAgICAgICAgIEdJVF9BU0tQQVNTPSIke2Fza3Bhc3N9IiBHSVRfVEVSTUlOQUxfUFJPTVBUPTAgXAogICAgICAgICAgICAvdXNyL2Jpbi9naXQgLUMgIiR7cmVwb3NpdG9yeX0iIHB1c2ggXAogICAgICAgICAgICAgIC0tZm9yY2Utd2l0aC1sZWFzZT1yZWZzL2hlYWRzL292ZXJsYXktc3RvcmU6JHtCRUZPUkV9IFwKICAgICAgICAgICAgICBvcmlnaW4gIiR7QUZURVJ9OnJlZnMvaGVhZHMvb3ZlcmxheS1zdG9yZSIK",
        ".github/workflows/overlay-validation.yml": "bmFtZTogVmFsaWRhdGUgbmF0aXZlIG92ZXJsYXkKCm9uOgogIHB1bGxfcmVxdWVzdDoKICAgIGJyYW5jaGVzOgogICAgICAtIG92ZXJsYXktc3RvcmUKICBwdXNoOgogICAgYnJhbmNoZXM6CiAgICAgIC0gJ2ZpeC9vdmVybGF5LSonCiAgICAgIC0gJ3JlZmFjdG9yL292ZXJsYXktKicKCnBlcm1pc3Npb25zOgogIGNvbnRlbnRzOiByZWFkCgplbnY6CiAgQ0k6ICIxIgogIEhPTUVCUkVXX0RFVkVMT1BFUjogIjEiCiAgSE9NRUJSRVdfTk9fQVVUT19VUERBVEU6ICIxIgoKam9iczoKICB2YWxpZGF0ZToKICAgIHJ1bnMtb246IHVidW50dS1sYXRlc3QKICAgIHRpbWVvdXQtbWludXRlczogMTUwCiAgICBzdGVwczoKICAgICAgLSBuYW1lOiBDaGVjayBvdXQgZXhhY3QgY2FuZGlkYXRlCiAgICAgICAgdXNlczogYWN0aW9ucy9jaGVja291dEAxMWJkNzE5MDFiYmU1YjE2MzBjZWVhNzNkMjc1OTczNjRjOWFmNjgzICMgdjQuMi4yCiAgICAgICAgd2l0aDoKICAgICAgICAgIHJlZjogJHt7IGdpdGh1Yi5ldmVudC5wdWxsX3JlcXVlc3QuaGVhZC5zaGEgfHwgZ2l0aHViLnNoYSB9fQogICAgICAgICAgZmV0Y2gtZGVwdGg6IDAKICAgICAgICAgIHBlcnNpc3QtY3JlZGVudGlhbHM6IGZhbHNlCgogICAgICAtIG5hbWU6IEZldGNoIG92ZXJsYXktc3RvcmUgY29tcGFyaXNvbiBiYXNlCiAgICAgICAgc2hlbGw6IGJhc2gKICAgICAgICBydW46IHwKICAgICAgICAgIHNldCAtZXVvIHBpcGVmYWlsCiAgICAgICAgICBnaXQgZmV0Y2ggLS1wcnVuZSBvcmlnaW4gb3ZlcmxheS1zdG9yZQoKICAgICAgLSBuYW1lOiBDaGVjayBmb3JtYXR0aW5nIGFuZCBzaGVsbCBzeW50YXgKICAgICAgICBzaGVsbDogYmFzaAogICAgICAgIHJ1bjogfAogICAgICAgICAgc2V0IC1ldW8gcGlwZWZhaWwKICAgICAgICAgIGdpdCBkaWZmIC0tY2hlY2sgb3JpZ2luL292ZXJsYXktc3RvcmUuLi5IRUFECiAgICAgICAgICBiYXNoIC1uIGJpbi9icmV3IExpYnJhcnkvSG9tZWJyZXcvdXRpbHMvb3ZlcmxheS5zaAogICAgICAgICAgd2hpbGUgSUZTPSByZWFkIC1yIHRlc3Rfc2NyaXB0OyBkbwogICAgICAgICAgICBiYXNoIC1uICIke3Rlc3Rfc2NyaXB0fSIKICAgICAgICAgIGRvbmUgPCA8KGZpbmQgTGlicmFyeS9Ib21lYnJldy90ZXN0L3N1cHBvcnQgLW1heGRlcHRoIDEgLW5hbWUgJ292ZXJsYXlfKi5zaCcgLXByaW50IHwgc29ydCkKICAgICAgICAgIHB5dGhvbjMgLW0gcHlfY29tcGlsZSBMaWJyYXJ5L0hvbWVicmV3L3Rlc3Qvc3VwcG9ydC9vdmVybGF5X3N0eWxlX2RlbHRhX2NoZWNrLnB5CgogICAgICAtIG5hbWU6IFJlamVjdCBzdHlsZSBvZmZlbnNlcyBvbiBvdmVybGF5IGNoYW5nZXMKICAgICAgICBzaGVsbDogYmFzaAogICAgICAgIHJ1bjogfAogICAgICAgICAgc2V0IC1ldW8gcGlwZWZhaWwKICAgICAgICAgIHB5dGhvbjMgTGlicmFyeS9Ib21lYnJldy90ZXN0L3N1cHBvcnQvb3ZlcmxheV9zdHlsZV9kZWx0YV9jaGVjay5weSBvcmlnaW4vb3ZlcmxheS1zdG9yZSBIRUFECgogICAgICAtIG5hbWU6IFJ1biBTb3JiZXQKICAgICAgICBzaGVsbDogYmFzaAogICAgICAgIHJ1bjogfAogICAgICAgICAgc2V0IC1ldW8gcGlwZWZhaWwKICAgICAgICAgIGJpbi9icmV3IHR5cGVjaGVjawoKICAgICAgLSBuYW1lOiBSdW4gY29tcGxldGUgb3ZlcmxheSByZWNvdmVyeSBtYXRyaXgKICAgICAgICBzaGVsbDogYmFzaAogICAgICAgIHJ1bjogfAogICAgICAgICAgc2V0IC1ldW8gcGlwZWZhaWwKICAgICAgICAgIGJhc2ggTGlicmFyeS9Ib21lYnJldy90ZXN0L3N1cHBvcnQvb3ZlcmxheV9maW5hbF9yZXZpZXdfcmVwcm9kdWNlci5zaCAiJFBXRCIKCiAgICAgIC0gbmFtZTogUnVuIGZ1bGwgSG9tZWJyZXcgUlNwZWMgc3VpdGUKICAgICAgICBzaGVsbDogYmFzaAogICAgICAgIHJ1bjogfAogICAgICAgICAgc2V0IC1ldW8gcGlwZWZhaWwKICAgICAgICAgIGJpbi9icmV3IHRlc3RzIC0tbm8tcGFyYWxsZWwK",
        "Library/Homebrew/test/support/overlay_rebase_workflow_test.sh": "IyEvYmluL2Jhc2gKIyBTdGF0aWMgZ3VhcmQgZm9yIGZyZXNoLXJ1bm5lciwgZXhhY3QtU0hBIG92ZXJsYXkgYnJhbmNoIHByb21vdGlvbi4Kc2V0IC1ldW8gcGlwZWZhaWwKCnJlcG89IiR7MTotJChjZCAiJChkaXJuYW1lICIke0JBU0hfU09VUkNFWzBdfSIpLy4uLy4uLy4uIiAmJiBwd2QgLVApfSIKcmVwbz0iJChjZCAiJHtyZXBvfSIgJiYgcHdkIC1QKSIKCnB5dGhvbjMgLSBcCiAgIiR7cmVwb30vLmdpdGh1Yi93b3JrZmxvd3MvcmViYXNlLXVwc3RyZWFtLW92ZXJsYXkueW1sIiBcCiAgIiR7cmVwb30vLmdpdGh1Yi93b3JrZmxvd3Mvb3ZlcmxheS12YWxpZGF0aW9uLnltbCIgPDwnUFknCmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAppbXBvcnQgc3lzCgpyZWJhc2UgPSBQYXRoKHN5cy5hcmd2WzFdKS5yZWFkX3RleHQoZW5jb2Rpbmc9InV0Zi04IikKdmFsaWRhdGlvbiA9IFBhdGgoc3lzLmFyZ3ZbMl0pLnJlYWRfdGV4dChlbmNvZGluZz0idXRmLTgiKQoKZm9yIGpvYiBpbiAoIiAgcHJlcGFyZTpcbiIsICIgIHZhbGlkYXRlOlxuIiwgIiAgcHJvbW90ZTpcbiIpOgogICAgaWYgam9iIG5vdCBpbiByZWJhc2U6CiAgICAgICAgcmFpc2UgU3lzdGVtRXhpdChmIm92ZXJsYXkgcHJvbW90aW9uIHdvcmtmbG93IGlzIG1pc3Npbmcge2pvYi5zdHJpcCgpfSIpCgpwcmVwYXJlX3N0YXJ0ID0gcmViYXNlLmluZGV4KCIgIHByZXBhcmU6XG4iKQp2YWxpZGF0ZV9zdGFydCA9IHJlYmFzZS5pbmRleCgiICB2YWxpZGF0ZTpcbiIpCnByb21vdGVfc3RhcnQgPSByZWJhc2UuaW5kZXgoIiAgcHJvbW90ZTpcbiIpCmlmIG5vdCBwcmVwYXJlX3N0YXJ0IDwgdmFsaWRhdGVfc3RhcnQgPCBwcm9tb3RlX3N0YXJ0OgogICAgcmFpc2UgU3lzdGVtRXhpdCgib3ZlcmxheSBwcm9tb3Rpb24gam9icyBhcmUgbm90IG9yZGVyZWQgcHJlcGFyZSwgdmFsaWRhdGUsIHByb21vdGUiKQoKcHJlcGFyZSA9IHJlYmFzZVtwcmVwYXJlX3N0YXJ0OnZhbGlkYXRlX3N0YXJ0XQp2YWxpZGF0ZV9qb2IgPSByZWJhc2VbdmFsaWRhdGVfc3RhcnQ6cHJvbW90ZV9zdGFydF0KcHJvbW90ZSA9IHJlYmFzZVtwcm9tb3RlX3N0YXJ0Ol0KCnJlcXVpcmVkX3ByZXBhcmUgPSBbCiAgICAiaWY6IGdpdGh1Yi5yZXBvc2l0b3J5ID09ICd3YW5nemhlbmcxNTUzNC1ibGlwL2JyZXcnIiwKICAgICJwZXJtaXNzaW9uczpcbiAgICAgIGNvbnRlbnRzOiB3cml0ZSIsCiAgICAicGVyc2lzdC1jcmVkZW50aWFsczogZmFsc2UiLAogICAgImdpdCAtYyBjb3JlLmhvb2tzUGF0aD0vZGV2L251bGwgcmViYXNlIHVwc3RyZWFtL21haW4iLAogICAgImF1dG9tYXRpb24vb3ZlcmxheS1yZWJhc2UtY2FuZGlkYXRlIiwKICAgICJQUkVQQVJFX1RPS0VOOiAke3sgZ2l0aHViLnRva2VuIH19IiwKICAgICItLWZvcmNlLXdpdGgtbGVhc2U9XCIke2NhbmRpZGF0ZV9yZWZ9OiR7Y2FuZGlkYXRlX2JlZm9yZX1cIiIsCl0KcmVxdWlyZWRfdmFsaWRhdGUgPSBbCiAgICAibmVlZHM6IHByZXBhcmUiLAogICAgInBlcm1pc3Npb25zOlxuICAgICAgY29udGVudHM6IHJlYWQiLAogICAgInJlZjogJHt7IG5lZWRzLnByZXBhcmUub3V0cHV0cy5hZnRlciB9fSIsCiAgICAicGVyc2lzdC1jcmVkZW50aWFsczogZmFsc2UiLAogICAgIm92ZXJsYXlfZmluYWxfcmV2aWV3X3JlcHJvZHVjZXIuc2giLAogICAgImJpbi9icmV3IHRlc3RzIC0tbm8tcGFyYWxsZWwiLAogICAgIm92ZXJsYXlfc3R5bGVfZGVsdGFfY2hlY2sucHkgdXBzdHJlYW0vbWFpbiBIRUFEIiwKICAgICJiaW4vYnJldyB0eXBlY2hlY2siLAogICAgIlZlcmlmeSB0aGUgZXhhY3QgdmFsaWRhdGVkIG9iamVjdCBhZnRlciBjYW5kaWRhdGUgZXhlY3V0aW9uIiwKXQpyZXF1aXJlZF9wcm9tb3RlID0gWwogICAgIm5lZWRzOiBbcHJlcGFyZSwgdmFsaWRhdGVdIiwKICAgICJlbnZpcm9ubWVudDogb3ZlcmxheS1wcm9tb3Rpb24iLAogICAgInBlcm1pc3Npb25zOiB7fSIsCiAgICAiT1ZFUkxBWV9QUk9NT1RJT05fVE9LRU46ICR7eyBzZWNyZXRzLk9WRVJMQVlfUFJPTU9USU9OX1RPS0VOIH19IiwKICAgICJHSVRfQ09ORklHX05PU1lTVEVNPTEiLAogICAgIkdJVF9DT05GSUdfR0xPQkFMPS9kZXYvbnVsbCIsCiAgICAiY29yZS5ob29rc1BhdGggL2Rldi9udWxsIiwKICAgICJyZWZzL3JlbW90ZXMvb3JpZ2luL2NhbmRpZGF0ZSIsCiAgICAiLS1mb3JjZS13aXRoLWxlYXNlPXJlZnMvaGVhZHMvb3ZlcmxheS1zdG9yZToiLAogICAgIiR7QUZURVJ9OnJlZnMvaGVhZHMvb3ZlcmxheS1zdG9yZSIsCl0KZm9yIHNlY3Rpb24sIHJlcXVpcmVkIGluICgKICAgIChwcmVwYXJlLCByZXF1aXJlZF9wcmVwYXJlKSwKICAgICh2YWxpZGF0ZV9qb2IsIHJlcXVpcmVkX3ZhbGlkYXRlKSwKICAgIChwcm9tb3RlLCByZXF1aXJlZF9wcm9tb3RlKSwKKToKICAgIG1pc3NpbmcgPSBbZnJhZ21lbnQgZm9yIGZyYWdtZW50IGluIHJlcXVpcmVkIGlmIGZyYWdtZW50IG5vdCBpbiBzZWN0aW9uXQogICAgaWYgbWlzc2luZzoKICAgICAgICByYWlzZSBTeXN0ZW1FeGl0KGYib3ZlcmxheSBwcm9tb3Rpb24gZ2F0ZSBpcyBpbmNvbXBsZXRlOiB7bWlzc2luZ30iKQoKaWYgIk9WRVJMQVlfUFJPTU9USU9OX1RPS0VOIiBpbiByZWJhc2VbOnByb21vdGVfc3RhcnRdOgogICAgcmFpc2UgU3lzdGVtRXhpdCgicHJvbW90aW9uIGNyZWRlbnRpYWwgaXMgZXhwb3NlZCBiZWZvcmUgdGhlIGZyZXNoIHByb21vdGlvbiBydW5uZXIiKQppZiAiYWN0aW9ucy9jaGVja291dCIgaW4gcHJvbW90ZToKICAgIHJhaXNlIFN5c3RlbUV4aXQoInByb21vdGlvbiBqb2IgbXVzdCBub3QgY2hlY2sgb3V0IG9yIGV4ZWN1dGUgY2FuZGlkYXRlIGZpbGVzIikKaWYgInVzZXM6IGFjdGlvbnMvY2hlY2tvdXRAdiIgaW4gcmViYXNlIG9yICJ1c2VzOiBhY3Rpb25zL2NoZWNrb3V0QHYiIGluIHZhbGlkYXRpb246CiAgICByYWlzZSBTeXN0ZW1FeGl0KCJvdmVybGF5IHdvcmtmbG93cyBtdXN0IHBpbiBhY3Rpb25zL2NoZWNrb3V0IGJ5IGltbXV0YWJsZSBjb21taXQgU0hBIikKaWYgInB1bGxfcmVxdWVzdDoiIG5vdCBpbiB2YWxpZGF0aW9uIG9yICIgICAgICAtIG92ZXJsYXktc3RvcmUiIG5vdCBpbiB2YWxpZGF0aW9uOgogICAgcmFpc2UgU3lzdGVtRXhpdCgib3ZlcmxheSB2YWxpZGF0aW9uIGlzIG5vdCBlbmFibGVkIGZvciBvdmVybGF5LXN0b3JlIHB1bGwgcmVxdWVzdHMiKQppZiAiICAgIHBhdGhzOiIgaW4gdmFsaWRhdGlvbiBvciAiICAgIHBhdGhzLWlnbm9yZToiIGluIHZhbGlkYXRpb246CiAgICByYWlzZSBTeXN0ZW1FeGl0KCJzZWN1cml0eS1zZW5zaXRpdmUgb3ZlcmxheSBQUiB2YWxpZGF0aW9uIG11c3Qgbm90IGJlIHBhdGgtZmlsdGVyZWQiKQppZiAicGVyc2lzdC1jcmVkZW50aWFsczogZmFsc2UiIG5vdCBpbiB2YWxpZGF0aW9uOgogICAgcmFpc2UgU3lzdGVtRXhpdCgib3ZlcmxheSB2YWxpZGF0aW9uIGNoZWNrb3V0IHBlcnNpc3RzIGNyZWRlbnRpYWxzIikKUFkKCnByaW50ZiAnb3ZlcmxheSByZWJhc2Ugd29ya2Zsb3cgdGVzdDogUEFTU1xuJwo=",
        "docs/Overlay-Promotion-Credentials.md": "IyBPdmVybGF5IFByb21vdGlvbiBDcmVkZW50aWFscwoKVGhlIHNjaGVkdWxlZCBvdmVybGF5IHJlYmFzZSBzZXBhcmF0ZXMgcHJlcGFyYXRpb24sIGNhbmRpZGF0ZSBleGVjdXRpb24sIGFuZCBwcm9tb3Rpb24gYWNyb3NzIHRocmVlIEdpdEh1Yi1ob3N0ZWQgam9icy4KCjEuICoqUHJlcGFyZSoqIHJlYmFzZXMgYG92ZXJsYXktc3RvcmVgIHdpdGhvdXQgZXhlY3V0aW5nIHJlcG9zaXRvcnkgY29kZSBhbmQgcHVibGlzaGVzIHRoZSBleGFjdCByZXN1bHQgdG8gYGF1dG9tYXRpb24vb3ZlcmxheS1yZWJhc2UtY2FuZGlkYXRlYCB3aXRoIHRoZSByZXBvc2l0b3J5LXNjb3BlZCBgR0lUSFVCX1RPS0VOYC4KMi4gKipWYWxpZGF0ZSoqIGNoZWNrcyBvdXQgdGhhdCBleGFjdCBTSEEgb24gYSBmcmVzaCwgcmVhZC1vbmx5IHJ1bm5lciB3aXRoIHBlcnNpc3RlZCBjaGVja291dCBjcmVkZW50aWFscyBkaXNhYmxlZCwgdGhlbiBydW5zIHRoZSByZWNvdmVyeSBtYXRyaXgsIHRoZSBmdWxsIFJTcGVjIHN1aXRlLCBjaGFuZ2VkLWxpbmUgc3R5bGUgdmFsaWRhdGlvbiwgYW5kIFNvcmJldC4KMy4gKipQcm9tb3RlKiogc3RhcnRzIG9uIGFub3RoZXIgZnJlc2ggcnVubmVyLCBpcyBnYXRlZCBieSB0aGUgYG92ZXJsYXktcHJvbW90aW9uYCBlbnZpcm9ubWVudCwgbmV2ZXIgY2hlY2tzIG91dCBvciBleGVjdXRlcyBjYW5kaWRhdGUgZmlsZXMsIGZldGNoZXMgdGhlIGV4YWN0IHZhbGlkYXRlZCBjb21taXQgaW50byBhbiBlbXB0eSByZXBvc2l0b3J5IHdpdGggaXNvbGF0ZWQgR2l0IGNvbmZpZ3VyYXRpb24sIHZlcmlmaWVzIGl0cyBjb21taXQgYW5kIHRyZWUgaGFzaGVzLCBhbmQgdXBkYXRlcyBgb3ZlcmxheS1zdG9yZWAgd2l0aCBhbiBleHBsaWNpdCBmb3JjZS13aXRoLWxlYXNlLgoKUHJvbW90aW9uIHJlcXVpcmVzIGFuIGVudmlyb25tZW50IHNlY3JldCBuYW1lZCBgT1ZFUkxBWV9QUk9NT1RJT05fVE9LRU5gIGluIGB3YW5nemhlbmcxNTUzNC1ibGlwL2JyZXdgLiBQcmVmZXIgYSBzaG9ydC1saXZlZCBHaXRIdWIgQXBwIGluc3RhbGxhdGlvbiB0b2tlbi4gSWYgYSBmaW5lLWdyYWluZWQgcGVyc29uYWwgYWNjZXNzIHRva2VuIGlzIHVzZWQsIHNjb3BlIGl0IG9ubHkgdG8gdGhhdCByZXBvc2l0b3J5IHdpdGg6CgotICoqQ29udGVudHM6IHdyaXRlKiosIHRvIHVwZGF0ZSBgb3ZlcmxheS1zdG9yZWAuCi0gKipXb3JrZmxvd3M6IHdyaXRlKiosIGJlY2F1c2UgdGhlIHJlYmFzZWQgY29tbWl0IGNhbiBtb2RpZnkgZmlsZXMgdW5kZXIgYC5naXRodWIvd29ya2Zsb3dzYC4KClByb3RlY3QgdGhlIGBvdmVybGF5LXByb21vdGlvbmAgZW52aXJvbm1lbnQgd2l0aCByZXF1aXJlZCByZXZpZXdlcnMgYW5kIHJlc3RyaWN0IHdoaWNoIGJyYW5jaGVzIG1heSBkZXBsb3kgdGhyb3VnaCBpdC4gVGhlIHByb21vdGlvbiBjcmVkZW50aWFsIGlzIGV4cG9zZWQgb25seSBpbnNpZGUgdGhlIGZpbmFsIGpvYi4gUm90YXRlIGl0IGltbWVkaWF0ZWx5IGlmIGFueSBwcmVwYXJhdGlvbiBvciB2YWxpZGF0aW9uIGpvYiBldmVyIHJlY2VpdmVzIGl0Lgo=",
    }
    for path, encoded in files.items():
        Path(path).write_bytes(base64.b64decode(encoded))


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in {"recovery", "workflows"}:
        raise SystemExit("usage: generate_overlay_hardening.py recovery|workflows")
    globals()[sys.argv[1]]()


if __name__ == "__main__":
    main()
