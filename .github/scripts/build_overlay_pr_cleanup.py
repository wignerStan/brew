#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return source.replace(old, new)


def replace_all(source: str, old: str, new: str, expected: int, label: str) -> str:
    count = source.count(old)
    if count != expected:
        raise SystemExit(f"{label}: expected {expected} matches, found {count}")
    return source.replace(old, new)


core_path = Path("Library/Homebrew/overlay/core.rb")
core = core_path.read_text(encoding="utf-8")

core = replace_all(
    core,
    "rescue Exception # rubocop:disable Lint/RescueException",
    "rescue Exception # rubocop:disable Lint/RescueException -- cleanup must include Interrupt and SystemExit",
    6,
    "broad cleanup boundaries",
)

core = replace_once(
    core,
    '''        unless staging_version.directory? && !staging_version.symlink? && staging_version.children.any?\n          raise TransactionFailure, "staged formula version is missing or empty: #{staging_version}"\n        end\n''',
    '''        valid_staging_version =\n          staging_version.directory? &&\n          !staging_version.symlink? &&\n          staging_version.children.any?\n        unless valid_staging_version\n          raise TransactionFailure, "staged formula version is missing or empty: #{staging_version}"\n        end\n''',
    "staging-version predicate",
)

core = replace_once(
    core,
    '''        owner_lock = File.open(@owner_lock_path, flags, 0600)\n        @owner_lock = owner_lock\n        owner_lock.close_on_exec = true\n        stat = owner_lock.stat\n        unless stat.file? && stat.uid == Process.uid && stat.nlink == 1\n          raise TransactionFailure, "unsafe overlay transaction owner lock: #{@owner_lock_path}"\n        end\n''',
    '''        owner_lock = Overlay.open_retained_file(@owner_lock_path, flags, mode: 0600)\n        @owner_lock = owner_lock\n        stat = owner_lock.stat\n        safe_lock = stat.file? && stat.uid == Process.uid && stat.nlink == 1\n        unless safe_lock\n          raise TransactionFailure, "unsafe overlay transaction owner lock: #{@owner_lock_path}"\n        end\n''',
    "formula owner-lock acquisition",
)

core = replace_once(
    core,
    '''        unless descriptor_stat.file? && descriptor_stat.uid == Process.uid && descriptor_stat.nlink == 1 &&\n               path_stat.file? && path_stat.uid == Process.uid && path_stat.nlink == 1 &&\n               descriptor_stat.dev == path_stat.dev && descriptor_stat.ino == path_stat.ino\n          raise TransactionFailure, "unsafe overlay transaction owner lock: #{@owner_lock_path}"\n        end\n''',
    '''        safe_lock = descriptor_stat.file? && descriptor_stat.uid == Process.uid && descriptor_stat.nlink == 1 &&\n                    path_stat.file? && path_stat.uid == Process.uid && path_stat.nlink == 1 &&\n                    descriptor_stat.dev == path_stat.dev && descriptor_stat.ino == path_stat.ino\n        unless safe_lock\n          raise TransactionFailure, "unsafe overlay transaction owner lock: #{@owner_lock_path}"\n        end\n''',
    "formula owner-lock identity",
)

core = replace_once(
    core,
    '''          next unless base_version.directory? && !base_version.symlink?\n''',
    '''          real_base_version = base_version.directory? && !base_version.symlink?\n          next unless real_base_version\n''',
    "base-version predicate",
)

core = replace_once(
    core,
    '''          next unless target.to_s == old_prefix || target.to_s.start_with?("#{old_prefix}/")\n''',
    '''          staged_prefix_target = target.to_s == old_prefix || target.to_s.start_with?("#{old_prefix}/")\n          next unless staged_prefix_target\n''',
    "staged-link predicate",
)

core = replace_once(
    core,
    '''        # This descriptor is intentionally retained until the reinstall backup is finalized.\n        # rubocop:disable Style/AutoResourceCleanup, Style/FileOpen\n        lock = File.open(@owner_lock_path, flags, 0600)\n        # rubocop:enable Style/AutoResourceCleanup, Style/FileOpen\n        lock.close_on_exec = true\n''',
    '''        lock = Overlay.open_retained_file(@owner_lock_path, flags, mode: 0600)\n''',
    "reinstall owner-lock acquisition",
)

