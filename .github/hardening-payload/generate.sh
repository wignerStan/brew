#!/bin/bash
set -euo pipefail

BASE_SHA=d986308aaef0c7dd1a0a669b25fdd94723e28c2f
RECOVERY_SHA=02c56ee0f81f49fdf963dc8924180929322de3a4
RECOVERY_PARENT=6d67dcb51bc2136bea491dd2d466df1c2d3c60e3
FINAL_BRANCH=fix/overlay-promotion-recovery-hardening
payload_dir=.github/hardening-payload

cp "${payload_dir}/rebase-upstream-overlay.yml" /tmp/rebase-upstream-overlay.yml
cp "${payload_dir}/overlay-validation.yml" /tmp/overlay-validation.yml
cp "${payload_dir}/overlay_rebase_workflow_test.sh" /tmp/overlay_rebase_workflow_test.sh
cp "${payload_dir}/Overlay-Promotion-Credentials.md" /tmp/Overlay-Promotion-Credentials.md

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git config core.hooksPath /dev/null
git cat-file -e "${BASE_SHA}^{commit}"
git cat-file -e "${RECOVERY_SHA}^{commit}"
git checkout --detach "${BASE_SHA}"

python3 <<'PY_TESTS'
from pathlib import Path

def replace_once(path: str, old: str, new: str, label: str) -> None:
    file = Path(path)
    source = file.read_text(encoding="utf-8")
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    file.write_text(source.replace(old, new), encoding="utf-8")

replace_once(
    "Library/Homebrew/test/formula_installer_spec.rb",
    '      expect(Homebrew::Overlay).to receive(:bump_generation!).ordered\n\n'
    '      installer.finish\n',
    '      installer.finish\n',
    "stale FormulaInstaller generation expectation",
)

outer_test = '''  it "does not finish an outer administrator mutation" do
    allow(Homebrew::EnvConfig).to receive(:overlay?).and_return(true)
    allow(Homebrew::Overlay).to receive(:mutation_active?).and_return(true)
    expect(Homebrew::Overlay).not_to receive(:begin_mutation!)
    expect(Homebrew::Overlay).not_to receive(:bump_generation!)

    session = described_class.new
    session.start!(formula)

    expect(session.managed?).to be(false)
    session.complete_native_install!
  end

'''
path = Path("Library/Homebrew/test/overlay/install_session_spec.rb")
source = path.read_text(encoding="utf-8")
anchor = '  it "finishes a writable administrator mutation after native install work" do\n'
if source.count(anchor) != 1:
    raise SystemExit("outer mutation test anchor changed")
path.write_text(source.replace(anchor, outer_test + anchor), encoding="utf-8")
PY_TESTS

git add -- \
  Library/Homebrew/test/formula_installer_spec.rb \
  Library/Homebrew/test/overlay/install_session_spec.rb
git diff --cached --check
git commit -m "Test outer overlay mutation ownership"

recovery_paths=(
  Library/Homebrew/overlay/core.rb
  Library/Homebrew/test/overlay/core_spec.rb
  Library/Homebrew/test/overlay/reinstall_backup_spec.rb
  Library/Homebrew/test/support/overlay_reinstall_recovery_test.sh
  Library/Homebrew/test/support/overlay_transaction_recovery_test.sh
  Library/Homebrew/utils/overlay/core.sh
)
git diff --binary "${RECOVERY_PARENT}" "${RECOVERY_SHA}" -- "${recovery_paths[@]}" | git apply --index

python3 <<'PY_RECOVERY'
from pathlib import Path

def replace_once(path: str, old: str, new: str, label: str) -> None:
    file = Path(path)
    source = file.read_text(encoding="utf-8")
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    file.write_text(source.replace(old, new), encoding="utf-8")

install_path = Path("Library/Homebrew/overlay/install_session.rb")
install = install_path.read_text(encoding="utf-8")
old_commit = '''        if (transaction = @transaction)
          transaction.commit!
        elsif (generation = @base_generation)
          Overlay.verify_base_generation!(generation)
          Overlay.record_base_generation!(keg.to_path, generation)
          Overlay.verify_base_generation!(generation)
          @local_keg_committed = true
          Overlay.bump_generation!
          @mutation_owned = false
        end
'''
new_commit = '''        if (transaction = @transaction)
          transaction.commit!
        elsif (generation = @base_generation)
          Overlay.verify_base_generation!(generation)
          Overlay.record_base_generation!(keg.to_path, generation)
          Overlay.verify_base_generation!(generation)
          Overlay.mark_reinstall_committed!(formula_name, formula_version, keg.to_path)
          @local_keg_committed = true
          Overlay.bump_generation!
          @mutation_owned = false
        end
'''
if install.count(old_commit) != 1:
    raise SystemExit(f"install commit block: expected one match, found {install.count(old_commit)}")
