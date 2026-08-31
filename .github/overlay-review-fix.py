from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    text = p.read_text()
    actual = text.count(old)
    if actual != count:
        raise SystemExit(f"{path}: expected {count} occurrence(s), found {actual}: {old!r}")
    p.write_text(text.replace(old, new, count))


replace(
    "Library/Homebrew/formula_installer.rb",
    "        base_generation: T.must(@overlay_base_generation),\n",
    "        base_generation: @overlay_base_generation,\n",
)
replace(
    "Library/Homebrew/formula_pin.rb",
    "    return false unless path.symlink? && path.exist?\n",
    "    return false unless path.symlink?\n"
    "    return false unless path.exist?\n",
)
replace(
    "Library/Homebrew/install.rb",
    "            inherited_link = false\n",
    "            inherited_link = T.let(false, T::Boolean)\n",
)

replace(
    "Library/Homebrew/overlay.rb",
    "    MAX_MANAGED_STATE_BYTES = 64 * 1024 * 1024\n",
    "    MAX_MANAGED_STATE_BYTES = T.let(64 * 1024 * 1024, Integer)\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "    class ReinstallBackup\n      extend T::Sig\n\n",
    "    class ReinstallBackup\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "        unless Overlay.local_keg_realization?(@formula_name, @version) &&\n"
    "               keg_path.stat.uid == Process.uid\n"
    "          raise TransactionFailure, \"refusing to back up a non-local overlay keg: #{keg_path}\"\n"
    "        end\n",
    "        safe_keg = Overlay.local_keg_realization?(@formula_name, @version) &&\n"
    "                   keg_path.stat.uid == Process.uid\n"
    "        raise TransactionFailure, \"refusing to back up a non-local overlay keg: #{keg_path}\" unless safe_keg\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "      rescue Exception # rubocop:disable Lint/RescueException\n",
    "      # Rescue Exception intentionally so recovery runs before non-StandardError interrupts are re-raised.\n"
    "      rescue Exception # rubocop:disable Lint/RescueException\n",
    count=1,
)
replace(
    "Library/Homebrew/overlay.rb",
    "          unless @final_version.readlink == expected\n"
    "            raise TransactionFailure, \"refusing to replace an unexpected overlay reinstall target: #{@final_version}\"\n"
    "          end\n"
    "          @final_version.unlink\n",
    "          if @final_version.readlink != expected\n"
    "            raise TransactionFailure, \"refusing to replace an unexpected overlay reinstall target: #{@final_version}\"\n"
    "          end\n\n"
    "          @final_version.unlink\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "          unless @final_version.directory? && @final_version.stat.uid == Process.uid\n"
    "            raise TransactionFailure, \"refusing to replace an unsafe overlay reinstall target: #{@final_version}\"\n"
    "          end\n"
    "          Overlay.remove_links_to!(@final_version)\n",
    "          safe_final_version = @final_version.directory? && @final_version.stat.uid == Process.uid\n"
    "          unless safe_final_version\n"
    "            raise TransactionFailure, \"refusing to replace an unsafe overlay reinstall target: #{@final_version}\"\n"
    "          end\n\n"
    "          Overlay.remove_links_to!(@final_version)\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "        lock = File.open(@owner_lock_path, flags, 0600)\n"
    "        lock.close_on_exec = true\n"
    "        stat = lock.stat\n"
    "        unless stat.file? && stat.uid == Process.uid && stat.nlink == 1 &&\n"
    "               lock.flock(File::LOCK_EX | File::LOCK_NB)\n"
    "          lock.close\n"
    "          raise TransactionFailure, \"could not acquire overlay reinstall owner lock: #{@owner_lock_path}\"\n"
    "        end\n",
    "        # This descriptor is intentionally retained until the reinstall backup is finalized.\n"
    "        # rubocop:disable Style/AutoResourceCleanup, Style/FileOpen\n"
    "        lock = File.open(@owner_lock_path, flags, 0600)\n"
    "        # rubocop:enable Style/AutoResourceCleanup, Style/FileOpen\n"
    "        lock.close_on_exec = true\n"
    "        stat = lock.stat\n"
    "        safe_lock = stat.file? && stat.uid == Process.uid && stat.nlink == 1\n"
    "        unless safe_lock\n"
    "          lock.close\n"
    "          raise TransactionFailure, \"could not acquire overlay reinstall owner lock: #{@owner_lock_path}\"\n"
    "        end\n"
    "        unless lock.flock(File::LOCK_EX | File::LOCK_NB)\n"
    "          lock.close\n"
    "          raise TransactionFailure, \"could not acquire overlay reinstall owner lock: #{@owner_lock_path}\"\n"
    "        end\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "        if lock.nil? || lock.closed? || @owner_lock_path.symlink? || !@owner_lock_path.file?\n"
    "          raise TransactionFailure, \"unsafe overlay reinstall owner lock: #{@owner_lock_path}\"\n"
    "        end\n"
    "        descriptor_stat = lock.stat\n",
    "        if lock.nil? || lock.closed? || @owner_lock_path.symlink? || !@owner_lock_path.file?\n"
    "          raise TransactionFailure, \"unsafe overlay reinstall owner lock: #{@owner_lock_path}\"\n"
    "        end\n\n"
    "        descriptor_stat = lock.stat\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "        unless descriptor_stat.file? && descriptor_stat.uid == Process.uid && descriptor_stat.nlink == 1 &&\n"
    "               path_stat.file? && path_stat.uid == Process.uid && path_stat.nlink == 1 &&\n"
    "               descriptor_stat.dev == path_stat.dev && descriptor_stat.ino == path_stat.ino\n"
    "          raise TransactionFailure, \"changed overlay reinstall owner lock: #{@owner_lock_path}\"\n"
    "        end\n",
    "        safe_lock = descriptor_stat.file? && descriptor_stat.uid == Process.uid && descriptor_stat.nlink == 1 &&\n"
    "                    path_stat.file? && path_stat.uid == Process.uid && path_stat.nlink == 1 &&\n"
    "                    descriptor_stat.dev == path_stat.dev && descriptor_stat.ino == path_stat.ino\n"
    "        raise TransactionFailure, \"changed overlay reinstall owner lock: #{@owner_lock_path}\" unless safe_lock\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "        unless formula == \"#{formula_name}\\n\" && recorded_version == \"#{version}\\n\" &&\n"
    "               [\"prepared\\n\", \"backed-up\\n\"].include?(state)\n"
    "          raise TransactionFailure, \"invalid overlay reinstall metadata: #{@root}\"\n"
    "        end\n"
    "        unless backup_version.directory? && !backup_version.symlink? && backup_version.stat.uid == Process.uid\n"
    "          raise TransactionFailure, \"overlay reinstall backup is unavailable: #{backup_version}\"\n"
    "        end\n",
    "        valid_metadata = formula == \"#{formula_name}\\n\" && recorded_version == \"#{version}\\n\" &&\n"
    "                         [\"prepared\\n\", \"backed-up\\n\"].include?(state)\n"
    "        raise TransactionFailure, \"invalid overlay reinstall metadata: #{@root}\" unless valid_metadata\n\n"
    "        safe_backup = backup_version.directory? && !backup_version.symlink? && backup_version.stat.uid == Process.uid\n"
    "        raise TransactionFailure, \"overlay reinstall backup is unavailable: #{backup_version}\" unless safe_backup\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "          unless @final_rack.readlink == expected_base_rack\n"
    "            raise TransactionFailure, \"refusing to replace a non-inherited formula rack: #{@final_rack}\"\n"
    "          end\n"
    "          @final_rack.unlink\n",
    "          if @final_rack.readlink != expected_base_rack\n"
    "            raise TransactionFailure, \"refusing to replace a non-inherited formula rack: #{@final_rack}\"\n"
    "          end\n\n"
    "          @final_rack.unlink\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "        return unless @root.exist? || @root.symlink?\n\n"
    "        parent = @root.parent\n"
    "        unless @root.directory? && !@root.symlink? && @root.stat.uid == Process.uid\n"
    "          raise TransactionFailure, \"unsafe overlay reinstall control path: #{@root}\"\n"
    "        end\n"
    "        FileUtils.rm_rf(@root)\n"
    "        if @root.exist? || @root.symlink?\n"
    "          raise TransactionFailure, \"could not remove overlay reinstall control path: #{@root}\"\n"
    "        end\n"
    "        Overlay.fsync_directory!(parent)\n",
    "        managed_root = @root.exist? || @root.symlink?\n"
    "        return unless managed_root\n\n"
    "        parent = @root.parent\n"
    "        safe_root = @root.directory? && !@root.symlink? && @root.stat.uid == Process.uid\n"
    "        raise TransactionFailure, \"unsafe overlay reinstall control path: #{@root}\" unless safe_root\n\n"
    "        FileUtils.rm_rf(@root)\n"
    "        if @root.exist? || @root.symlink?\n"
    "          raise TransactionFailure, \"could not remove overlay reinstall control path: #{@root}\"\n"
    "        end\n\n"
    "        Overlay.fsync_directory!(parent)\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "    def self.inherited_install_target?(formula_name, version)\n"
    "      return false unless active? && valid_formula_name?(formula_name) && valid_version_name?(version)\n\n"
    "      rack = HOMEBREW_CELLAR/formula_name\n"
    "      keg = rack/version\n"
    "      rack.directory? && !rack.symlink? && keg.symlink? && inherited_keg?(keg)\n"
    "    end\n",
    "    def self.inherited_install_target?(formula_name, version)\n"
    "      return false unless active?\n"
    "      return false unless valid_formula_name?(formula_name)\n"
    "      return false unless valid_version_name?(version)\n\n"
    "      rack = HOMEBREW_CELLAR/formula_name\n"
    "      keg = rack/version\n"
    "      return false unless rack.directory?\n"
    "      return false if rack.symlink?\n"
    "      return false unless keg.symlink?\n\n"
    "      inherited_keg?(keg)\n"
    "    end\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "      prefix_stat = prefix.lstat\n"
    "      unless prefix_stat.directory? && !prefix.symlink?\n"
    "        raise TransactionFailure, \"unsafe administrator Homebrew prefix: #{prefix}\"\n"
    "      end\n\n"
    "      flags = File::RDONLY | File::NOFOLLOW\n"
    "      lease = File.open(lock_path, flags)\n",
    "      prefix_stat = prefix.lstat\n"
    "      safe_prefix = prefix_stat.directory? && !prefix.symlink?\n"
    "      raise TransactionFailure, \"unsafe administrator Homebrew prefix: #{prefix}\" unless safe_prefix\n\n"
    "      flags = File::RDONLY | File::NOFOLLOW\n"
    "      # This descriptor is intentionally returned so the caller can hold the shared lease through the build.\n"
    "      # rubocop:disable Style/AutoResourceCleanup, Style/FileOpen\n"
    "      lease = File.open(lock_path, flags)\n"
    "      # rubocop:enable Style/AutoResourceCleanup, Style/FileOpen\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "                  (descriptor_stat.mode & 0022).zero? && path_stat.file? && path_stat.uid == prefix_stat.uid &&\n",
    "                  descriptor_stat.mode.nobits?(0022) && path_stat.file? && path_stat.uid == prefix_stat.uid &&\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "      raise TransactionFailure, \"administrator Homebrew mutation lock changed while acquiring it: #{lock_path}\" unless stable_lock\n",
    "      unless stable_lock\n"
    "        raise TransactionFailure,\n"
    "              \"administrator Homebrew mutation lock changed while acquiring it: #{lock_path}\"\n"
    "      end\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "        fields = contents.split(\"\\0\", -1)\n"
    "        fields.pop\n"
    "        unless fields.length.even? && fields.none?(&:empty?)\n"
    "          raise TransactionFailure, \"invalid overlay view state: #{state}\"\n"
    "        end\n\n"
    "        fields.each_slice(2) do |relative, target|\n"
    "          expected = expected_link_target(relative)\n",
    "        fields = contents.split(\"\\0\", -1)\n"
    "        fields.pop\n"
    "        valid_fields = fields.length.even? && fields.none?(&:empty?)\n"
    "        raise TransactionFailure, \"invalid overlay view state: #{state}\" unless valid_fields\n\n"
    "        fields.each_slice(2) do |relative, target|\n"
    "          relative = T.must(relative)\n"
    "          target = T.must(target)\n"
    "          expected = expected_link_target(relative)\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "        atomic_exchange!(left, right)\n"
    "        unless [right.stat.dev, right.stat.ino] == left_identity &&\n"
    "               [left.stat.dev, left.stat.ino] == right_identity &&\n"
    "               (left/\"identity\").read == \"right\\n\" && (right/\"identity\").read == \"left\\n\"\n"
    "          raise TransactionFailure, \"atomic overlay exchange probe did not swap Cellar directories exactly\"\n"
    "        end\n\n"
    "        atomic_exchange!(left, right)\n"
    "        unless [left.stat.dev, left.stat.ino] == left_identity &&\n"
    "               [right.stat.dev, right.stat.ino] == right_identity &&\n"
    "               (left/\"identity\").read == \"left\\n\" && (right/\"identity\").read == \"right\\n\"\n"
    "          raise TransactionFailure, \"atomic overlay exchange probe did not restore Cellar directories exactly\"\n"
    "        end\n",
    "        atomic_exchange!(left, right)\n"
    "        swapped_exactly = [right.stat.dev, right.stat.ino] == left_identity &&\n"
    "                          [left.stat.dev, left.stat.ino] == right_identity &&\n"
    "                          (left/\"identity\").read == \"right\\n\" && (right/\"identity\").read == \"left\\n\"\n"
    "        unless swapped_exactly\n"
    "          raise TransactionFailure, \"atomic overlay exchange probe did not swap Cellar directories exactly\"\n"
    "        end\n\n"
    "        atomic_exchange!(left, right)\n"
    "        restored_exactly = [left.stat.dev, left.stat.ino] == left_identity &&\n"
    "                           [right.stat.dev, right.stat.ino] == right_identity &&\n"
    "                           (left/\"identity\").read == \"left\\n\" && (right/\"identity\").read == \"right\\n\"\n"
    "        unless restored_exactly\n"
    "          raise TransactionFailure, \"atomic overlay exchange probe did not restore Cellar directories exactly\"\n"
    "        end\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "        if probe && (probe.exist? || probe.symlink?)\n"
    "          unless probe.directory? && !probe.symlink? && probe.stat.uid == Process.uid\n"
    "            raise TransactionFailure, \"unsafe atomic overlay exchange probe: #{probe}\"\n"
    "          end\n"
    "          FileUtils.rm_rf(probe)\n"
    "          if probe.exist? || probe.symlink?\n"
    "            raise TransactionFailure, \"could not remove atomic overlay exchange probe: #{probe}\"\n"
    "          end\n"
    "          fsync_directory!(parent)\n"
    "        end\n",
    "        if probe && (probe.exist? || probe.symlink?)\n"
    "          safe_probe = probe.directory? && !probe.symlink? && probe.stat.uid == Process.uid\n"
    "          raise TransactionFailure, \"unsafe atomic overlay exchange probe: #{probe}\" unless safe_probe\n\n"
    "          FileUtils.rm_rf(probe)\n"
    "          if probe.exist? || probe.symlink?\n"
    "            raise TransactionFailure, \"could not remove atomic overlay exchange probe: #{probe}\"\n"
    "          end\n\n"
    "          fsync_directory!(parent)\n"
    "        end\n",
)
replace(
    "Library/Homebrew/overlay.rb",
    "    def self.keg_record_target(path)\n"
    "      return unless path.symlink? && path.directory?\n\n",
    "    def self.keg_record_target(path)\n"
    "      return unless path.symlink?\n"
    "      return unless path.directory?\n\n",
)

replace(
    "Library/Homebrew/sorbet/rbi/dsl/homebrew/env_config.rbi",
    "    sig { returns(T::Boolean) }\n"
    "    def no_verify_attestations?; end\n\n"
    "    sig { returns(String) }\n"
    "    def pip_index_url; end\n",
    "    sig { returns(T::Boolean) }\n"
    "    def no_verify_attestations?; end\n\n"
    "    sig { returns(T::Boolean) }\n"
    "    def overlay?; end\n\n"
    "    sig { returns(T::Boolean) }\n"
    "    def overlay_active?; end\n\n"
    "    sig { returns(T.nilable(::String)) }\n"
    "    def overlay_base_prefix; end\n\n"
    "    sig { returns(T::Boolean) }\n"
    "    def overlay_force?; end\n\n"
    "    sig { returns(T.nilable(::String)) }\n"
    "    def overlay_user_prefix; end\n\n"
    "    sig { returns(String) }\n"
    "    def pip_index_url; end\n",
)

replace(
    "Library/Homebrew/test/cmd/overlay-sync_spec.rb",
    "    allow(Homebrew::Overlay).to receive(:active?).and_return(true)\n"
    "    allow(Homebrew::Overlay).to receive(:sync!)\n\n"
    "    described_class.new([]).run\n\n"
    "    expect(Homebrew::Overlay).to have_received(:sync!).once\n",
    "    allow(Homebrew::Overlay).to receive(:active?).and_return(true)\n"
    "    expect(Homebrew::Overlay).to receive(:sync!).once\n\n"
    "    described_class.new([]).run\n",
)
replace(
    "Library/Homebrew/test/cmd/overlay-sync_spec.rb",
    "    allow(Homebrew::Overlay).to receive(:active?).and_return(false)\n"
    "    allow(Homebrew::Overlay).to receive(:sync!)\n\n"
    "    expect { described_class.new([]).run }\n"
    "      .to output(/requires an active per-user Homebrew overlay/).to_stderr\n"
    "    expect(Homebrew).to have_failed\n"
    "    expect(Homebrew::Overlay).not_to have_received(:sync!)\n",
    "    allow(Homebrew::Overlay).to receive(:active?).and_return(false)\n"
    "    expect(Homebrew::Overlay).not_to receive(:sync!)\n\n"
    "    expect { described_class.new([]).run }\n"
    "      .to output(/requires an active per-user Homebrew overlay/).to_stderr\n"
    "    expect(Homebrew).to have_failed\n",
)
replace(
    "Library/Homebrew/test/formula_installer_spec.rb",
    "        active?:                       true,\n"
    "        acquire_base_mutation_lease:   base_lease,\n"
    "        begin_formula_transaction:     nil,\n"
    "        current_base_generation:       generation,\n"
    "        local_keg_realization?:        false,\n"
    "        validate_local_install_target!: nil,\n",
    "        active?:                        true,\n"
    "        acquire_base_mutation_lease:    base_lease,\n"
    "        begin_formula_transaction:      nil,\n"
    "        current_base_generation:        generation,\n"
    "        local_keg_realization?:         false,\n"
    "        validate_local_install_target!: nil,\n",
)
replace(
    "Library/Homebrew/test/overlay_spec.rb",
    "# typed: strict\n",
    "# typed: true\n",
)
replace(
    "Library/Homebrew/test/overlay_spec.rb",
    "  it \"rejects a transaction marker path replaced after opening\" do\n"
    "    add_base_formula(\"foo\", \"1.0\")\n",
    "  it \"rejects a transaction marker path replaced after opening\" do\n"
    "    transaction = T.let(nil, T.nilable(Homebrew::Overlay::FormulaTransaction))\n"
    "    marker = T.let(nil, T.nilable(Pathname))\n"
    "    opened_marker = T.let(nil, T.nilable(Pathname))\n\n"
    "    add_base_formula(\"foo\", \"1.0\")\n",
)
replace(
    "Library/Homebrew/test/overlay_spec.rb",
    "    opened_marker&.rename(marker) if opened_marker&.exist?\n",
    "    opened_marker&.rename(T.must(marker)) if opened_marker&.exist?\n",
)
replace(
    "Library/Homebrew/test/overlay_spec.rb",
    "    descriptor = described_class::MUTATION_LOCK_DESCRIPTOR\n",
    "    descriptor = Homebrew::Overlay::MUTATION_LOCK_DESCRIPTOR\n",
)

replace(
    "Library/Homebrew/test/support/overlay_rebase_workflow_test.sh",
    "python3 - \\\n  \"${repo}/.github/workflows/rebase-upstream-overlay.yml\" \\\n  \"${repo}/.github/workflows/overlay-validation.yml\" <<'PY'\n",
    "workflow_files=(\n"
    "  \"${repo}/.github/workflows/rebase-upstream-overlay.yml\"\n"
    "  \"${repo}/.github/workflows/overlay-validation.yml\"\n"
    ")\n"
    "python3 - \"${workflow_files[@]}\" <<'PY'\n",
)
replace(
    "Library/Homebrew/test/support/overlay_rebase_workflow_test.sh",
    '    "bin/brew style",\n',
    '    "overlay_style_delta_check.py",\n',
)
replace(
    "Library/Homebrew/test/support/overlay_removal_partition_test.sh",
    "python3 - \\\n  \"${repo}/Library/Homebrew/uninstall.rb\" \\\n  \"${repo}/Library/Homebrew/cleanup.rb\" \\\n  \"${repo}/Library/Homebrew/utils/autoremove.rb\" \\\n  \"${repo}/Library/Homebrew/keg.rb\" <<'PY'\n",
    "source_files=(\n"
    "  \"${repo}/Library/Homebrew/uninstall.rb\"\n"
    "  \"${repo}/Library/Homebrew/cleanup.rb\"\n"
    "  \"${repo}/Library/Homebrew/utils/autoremove.rb\"\n"
    "  \"${repo}/Library/Homebrew/keg.rb\"\n"
    ")\n"
    "python3 - \"${source_files[@]}\" <<'PY'\n",
)
replace(
    "Library/Homebrew/test/support/overlay_reinstall_recovery_test.sh",
    "# shellcheck source=../../utils/overlay.sh\n"
    "source \"${repo}/Library/Homebrew/utils/overlay.sh\"\n",
    "# The repository root is resolved at runtime, so ShellCheck cannot follow this source statically.\n"
    "# shellcheck disable=SC1091\n"
    "source \"${repo}/Library/Homebrew/utils/overlay.sh\"\n",
)

style_delta = r'''#!/usr/bin/env python3
import collections
import re
import subprocess
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: overlay_style_delta_check.py BASE HEAD")
base, head = sys.argv[1:]
comparison = f"{base}...{head}"
filters = ["*.rb", "*.rbi", "*.sh", "*.yml", "*.yaml", "bin/brew"]
changed = subprocess.check_output(
    ["git", "diff", "--name-only", "--diff-filter=ACMR", comparison, "--", *filters],
    text=True,
).splitlines()
if not changed:
    print("changed-line style gate: PASS (no style-relevant files)")
    raise SystemExit(0)

patch = subprocess.check_output(
    ["git", "diff", "--unified=0", "--no-color", comparison, "--", *changed],
    text=True,
)
style = subprocess.run(
    ["bin/brew", "style", "--display-cop-names", *changed],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    check=False,
)

ranges = collections.defaultdict(list)
current = None
hunk = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
for line in patch.splitlines():
    if line.startswith("+++ b/"):
        current = line[6:]
    elif current:
        match = hunk.match(line)
        if match:
            start = int(match.group(1))
            count = int(match.group(2) or "1")
            if count:
                ranges[current].append((start, start + count - 1))


def changed_line(path, lineno):
    return any(start <= lineno <= end for start, end in ranges.get(path, ()))


ansi = re.compile(r"\x1b\[[0-9;]*m")
action_error = re.compile(r"^::error file=([^,]+),line=(\d+)(?:,[^:]*)?::(.*)$")
plain = re.compile(r"^([^:]+):(\d+):\d+: [A-Z]: (.*)$")
recognized = set()
changed_errors = set()
for raw in style.stdout.splitlines():
    line = ansi.sub("", raw)
    match = action_error.match(line)
    if match:
        path, lineno, message = match.group(1), int(match.group(2)), match.group(3)
    else:
        match = plain.match(line)
        if not match:
            continue
        path, lineno, message = match.group(1), int(match.group(2)), match.group(3)
        if not path.startswith(("Library/Homebrew/", ".github/", "bin/")):
            path = f"Library/Homebrew/{path}"
    key = (path, lineno, message)
    recognized.add(key)
    if changed_line(path, lineno):
        changed_errors.add(key)

for path, lineno, message in sorted(changed_errors):
    print(f"{path}:{lineno}: {message}")
if changed_errors:
    raise SystemExit(f"style reported {len(changed_errors)} offense(s) on changed lines")
if style.returncode != 0 and not recognized:
    print("\n".join(style.stdout.splitlines()[-80:]))
    raise SystemExit("style failed without locatable diagnostics")
print("changed-line style gate: PASS")
'''
Path("Library/Homebrew/test/support/overlay_style_delta_check.py").write_text(style_delta)

replace(
    ".github/workflows/overlay-validation.yml",
    "  pull_request:\n    paths:\n",
    "  pull_request:\n    branches:\n      - overlay-store\n    paths:\n",
)
replace(
    ".github/workflows/overlay-validation.yml",
    "      - name: Fetch comparison bases\n"
    "        shell: bash\n"
    "        run: |\n"
    "          set -euo pipefail\n"
    "          git remote add upstream https://github.com/Homebrew/brew.git 2>/dev/null ||\n"
    "            git remote set-url upstream https://github.com/Homebrew/brew.git\n"
    "          git fetch --prune upstream main\n"
    "          git branch -f main upstream/main\n",
    "      - name: Fetch overlay-store comparison base\n"
    "        shell: bash\n"
    "        run: |\n"
    "          set -euo pipefail\n"
    "          git fetch --prune origin overlay-store\n",
)
replace(
    ".github/workflows/overlay-validation.yml",
    "          git diff --check upstream/main...HEAD\n",
    "          git diff --check origin/overlay-store...HEAD\n",
)
old_validation_style = '''      - name: Run RuboCop on overlay delta
        shell: bash
        run: |
          set -euo pipefail
          mapfile -t changed < <(
            git diff --name-only --diff-filter=ACMR upstream/main...HEAD -- \
              '*.rb' '*.rbi' '*.sh' '*.yml' '*.yaml' bin/brew
          )
          if ((${#changed[@]} > 0)); then
            bin/brew style "${changed[@]}"
          fi
'''
new_validation_style = '''      - name: Reject style offenses on overlay changes
        shell: bash
        run: |
          set -euo pipefail
          python3 Library/Homebrew/test/support/overlay_style_delta_check.py origin/overlay-store HEAD
'''
replace(".github/workflows/overlay-validation.yml", old_validation_style, new_validation_style)

old_rebase_style = '''      - name: Run RuboCop on the rebased overlay delta
        if: steps.rebase.outputs.changed == 'true'
        shell: bash
        run: |
          set -euo pipefail
          mapfile -t changed < <(
            git diff --name-only --diff-filter=ACMR upstream/main...HEAD -- \
              '*.rb' '*.rbi' '*.sh' '*.yml' '*.yaml' bin/brew
          )
          if ((${#changed[@]} > 0)); then
            bin/brew style "${changed[@]}"
          fi
'''
new_rebase_style = '''      - name: Reject style offenses on the rebased overlay delta
        if: steps.rebase.outputs.changed == 'true'
        shell: bash
        run: |
          set -euo pipefail
          python3 Library/Homebrew/test/support/overlay_style_delta_check.py upstream/main HEAD
'''
replace(".github/workflows/rebase-upstream-overlay.yml", old_rebase_style, new_rebase_style)
replace(
    ".github/workflows/rebase-upstream-overlay.yml",
    "          printf '%s\\n' '#!/bin/sh' \\\n"
    "            'case \"$1\" in *Username*) printf \"%s\\\\n\" x-access-token ;; *) printf \"%s\\\\n\" \"${OVERLAY_PROMOTION_TOKEN:?}\" ;; esac' \\\n"
    "            >\"${askpass}\"\n",
    "          cat >\"${askpass}\" <<'ASKPASS'\n"
    "          #!/bin/sh\n"
    "          case \"$1\" in\n"
    "            *Username*) printf '%s\\n' x-access-token ;;\n"
    "            *) printf '%s\\n' \"${OVERLAY_PROMOTION_TOKEN:?}\" ;;\n"
    "          esac\n"
    "          ASKPASS\n",
)