helper_anchor = '''    sig {\n      params(\n        path:        Pathname,\n        description: String,\n        max_bytes:   Integer,\n      ).returns(T.nilable(String))\n    }\n    def self.read_owned_file(path, description:, max_bytes:)\n'''
helper = '''    sig { params(path: Pathname, flags: Integer, mode: T.nilable(Integer)).returns(File) }\n    def self.open_retained_file(path, flags, mode: nil)\n      retained = T.let(nil, T.nilable(File))\n      completed = false\n      begin\n        retained = if mode.nil?\n          File.open(path, flags) { |file| file.dup }\n        else\n          File.open(path, flags, mode) { |file| file.dup }\n        end\n        descriptor = T.must(retained)\n        descriptor.close_on_exec = true\n        completed = true\n        descriptor\n      ensure\n        retained.close if !completed && retained && !retained.closed?\n      end\n    end\n\n'''
if core.count(helper_anchor) != 1:
    raise SystemExit("retained descriptor helper anchor changed")
core = core.replace(helper_anchor, helper + helper_anchor)

read_start = core.index(helper_anchor)
read_end = core.index("\n    sig { params(path: Pathname).returns(Pathname) }", read_start)
new_reader = '''    sig {\n      params(\n        path:        Pathname,\n        description: String,\n        max_bytes:   Integer,\n      ).returns(T.nilable(String))\n    }\n    def self.read_owned_file(path, description:, max_bytes:)\n      flags = File::RDONLY | File::NOFOLLOW\n      opened = false\n      File.open(path, flags) do |file|\n        opened = true\n        file.binmode\n        descriptor_stat = file.stat\n        path_stat = path.lstat\n        safe_descriptor = descriptor_stat.file? &&\n                          descriptor_stat.uid == Process.uid &&\n                          descriptor_stat.nlink == 1 &&\n                          descriptor_stat.mode.nobits?(0022) &&\n                          descriptor_stat.dev == path_stat.dev &&\n                          descriptor_stat.ino == path_stat.ino\n        raise TransactionFailure, "unsafe #{description}: #{path}" unless safe_descriptor\n        if descriptor_stat.size > max_bytes\n          raise TransactionFailure, "oversized #{description}: #{path}"\n        end\n\n        contents = file.read(max_bytes + 1) || ""\n        final_descriptor_stat = file.stat\n        final_path_stat = path.lstat\n        stable_descriptor = descriptor_stat.dev == final_descriptor_stat.dev &&\n                            descriptor_stat.ino == final_descriptor_stat.ino &&\n                            descriptor_stat.mode == final_descriptor_stat.mode &&\n                            descriptor_stat.uid == final_descriptor_stat.uid &&\n                            descriptor_stat.gid == final_descriptor_stat.gid &&\n                            descriptor_stat.nlink == final_descriptor_stat.nlink &&\n                            descriptor_stat.size == final_descriptor_stat.size &&\n                            descriptor_stat.mtime == final_descriptor_stat.mtime &&\n                            descriptor_stat.ctime == final_descriptor_stat.ctime\n        stable_path = final_descriptor_stat.dev == final_path_stat.dev &&\n                      final_descriptor_stat.ino == final_path_stat.ino &&\n                      final_descriptor_stat.mode == final_path_stat.mode &&\n                      final_descriptor_stat.uid == final_path_stat.uid &&\n                      final_descriptor_stat.nlink == final_path_stat.nlink\n        stable_read = stable_descriptor &&\n                      stable_path &&\n                      contents.bytesize == descriptor_stat.size &&\n                      contents.bytesize <= max_bytes\n        raise TransactionFailure, "changed #{description} while reading: #{path}" unless stable_read\n\n        contents\n      end\n    rescue Errno::ENOENT => e\n      raise TransactionFailure, "unsafe #{description}: #{path} (#{e.message})" if opened\n\n      nil\n    rescue TransactionFailure\n      raise\n    rescue SystemCallError, IOError => e\n      raise TransactionFailure, "unsafe #{description}: #{path} (#{e.message})"\n    end\n'''
core = core[:read_start] + new_reader + core[read_end:]