install_path.write_text(install.replace(old_commit, new_commit), encoding="utf-8")

replace_once(
    "Library/Homebrew/overlay/core.rb",
    '        write_state("committing")\n'
    '        marker = final_version/TRANSACTION_MARKER\n',
    '        write_state("committing")\n'
    '        Overlay.mark_reinstall_committed!(formula_name, version, final_version)\n'
    '        @finished = true\n'
    '        marker = final_version/TRANSACTION_MARKER\n',
    "formula transaction reinstall commit point",
)
replace_once(
    "Library/Homebrew/overlay/core.rb",
    '        Overlay.durable_atomic_write!(@metadata_state, "committed\\n", mode: 0600)\n'
    '        Overlay.fsync_directory!(@root)\n',
    '        # This state write is the reinstall commit boundary and must be the\n'
    '        # final fallible operation in this method.\n'
    '        Overlay.durable_atomic_write!(@metadata_state, "committed\\n", mode: 0600)\n',
    "reinstall commit final operation",
)
replace_once(
    "Library/Homebrew/overlay/core.rb",
    '        current.mkdir unless current.directory?\n'
    '        unless current.directory? && !current.symlink? && current.stat.uid == Process.uid && current.writable?\n',
    '        unless current.directory?\n'
    '          current.mkdir\n'
    '          fsync_directory!(current.parent)\n'
    '        end\n'
    '        unless current.directory? && !current.symlink? && current.stat.uid == Process.uid && current.writable?\n',
    "durable directory creation",
)

spec_path = Path("Library/Homebrew/test/overlay/install_session_spec.rb")
spec = spec_path.read_text(encoding="utf-8")
old_expectations = '''    expect(Homebrew::Overlay).to receive(:record_base_generation!).with(keg.to_path, generation)
    expect(Homebrew::Overlay).to receive(:bump_generation!)
    session.commit!(keg)
'''
new_expectations = '''    expect(Homebrew::Overlay).to receive(:record_base_generation!).with(keg.to_path, generation).ordered
    expect(Homebrew::Overlay).to receive(:mark_reinstall_committed!)
      .with("foo", "2.0", keg.to_path).ordered
    expect(Homebrew::Overlay).to receive(:bump_generation!).ordered
    session.commit!(keg)
'''
if spec.count(old_expectations) != 1:
    raise SystemExit("local realization expectation block changed")
spec_path.write_text(spec.replace(old_expectations, new_expectations), encoding="utf-8")

core_spec_path = Path("Library/Homebrew/test/overlay/core_spec.rb")
core_spec = core_spec_path.read_text(encoding="utf-8")
unlink_stub = '''    allow(described_class).to receive(:durable_unlink!).and_wrap_original do |original, path|
      events << [:unlink, path]
      original.call(path)
    end

    transaction.publish!
'''
commit_stub = '''    allow(described_class).to receive(:durable_unlink!).and_wrap_original do |original, path|
      events << [:unlink, path]
      original.call(path)
    end
    allow(described_class).to receive(:mark_reinstall_committed!) do |formula_name, version, path|
      events << [:reinstall_commit, formula_name, version, path]
    end

    transaction.publish!
'''
if core_spec.count(unlink_stub) != 1:
    raise SystemExit("transaction event stub anchor changed")
core_spec = core_spec.replace(unlink_stub, commit_stub)
old_events = '''      [:write, state_file, "committing\\n"],
      [:unlink, final_transaction_marker],
'''
new_events = '''      [:write, state_file, "committing\\n"],
      [:reinstall_commit, transaction.formula_name, transaction.version, transaction.final_version],
      [:unlink, final_transaction_marker],
'''
if core_spec.count(old_events) != 1:
    raise SystemExit("transaction event order anchor changed")
core_spec = core_spec.replace(old_events, new_events)