old_ensure = '''    # Create a private internal directory without following any symlinked\n    # component below the native prefix. Existing ancestors must remain real,\n    # writable directories owned by the current user.\n    sig { params(directory: Pathname).void }\n    def self.ensure_owned_directory!(directory)\n      prefix = HOMEBREW_PREFIX.expand_path\n      directory = directory.expand_path\n      unless prefix.directory? && !prefix.symlink? && prefix.stat.uid == Process.uid && prefix.writable?\n        raise TransactionFailure, "unsafe or non-writable Homebrew overlay prefix: #{prefix}"\n      end\n      unless path_under?(directory, prefix)\n        raise TransactionFailure, "overlay directory escapes the native prefix: #{directory}"\n      end\n\n      relative = directory.relative_path_from(prefix)\n      current = prefix\n      relative.each_filename do |component|\n        if component.empty? || component == "." || component == ".."\n          raise TransactionFailure, "invalid overlay directory component: #{directory}"\n        end\n\n        current /= component\n        if current.symlink? || (current.exist? && !current.directory?)\n          raise TransactionFailure, "unsafe overlay directory component: #{current}"\n        end\n\n        current.mkdir unless current.directory?\n        unless current.directory? && !current.symlink? && current.stat.uid == Process.uid && current.writable?\n          raise TransactionFailure, "unowned or non-writable overlay directory: #{current}"\n        end\n      end\n    rescue ArgumentError\n      raise TransactionFailure, "overlay directory escapes the native prefix: #{directory}"\n    end\n'''
new_ensure = '''    # Create a private internal directory without following any symlinked\n    # component below the native prefix. Every new directory entry is published\n    # by fsyncing its already-validated parent before deeper paths are created.\n    sig { params(directory: Pathname).void }\n    def self.ensure_owned_directory!(directory)\n      prefix = HOMEBREW_PREFIX.expand_path\n      directory = directory.expand_path\n      safe_prefix = prefix.directory? && !prefix.symlink? && prefix.stat.uid == Process.uid && prefix.writable?\n      raise TransactionFailure, "unsafe or non-writable Homebrew overlay prefix: #{prefix}" unless safe_prefix\n      unless path_under?(directory, prefix)\n        raise TransactionFailure, "overlay directory escapes the native prefix: #{directory}"\n      end\n\n      relative = directory.relative_path_from(prefix)\n      current = prefix\n      relative.each_filename do |component|\n        valid_component = !component.empty? && component != "." && component != ".."\n        raise TransactionFailure, "invalid overlay directory component: #{directory}" unless valid_component\n\n        parent = current\n        current /= component\n        if current.symlink? || (current.exist? && !current.directory?)\n          raise TransactionFailure, "unsafe overlay directory component: #{current}"\n        end\n\n        unless current.directory?\n          parent_stat = parent.lstat\n          safe_parent = parent_stat.directory? && !parent.symlink? &&\n                        parent_stat.uid == Process.uid && parent.writable?\n          raise TransactionFailure, "unsafe overlay directory parent: #{parent}" unless safe_parent\n\n          current.mkdir\n          fsync_directory!(parent, expected_device: parent_stat.dev, expected_inode: parent_stat.ino)\n        end\n        safe_directory = current.directory? && !current.symlink? &&\n                         current.stat.uid == Process.uid && current.writable?\n        unless safe_directory\n          raise TransactionFailure, "unowned or non-writable overlay directory: #{current}"\n        end\n      end\n    rescue ArgumentError\n      raise TransactionFailure, "overlay directory escapes the native prefix: #{directory}"\n    end\n'''
core = replace_once(core, old_ensure, new_ensure, "durable owned-directory creation")

core = replace_once(
    core,
    '''        unless file.stat.nlink.zero? && !path.exist? && !path.symlink?\n          raise TransactionFailure, "changed overlay durability file while removing: #{path}"\n        end\n''',
    '''        removed = file.stat.nlink.zero? && !path.exist? && !path.symlink?\n        unless removed\n          raise TransactionFailure, "changed overlay durability file while removing: #{path}"\n        end\n''',
    "durable unlink predicate",
)

core = replace_once(
    core,
    '''      unless active? && path.directory? && !path.symlink? &&\n             rack.directory? && !rack.symlink? && rack.parent.expand_path == HOMEBREW_CELLAR.expand_path &&\n             valid_formula_name?(rack.basename.to_s) && valid_version_name?(path.basename.to_s) &&\n             path.stat.uid == Process.uid\n        raise TransactionFailure, "refusing to record a base generation outside a local keg: #{path}"\n      end\n''',
    '''      local_keg = active? && path.directory? && !path.symlink? &&\n                  rack.directory? && !rack.symlink? && rack.parent.expand_path == HOMEBREW_CELLAR.expand_path &&\n                  valid_formula_name?(rack.basename.to_s) && valid_version_name?(path.basename.to_s) &&\n                  path.stat.uid == Process.uid\n      unless local_keg\n        raise TransactionFailure, "refusing to record a base generation outside a local keg: #{path}"\n      end\n''',
    "local-keg generation predicate",
)

core = replace_once(
    core,
    '''      components = relative.split("/", -1)\n      case components\n      in ["Cellar", formula]\n        return unless valid_formula_name?(formula)\n      in ["Cellar", formula, version]\n        return unless valid_formula_name?(formula) && valid_version_name?(version)\n      in ["opt", formula]\n        return unless valid_formula_name?(formula)\n      in ["var", "homebrew", "linked", formula]\n        return unless valid_formula_name?(formula)\n      else\n        return\n      end\n\n      (base_prefix/relative).to_s\n''',
    '''      components = relative.split("/", -1)\n      formula = if (components.length == 2 && %w[Cellar opt].include?(components.first)) ||\n                   (components.length == 3 && components.first == "Cellar")\n        components[1]\n      elsif components.length == 4 && components.first(3) == %w[var homebrew linked]\n        components[3]\n      end\n      return if formula.nil?\n      return unless valid_formula_name?(formula)\n\n      version = components.length == 3 ? components[2] : nil\n      valid_version = version.nil? || valid_version_name?(version)\n      return unless valid_version\n\n      (base_prefix/relative).to_s\n''',
    "managed link target parser",
)

core = replace_once(
    core,
    '''      # This descriptor is intentionally returned so the caller can hold the shared lease through the build.\n      # rubocop:disable Style/AutoResourceCleanup, Style/FileOpen\n      lease = File.open(lock_path, flags)\n      # rubocop:enable Style/AutoResourceCleanup, Style/FileOpen\n      lease.close_on_exec = true\n''',
    '''      lease = open_retained_file(lock_path, flags)\n''',
    "base mutation lease acquisition",
)

core = replace_once(
    core,
    '''      lock = File.open(lock_path, flags, 0640)\n      lock_stat = lock.stat\n      unless lock_stat.file? && lock_stat.uid == Process.uid && lock_stat.nlink == 1\n        lock.close\n        raise TransactionFailure, "unsafe overlay mutation lock: #{lock_path}"\n      end\n      lock.chmod 0640\n      lock.close_on_exec = true\n''',
    '''      lock = open_retained_file(lock_path, flags, mode: 0640)\n      lock_stat = lock.stat\n      safe_lock = lock_stat.file? && lock_stat.uid == Process.uid && lock_stat.nlink == 1\n      unless safe_lock\n        lock.close\n        raise TransactionFailure, "unsafe overlay mutation lock: #{lock_path}"\n      end\n      lock.chmod 0640\n''',
    "mutation lock acquisition",
)

# Replace one-line compound `unless` guards with an explicitly named positive
# predicate. This preserves the security invariant without introducing a large
# negated expression such as `if !(a && b && c)`.
pattern = re.compile(r"^(?P<indent>\s*)(?P<control>return(?:\s+[^ ]+)?|next) unless (?P<condition>.*(?:&&|\|\|).*)$", re.MULTILINE)

def replace_compound_guard(match: re.Match[str]) -> str:
    indent = match.group("indent")
    return (
        f"{indent}condition_met = {match.group('condition')}\n"
        f"{indent}{match.group('control')} unless condition_met"
    )

core, guard_count = pattern.subn(replace_compound_guard, core)
if guard_count < 8:
    raise SystemExit(f"compound guard normalization matched only {guard_count} locations")

# The remaining multi-line `unless` expressions are converted to named
# predicates while keeping their original positive validation logic.
multiline_replacements = [
    (
        '''        unless stable_descriptor && stable_path && contents.bytesize == descriptor_stat.size &&\n               contents.bytesize <= max_bytes\n          raise TransactionFailure, "changed #{description} while reading: #{path}"\n        end\n''',
        '''        stable_read = stable_descriptor && stable_path && contents.bytesize == descriptor_stat.size &&\n                      contents.bytesize <= max_bytes\n        unless stable_read\n          raise TransactionFailure, "changed #{description} while reading: #{path}"\n        end\n''',
        "stable reader predicate",
    ),
]
for old, new, label in multiline_replacements:
    if old in core:
        core = replace_once(core, old, new, label)