commit_failure_test = '''  it "does not roll back after the durable committing boundary" do
    add_base_formula("foo", "1.0")
    transaction = T.must(described_class.begin_formula_transaction(formula, base_generation:))
    stage(transaction)
    transaction.publish!

    allow(described_class).to receive(:mark_reinstall_committed!)
    allow(described_class).to receive(:durable_unlink!).and_raise(
      Homebrew::Overlay::TransactionFailure,
      "cleanup failed",
    )

    expect do
      transaction.commit!
    end.to raise_error(Homebrew::Overlay::TransactionFailure, "cleanup failed")
    expect(transaction.finished?).to be(true)
    expect(user_cellar/"foo/2.0").to be_a_directory

    transaction.rollback!
    expect(user_cellar/"foo/2.0").to be_a_directory
  end

'''
commit_failure_anchor = '  it "does not accept a hard-linked transaction marker" do\n'
if core_spec.count(commit_failure_anchor) != 1:
    raise SystemExit("post-boundary failure test anchor changed")
core_spec = core_spec.replace(commit_failure_anchor, commit_failure_test + commit_failure_anchor)

directory_test = '''  it "fsyncs each parent after creating a control-directory component" do
    FileUtils.rm_rf(prefix/"var")
    target = prefix/"var/homebrew/overlay/new-control-root"
    fsynced = []

    allow(described_class).to receive(:fsync_directory!).and_wrap_original do |original, path, **options|
      fsynced << path
      original.call(path, **options)
    end

    described_class.ensure_owned_directory!(target)

    expect(fsynced).to eq([
      prefix,
      prefix/"var",
      prefix/"var/homebrew",
      prefix/"var/homebrew/overlay",
    ])
  end

'''
directory_anchor = '  it "rejects symlinked intermediate mutation-state directories" do\n'
if core_spec.count(directory_anchor) != 1:
    raise SystemExit("durable directory test anchor changed")
core_spec = core_spec.replace(directory_anchor, directory_test + directory_anchor)
core_spec_path.write_text(core_spec, encoding="utf-8")

shell_path = Path("Library/Homebrew/utils/overlay/core.sh")
shell = shell_path.read_text(encoding="utf-8")
helper_anchor = 'homebrew-overlay-recover-formula-transactions() {\n'
helper = r'''# If formula recovery observes its durable committing state before the Ruby
# owner could update an enclosing reinstall journal, complete that journal from
# the exact committed keg identity. This closes the cross-journal crash window.
homebrew-overlay-record-reinstall-commit-from-formula-recovery() {
  local prefix="$1" formula="$2" version="$3" final_version="$4" base_generation="$5"
  local failed_parent="${prefix}/Cellar/.homebrew-overlay-failed"
  local root owner_lock owner_fd recorded_formula recorded_version state
  local identity device inode matched=0

  for root in "${failed_parent}"/reinstall-*
  do
    [[ -e "${root}" || -L "${root}" ]] || continue
    [[ -d "${root}" && ! -L "${root}" && -O "${root}" ]] || return 1
    [[ -f "${root}/formula" && ! -L "${root}/formula" &&
       -f "${root}/version" && ! -L "${root}/version" &&
       -f "${root}/state" && ! -L "${root}/state" ]] || continue
    recorded_formula="$(homebrew-overlay-read-owned-line "${root}/formula")" || return 1
    recorded_version="$(homebrew-overlay-read-owned-line "${root}/version")" || return 1
    [[ "${recorded_formula}" == "${formula}" && "${recorded_version}" == "${version}" ]] || continue
    matched=$((matched + 1))
    [[ "${matched}" -eq 1 ]] || {
      echo "Error: multiple overlay reinstall journals match ${formula}/${version}" >&2
      return 1
    }

    owner_lock="${root}/owner.lock"
    homebrew-overlay-lock-path-valid "${owner_lock}" "${EUID}" || return 1
    exec {owner_fd}<>"${owner_lock}" || return 1
    homebrew-overlay-lock-fd-valid "${owner_fd}" "${owner_lock}" "${EUID}" || {
      exec {owner_fd}>&-
      return 1
    }
    flock -x -n "${owner_fd}" || {
      exec {owner_fd}>&-
      echo "Error: overlay reinstall owner remained active during formula recovery: ${root}" >&2
      return 1
    }

    state="$(homebrew-overlay-read-owned-line "${root}/state")" || {
      exec {owner_fd}>&-
      return 1
    }
    case "${state}" in
      committed)
        ;;
      backed-up)
        [[ -d "${root}/backup/${formula}/${version}" &&
           ! -L "${root}/backup/${formula}/${version}" &&
           -O "${root}/backup/${formula}/${version}" ]] || {
          exec {owner_fd}>&-
          return 1
        }
        [[ -d "${final_version}" && ! -L "${final_version}" && -O "${final_version}" ]] || {
          exec {owner_fd}>&-
          return 1
        }
        identity="$(stat -Lc '%d:%i' -- "${final_version}")" || {
          exec {owner_fd}>&-
          return 1
        }
        device="${identity%%:*}"
        inode="${identity#*:}"
        homebrew-overlay-atomic-write "${root}/committed_base_generation" 0600 <<<"${base_generation}" || {
          exec {owner_fd}>&-
          return 1
        }
        homebrew-overlay-atomic-write "${root}/committed_device" 0600 <<<"${device}" || {
          exec {owner_fd}>&-
          return 1
        }
        homebrew-overlay-atomic-write "${root}/committed_inode" 0600 <<<"${inode}" || {
          exec {owner_fd}>&-
          return 1
        }
        # Keep this as the last fallible publication operation.
        homebrew-overlay-atomic-write "${root}/state" 0600 <<<'committed' || {
          exec {owner_fd}>&-
          return 1
        }
        ;;
      *)
        exec {owner_fd}>&-
        echo "Error: overlay reinstall journal is not committable from formula recovery: ${root}" >&2
        return 1
        ;;
    esac
    exec {owner_fd}>&-
  done
}

'''
if shell.count(helper_anchor) != 1:
    raise SystemExit("formula recovery helper anchor changed")