residual_compound_unless = [
    (number, line)
    for number, line in enumerate(core.splitlines(), 1)
    if "unless" in line and ("&&" in line or "||" in line)
]
if residual_compound_unless:
    details = "\n".join(f"{number}: {line}" for number, line in residual_compound_unless)
    raise SystemExit(f"compound unless expressions remain:\n{details}")

core_path.write_text(core, encoding="utf-8")

shell_path = Path("Library/Homebrew/utils/overlay/core.sh")
shell = shell_path.read_text(encoding="utf-8")

shell = replace_once(
    shell,
    '''    "~") printf '%s\\n' "${HOME}" ;;\n    "~/"*) printf '%s/%s\\n' "${HOME}" "${1#\\~/}" ;;\n''',
    '''    "~") printf '%s\\n' "${HOME}" ;;\n    # Match a literal tilde; expansion happens only in the emitted path.\n    # shellcheck disable=SC2088\n    "~/"*) printf '%s/%s\\n' "${HOME}" "${1#\\~/}" ;;\n''',
    "literal tilde expansion",
)

shell = replace_once(
    shell,
    '''  local owner links mode device inode\n\n  [[ -f "${lock_file}" && ! -L "${lock_file}" && -r "${lock_file}" ]] || return 1\n  read -r owner links mode device inode < <(\n    stat -Lc '%u %h %f %d %i' -- "${lock_file}"\n''',
    '''  local owner links mode\n\n  [[ -f "${lock_file}" && ! -L "${lock_file}" && -r "${lock_file}" ]] || return 1\n  read -r owner links mode < <(\n    stat -Lc '%u %h %f' -- "${lock_file}"\n''',
    "lock path metadata",
)

safe_mkdir_pattern = re.compile(
    r"homebrew-overlay-safe-mkdir\(\) \{\n.*?\n\}\n\nhomebrew-overlay-private-temporary\(\)",
    re.DOTALL,
)
safe_mkdir_replacement = '''homebrew-overlay-safe-mkdir() {\n  local prefix directory relative component current parent\n  local -a components=()\n\n  prefix="$(homebrew-overlay-normalize-absolute "$1")" || return 1\n  directory="$(homebrew-overlay-normalize-absolute "$2")" || return 1\n  homebrew-overlay-path-under "${directory}" "${prefix}" || return 1\n  homebrew-overlay-prefix-owned-and-writable "${prefix}" || return 1\n\n  relative="${directory#"${prefix}"}"\n  relative="${relative#/}"\n  [[ -z "${relative}" ]] && return 0\n  homebrew-overlay-valid-relative-path "${relative}" || return 1\n\n  current="${prefix}"\n  IFS=/ read -r -a components <<<"${relative}"\n  for component in "${components[@]}"\n  do\n    parent="${current}"\n    current="${current}/${component}"\n    if [[ -L "${current}" || ( -e "${current}" && ! -d "${current}" ) ]]\n    then\n      return 1\n    fi\n    if [[ ! -d "${current}" ]]\n    then\n      mkdir -- "${current}" || return 1\n      homebrew-overlay-fsync-directory "${parent}" || return 1\n    fi\n    [[ -O "${current}" && -w "${current}" ]] || return 1\n  done\n}\n\nhomebrew-overlay-private-temporary()'''
shell, safe_mkdir_count = safe_mkdir_pattern.subn(safe_mkdir_replacement, shell)
if safe_mkdir_count != 1:
    raise SystemExit(f"safe mkdir replacement matched {safe_mkdir_count} locations")

shell = replace_once(
    shell,
    '''homebrew-overlay-initialize-prefix() {\n  local base_prefix repository prefix brew_link brew_target marker existing_base=""\n  local directory\n''',
    '''homebrew-overlay-initialize-prefix() {\n  local base_prefix repository prefix brew_link brew_target marker existing_base=""\n  local directory\n  local -a overlay_directories=(\n    bin\n    Caskroom\n    Cellar\n    etc/homebrew\n    Frameworks\n    include\n    lib\n    opt\n    sbin\n    share\n    var/homebrew/linked\n    var/homebrew/locks\n    var/homebrew/overlay/transactions\n    var/homebrew/overlay/transactions/.locks\n    var/homebrew/overlay/sync\n  )\n''',
    "overlay directory array",
)

shell = replace_once(
    shell,
    '''  if [[ ! -d "${prefix}" ]]\n  then\n    mkdir -m 0700 -p -- "${prefix}" || return 1\n  fi\n''',
    '''  if [[ ! -d "${prefix}" ]]\n  then\n    mkdir -p -- "${prefix}" || return 1\n    chmod 0700 -- "${prefix}" || return 1\n  fi\n''',
    "prefix creation mode",
)

shell = replace_once(
    shell,
    '''  for directory in \\\n    bin Caskroom Cellar etc/homebrew Frameworks include lib opt sbin share \\\n    var/homebrew/linked var/homebrew/locks var/homebrew/overlay/transactions \\\n    var/homebrew/overlay/transactions/.locks var/homebrew/overlay/sync\n''',
    '''  for directory in "${overlay_directories[@]}"\n''',
    "single-line overlay directory loop",
)

shell = replace_once(
    shell,
    '''homebrew-overlay-state-file() {\n  printf '%s\\n' "${HOMEBREW_PREFIX}/var/homebrew/overlay/view.state"\n}\n''',
    '''homebrew-overlay-state-file() {\n  printf '%s\\n' "${HOMEBREW_PREFIX:?HOMEBREW_PREFIX is required}/var/homebrew/overlay/view.state"\n}\n''',
    "required prefix state path",
)

shell = replace_once(
    shell,
    '''    exec {digest_fd}>&-\n    output_digest="${digest}"\n''',
    '''    exec {digest_fd}>&-\n    # Assigned through a caller-owned nameref; ShellCheck cannot see that use.\n    # shellcheck disable=SC2034\n    output_digest="${digest}"\n''',
    "digest nameref assignment",
)

shell = replace_once(
    shell,
    '''  local link_index\n  local -n output_map="${array_name}"\n''',
    '''  local link_index\n  # The caller supplies an associative array; ShellCheck cannot infer the nameref type.\n  # shellcheck disable=SC2178\n  local -n output_map="${array_name}"\n''',
    "managed view nameref",
)

shell = replace_once(
    shell,
    '''      .homebrew-overlay-staging | .homebrew-overlay-racks | .homebrew-overlay-failed)\n        [[ -d "${entry}" && ! -L "${entry}" && -O "${entry}" ]] || {\n          echo "Error: unsafe overlay Cellar control directory: ${entry}" >&2\n          return 1\n        }\n        continue\n        ;;\n    esac\n''',
    '''      .homebrew-overlay-staging | .homebrew-overlay-racks | .homebrew-overlay-failed)\n        [[ -d "${entry}" && ! -L "${entry}" && -O "${entry}" ]] || {\n          echo "Error: unsafe overlay Cellar control directory: ${entry}" >&2\n          return 1\n        }\n        continue\n        ;;\n      *)\n        ;;\n    esac\n''',
    "Cellar control-directory default branch",
)

shell = replace_all(
    shell,
    '''  (\n    homebrew-overlay-lock-fd-valid 7 "${base_lock}" "${base_owner}" || {\n''',
    '''  # The child validates the same lock path whose descriptor it inherits.\n  # shellcheck disable=SC2094\n  (\n    homebrew-overlay-lock-fd-valid 7 "${base_lock}" "${base_owner}" || {\n''',
    2,
    "base lock descriptor validation",
)

shell = replace_once(
    shell,
    '''    while IFS= read -r -d '' link\n''',
    '''    # The listing is removed only on error or after the read completes.\n    # shellcheck disable=SC2094\n    while IFS= read -r -d '' link\n''',
    "link listing lifecycle",
)

shell = re.sub(
    r"(local [^\n]*?) staging_version([^\n]*\n)",
    r"\1\2",
    shell,
    count=1,
)
shell = replace_once(
    shell,
    '''    staging_version="${staging_root}/${formula}/${version}"\n''',
    "",
    "unused staging version",
)

shell = replace_once(
    shell,
    '''  user_prefix="$(homebrew-overlay-initialize-prefix "${base_prefix}" "${HOMEBREW_REPOSITORY}" "${user_prefix}")" || return 1\n''',
    '''  user_prefix="$(homebrew-overlay-initialize-prefix \\\n    "${base_prefix}" "${HOMEBREW_REPOSITORY:?HOMEBREW_REPOSITORY is required}" "${user_prefix}")" || return 1\n''',
    "required repository path",
)

shell_path.write_text(shell, encoding="utf-8")