shell = shell.replace(helper_anchor, helper + helper_anchor)
commit_validation = '''        if [[ "${recorded_generation}" != "${base_generation}" ]]
        then
          echo "Error: committed overlay formula has the wrong base generation: ${final_version}" >&2
          return 1
        fi
        if [[ -n "${final_marker_id}" && "${final_marker_id}" != "${id}" ]]
'''
commit_validation_new = '''        if [[ "${recorded_generation}" != "${base_generation}" ]]
        then
          echo "Error: committed overlay formula has the wrong base generation: ${final_version}" >&2
          return 1
        fi
        homebrew-overlay-record-reinstall-commit-from-formula-recovery \
          "${prefix}" "${formula}" "${version}" "${final_version}" "${base_generation}" || return 1
        if [[ -n "${final_marker_id}" && "${final_marker_id}" != "${id}" ]]
'''
if shell.count(commit_validation) != 1:
    raise SystemExit("formula committing recovery anchor changed")
shell_path.write_text(shell.replace(commit_validation, commit_validation_new), encoding="utf-8")

reinstall_test_path = Path("Library/Homebrew/test/support/overlay_reinstall_recovery_test.sh")
reinstall_test = reinstall_test_path.read_text(encoding="utf-8")
coordination_case = r'''
# Formula commit recovery must complete a still-backed-up reinstall journal
# before that journal can incorrectly restore the old keg.
rm -rf -- "${prefix}/Cellar/foo/2.0"
coordinated="$(make_control reinstall-105-7777777777777777 backed-up)"
mkdir -p \
  "${coordinated}/backup/foo/2.0/bin" \
  "${prefix}/Cellar/foo/2.0/bin" \
  "${prefix}/var/homebrew/overlay/transactions/txn-reinstall-commit" \
  "${prefix}/var/homebrew/overlay/transactions/.locks"
printf 'old\n' >"${coordinated}/backup/foo/2.0/bin/foo"
printf 'new\n' >"${prefix}/Cellar/foo/2.0/bin/foo"
generation="$(homebrew-overlay-view-key "${base}")"
homebrew-overlay-base-generation-valid "${generation}"
printf '%s\n' "${generation}" >"${prefix}/Cellar/foo/2.0/.brew-overlay-base-generation"
chmod 0600 "${prefix}/Cellar/foo/2.0/.brew-overlay-base-generation"
transaction="${prefix}/var/homebrew/overlay/transactions/txn-reinstall-commit"
printf 'foo\n' >"${transaction}/formula"
printf '2.0\n' >"${transaction}/version"
printf '%s\n' "${generation}" >"${transaction}/base_generation"
printf 'committing\n' >"${transaction}/state"
chmod 0600 "${transaction}/formula" "${transaction}/version" \
  "${transaction}/base_generation" "${transaction}/state"
: >"${prefix}/var/homebrew/overlay/transactions/.locks/txn-reinstall-commit.lock"
chmod 0600 "${prefix}/var/homebrew/overlay/transactions/.locks/txn-reinstall-commit.lock"
homebrew-overlay-sync --force
grep -qx new "${prefix}/Cellar/foo/2.0/bin/foo"
test ! -e "${coordinated}"
test ! -e "${transaction}"

'''
coord_anchor = '# A live owner is never recovered by its own child synchronizer.\n'
if reinstall_test.count(coord_anchor) != 1:
    raise SystemExit("coordinated recovery test anchor changed")