checker_path = Path("Library/Homebrew/test/support/overlay_style_delta_check.py")
checker_path.write_text(
    '''#!/usr/bin/env python3\nimport collections\nimport re\nimport subprocess\nimport sys\n\nANSI = re.compile(r"\\x1b\\[[0-9;]*m")\nACTION_ERROR = re.compile(r"^::error file=([^,]+),line=(\\d+)(?:,[^:]*)?::(.*)$")\nPLAIN_ERROR = re.compile(r"^([^:]+):(\\d+):\\d+: [A-Z]: (.*)$")\nFATAL_UNPARSED = re.compile(\n    r"(?:^::error(?::| )|\\b(?:fatal|traceback|exception|syntax error|parser crashed|segmentation fault)\\b)",\n    re.IGNORECASE,\n)\n\n\ndef changed_line(ranges, path, lineno):\n    return any(start <= lineno <= end for start, end in ranges.get(path, ()))\n\n\ndef parse_style_output(output, ranges, returncode):\n    recognized = set()\n    changed_errors = set()\n    unparsed_fatal = []\n    for raw in output.splitlines():\n        line = ANSI.sub("", raw)\n        match = ACTION_ERROR.match(line)\n        if match:\n            path, lineno, message = match.group(1), int(match.group(2)), match.group(3)\n        else:\n            match = PLAIN_ERROR.match(line)\n            if not match:\n                if returncode != 0 and FATAL_UNPARSED.search(line):\n                    unparsed_fatal.append(line)\n                continue\n            path, lineno, message = match.group(1), int(match.group(2)), match.group(3)\n            if not path.startswith(("Library/Homebrew/", ".github/", "bin/")):\n                path = f"Library/Homebrew/{path}"\n        key = (path, lineno, message)\n        recognized.add(key)\n        if changed_line(ranges, path, lineno):\n            changed_errors.add(key)\n    return recognized, changed_errors, unparsed_fatal\n\n\ndef main(argv):\n    if len(argv) != 3:\n        raise SystemExit("usage: overlay_style_delta_check.py BASE HEAD")\n    base, head = argv[1:]\n    comparison = f"{base}...{head}"\n    filters = ["*.rb", "*.rbi", "*.sh", "*.yml", "*.yaml", "bin/brew"]\n    changed = subprocess.check_output(\n        [\n            "git",\n            "diff",\n            "--find-renames",\n            "--find-copies-harder",\n            "--name-only",\n            "--diff-filter=ACMR",\n            comparison,\n            "--",\n            *filters,\n        ],\n        text=True,\n    ).splitlines()\n    if not changed:\n        print("changed-line style gate: PASS (no style-relevant files)")\n        return 0\n\n    patch = subprocess.check_output(\n        [\n            "git",\n            "diff",\n            "--find-renames",\n            "--find-copies-harder",\n            "--unified=0",\n            "--no-color",\n            comparison,\n            "--",\n            *filters,\n        ],\n        text=True,\n    )\n    style = subprocess.run(\n        ["bin/brew", "style", "--display-cop-names", *changed],\n        text=True,\n        stdout=subprocess.PIPE,\n        stderr=subprocess.STDOUT,\n        check=False,\n    )\n\n    ranges = collections.defaultdict(list)\n    current = None\n    hunk = re.compile(r"^@@ -\\d+(?:,\\d+)? \\+(\\d+)(?:,(\\d+))? @@")\n    for line in patch.splitlines():\n        if line.startswith("+++ b/"):\n            current = line[6:]\n        elif current:\n            match = hunk.match(line)\n            if match:\n                start = int(match.group(1))\n                count = int(match.group(2) or "1")\n                if count:\n                    ranges[current].append((start, start + count - 1))\n\n    recognized, changed_errors, unparsed_fatal = parse_style_output(style.stdout, ranges, style.returncode)\n    for path, lineno, message in sorted(changed_errors):\n        print(f"{path}:{lineno}: {message}")\n    if changed_errors:\n        raise SystemExit(f"style reported {len(changed_errors)} offense(s) on changed lines")\n    if unparsed_fatal:\n        print("\\n".join(unparsed_fatal[-40:]))\n        raise SystemExit("style failed with unparsed fatal output")\n    if style.returncode != 0 and not recognized:\n        print("\\n".join(style.stdout.splitlines()[-80:]))\n        raise SystemExit("style failed without locatable diagnostics")\n    print("changed-line style gate: PASS")\n    return 0\n\n\nif __name__ == "__main__":\n    raise SystemExit(main(sys.argv))\n''',
    encoding="utf-8",
)