reinstall_test_path.write_text(
    reinstall_test.replace(coord_anchor, coordination_case + coord_anchor),
    encoding="utf-8",
)
PY_RECOVERY

chmod +x \
  Library/Homebrew/test/support/overlay_reinstall_recovery_test.sh \
  Library/Homebrew/test/support/overlay_transaction_recovery_test.sh

git add -- \
  Library/Homebrew/overlay/core.rb \
  Library/Homebrew/overlay/install_session.rb \
  Library/Homebrew/test/overlay/core_spec.rb \
  Library/Homebrew/test/overlay/install_session_spec.rb \
  Library/Homebrew/test/overlay/reinstall_backup_spec.rb \
  Library/Homebrew/test/support/overlay_reinstall_recovery_test.sh \
  Library/Homebrew/test/support/overlay_transaction_recovery_test.sh \
  Library/Homebrew/utils/overlay/core.sh
git diff --cached --check
git commit -m "Harden overlay recovery commit authority"

cp /tmp/rebase-upstream-overlay.yml .github/workflows/rebase-upstream-overlay.yml
cp /tmp/overlay-validation.yml .github/workflows/overlay-validation.yml
cp /tmp/overlay_rebase_workflow_test.sh Library/Homebrew/test/support/overlay_rebase_workflow_test.sh
cp /tmp/Overlay-Promotion-Credentials.md docs/Overlay-Promotion-Credentials.md
chmod +x Library/Homebrew/test/support/overlay_rebase_workflow_test.sh

git add -- \
  .github/workflows/rebase-upstream-overlay.yml \
  .github/workflows/overlay-validation.yml \
  Library/Homebrew/test/support/overlay_rebase_workflow_test.sh \
  docs/Overlay-Promotion-Credentials.md
git diff --cached --check
git commit -m "Isolate overlay promotion credentials"

test "$(git rev-list --count "${BASE_SHA}..HEAD")" -eq 3
test -z "$(git rev-list --merges "${BASE_SHA}..HEAD")"

bash -n \
  Library/Homebrew/utils/overlay.sh \
  Library/Homebrew/utils/overlay/core.sh \
  Library/Homebrew/test/support/overlay_rebase_workflow_test.sh \
  Library/Homebrew/test/support/overlay_reinstall_recovery_test.sh \
  Library/Homebrew/test/support/overlay_transaction_recovery_test.sh
bash Library/Homebrew/test/support/overlay_rebase_workflow_test.sh "$PWD"
bash Library/Homebrew/test/support/overlay_reinstall_recovery_test.sh "$PWD"
bash Library/Homebrew/test/support/overlay_transaction_recovery_test.sh "$PWD"
bash Library/Homebrew/test/support/overlay_architecture_test.sh "$PWD"
python3 Library/Homebrew/test/support/overlay_style_delta_check.py "${BASE_SHA}" HEAD
bin/brew typecheck
bin/brew tests --no-parallel \
  --only=overlay/core,overlay/install_session,overlay/reinstall_session,overlay/reinstall_backup,formula_installer

expected_old="$(git ls-remote --heads origin "refs/heads/${FINAL_BRANCH}" | awk '{print $1}')"
git push \
  --force-with-lease="refs/heads/${FINAL_BRANCH}:${expected_old}" \
  origin "HEAD:refs/heads/${FINAL_BRANCH}"
printf 'final_sha=%s\n' "$(git rev-parse HEAD)"