Path("Library/Homebrew/test/support/overlay_style_delta_check_test.py").write_text(
    '''#!/usr/bin/env python3\nimport unittest\n\nfrom overlay_style_delta_check import parse_style_output\n\n\nclass ParseStyleOutputTest(unittest.TestCase):\n    def test_nonzero_status_with_known_diagnostic_and_fatal_output_fails_closed(self):\n        ranges = {"Library/Homebrew/foo.rb": [(10, 10)]}\n        output = (\n            "Library/Homebrew/foo.rb:4:1: C: existing offense\\n"\n            "fatal: parser crashed while inspecting another file\\n"\n        )\n\n        recognized, changed, fatal = parse_style_output(output, ranges, 2)\n\n        self.assertEqual(len(recognized), 1)\n        self.assertFalse(changed)\n        self.assertEqual(fatal, ["fatal: parser crashed while inspecting another file"])\n\n    def test_located_changed_diagnostic_is_reported_without_false_fatal_output(self):\n        ranges = {"Library/Homebrew/foo.rb": [(10, 10)]}\n        output = "Library/Homebrew/foo.rb:10:1: C: new offense\\n1 file inspected\\n"\n\n        recognized, changed, fatal = parse_style_output(output, ranges, 1)\n\n        self.assertEqual(recognized, changed)\n        self.assertFalse(fatal)\n\n\nif __name__ == "__main__":\n    unittest.main()\n''',
    encoding="utf-8",
)

spec_path = Path("Library/Homebrew/test/overlay/core_spec.rb")
spec = spec_path.read_text(encoding="utf-8")
spec_anchor = '''  it "recognizes a symlinked administrator rack and keg as inherited" do\n'''
spec_test = '''  it "fsyncs each parent after publishing a new owned directory entry" do\n    target = prefix/"durability/first/second"\n    fsynced_parents = T.let([], T::Array[Pathname])\n    allow(described_class).to receive(:fsync_directory!).and_wrap_original do |original, path, **options|\n      fsynced_parents << path\n      original.call(path, **options)\n    end\n\n    described_class.ensure_owned_directory!(target)\n\n    expect(fsynced_parents).to eq([prefix, prefix/"durability", prefix/"durability/first"])\n    expect(target).to be_a_directory\n  end\n\n'''
spec = replace_once(spec, spec_anchor, spec_test + spec_anchor, "directory durability spec")
spec_path.write_text(spec, encoding="utf-8")

shell_test = Path("Library/Homebrew/test/support/overlay_directory_durability_test.sh")
shell_test.write_text(
    '''#!/bin/bash\nset -euo pipefail\n\nrepo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"\nwork="$(mktemp -d)"\ntrap 'rm -rf "${work}"' EXIT\n\n# shellcheck source=Homebrew/utils/overlay/core.sh\nsource "${repo}/Library/Homebrew/utils/overlay/core.sh"\n\nprefix="${work}/prefix"\nmkdir -p -- "${prefix}"\nlog="${work}/fsync.log"\n\nhomebrew-overlay-fsync-directory() {\n  printf '%s\\n' "$1" >>"${log}"\n}\n\nhomebrew-overlay-safe-mkdir "${prefix}" "${prefix}/durability/first/second"\ncat >"${work}/expected" <<EOF\n${prefix}\n${prefix}/durability\n${prefix}/durability/first\nEOF\ncmp -s "${work}/expected" "${log}"\ntest -d "${prefix}/durability/first/second"\n\nprintf 'overlay directory durability test: PASS\\n'\n''',
    encoding="utf-8",
)
shell_test.chmod(0o755)

reproducer_path = Path("Library/Homebrew/test/support/overlay_final_review_reproducer.sh")
reproducer = reproducer_path.read_text(encoding="utf-8")
reproducer_anchor = '''bash "${script_dir}/overlay_architecture_test.sh" "${repo}"\n'''
reproducer_addition = '''bash "${script_dir}/overlay_architecture_test.sh" "${repo}"\nbash "${script_dir}/overlay_directory_durability_test.sh" "${repo}"\npython3 "${script_dir}/overlay_style_delta_check_test.py"\n'''
reproducer = replace_once(
    reproducer,
    reproducer_anchor,
    reproducer_addition,
    "aggregate durability and style-parser tests",
)
reproducer_path.write_text(reproducer, encoding="utf-8")

print("overlay PR cleanup transformation applied")
