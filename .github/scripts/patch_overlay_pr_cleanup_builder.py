#!/usr/bin/env python3
from pathlib import Path

path = Path(".github/scripts/build_overlay_pr_cleanup.py")
source = path.read_text(encoding="utf-8")

compound_anchor = "residual_compound_unless = [\n"
compound_addition = r'''plain_unless_pattern = re.compile(
    r"^(?P<indent>\s*)unless (?P<condition>.*(?:&&|\|\|).*)$",
    re.MULTILINE,
)


def replace_plain_compound_unless(match: re.Match[str]) -> str:
    condition = match.group("condition")
    if condition.rstrip().endswith(("&&", "||")):
        return match.group(0)
    indent = match.group("indent")
    return f"{indent}condition_met = {condition}\n{indent}unless condition_met"


core, plain_unless_count = plain_unless_pattern.subn(replace_plain_compound_unless, core)
if plain_unless_count < 5:
    raise SystemExit(f"plain compound-unless normalization matched only {plain_unless_count} locations")

'''
if source.count(compound_anchor) != 1:
    raise SystemExit("residual compound-unless anchor changed")
source = source.replace(compound_anchor, compound_addition + compound_anchor)

count_anchor = '    2,\n    "base lock descriptor validation",\n'
if source.count(count_anchor) != 1:
    raise SystemExit("base-lock replacement count anchor changed")
source = source.replace(
    count_anchor,
    '    1,\n    "base lock descriptor validation",\n',
)

sync_anchor = r"""shell = replace_once(
    shell,
    '''    while IFS= read -r -d '' link\n''',
"""
sync_insertion = r"""shell = replace_once(
    shell,
    '''  (\n    local mutation_fd="" owner_lock transactions\n''',
    '''  # The synchronizer validates the same base-lock path whose descriptor it inherits.\n  # shellcheck disable=SC2094\n  (\n    local mutation_fd="" owner_lock transactions\n''',
    "synchronizer base lock descriptor validation",
)

"""
if source.count(sync_anchor) != 1:
    raise SystemExit("synchronizer lock insertion anchor changed")
source = source.replace(sync_anchor, sync_insertion + sync_anchor)

old_reproducer = r"""reproducer_path = Path("Library/Homebrew/test/support/overlay_final_review_reproducer.sh")
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
"""
new_reproducer = r"""reproducer_path = Path("Library/Homebrew/test/support/overlay_final_review_reproducer.sh")
reproducer = reproducer_path.read_text(encoding="utf-8")
reproducer = replace_once(
    reproducer,
    "  overlay_architecture_test.sh\n",
    "  overlay_architecture_test.sh\n  overlay_directory_durability_test.sh\n",
    "aggregate directory-durability test registration",
)
reproducer = replace_once(
    reproducer,
    "done\n\nprintf 'complete native overlay audit regression gate: PASS\\n'\n",
    "done\n\npython3 \"${support}/overlay_style_delta_check_test.py\"\n\n"
    "printf 'complete native overlay audit regression gate: PASS\\n'\n",
    "aggregate style-parser regression invocation",
)
reproducer_path.write_text(reproducer, encoding="utf-8")
"""
if source.count(old_reproducer) != 1:
    raise SystemExit("aggregate runner transformation block changed")
source = source.replace(old_reproducer, new_reproducer)

core_write_anchor = 'core_path.write_text(core, encoding="utf-8")\n'
core_finalization = r'''core = re.sub(
    r"^(?P<indent>\s*)rescue Exception # rubocop:disable Lint/RescueException -- cleanup must include Interrupt and SystemExit$",
    lambda match: (
        f"{match.group('indent')}# Cleanup must also restore durable state for Interrupt and SystemExit.\n"
        f"{match.group('indent')}rescue Exception # rubocop:disable Lint/RescueException"
    ),
    core,
    flags=re.MULTILINE,
)
core = replace_once(
    core,
    "      condition_met = active? && valid_formula_name?(formula_name) && "
    "transaction_id.match?(/\\A[1-9][0-9]*-[0-9a-f]{24}\\z/)\n",
    "      condition_met =\n"
    "        active? &&\n"
    "        valid_formula_name?(formula_name) &&\n"
    "        transaction_id.match?(/\\A[1-9][0-9]*-[0-9a-f]{24}\\z/)\n",
    "build transaction identifier line length",
)
core = replace_once(
    core,
    "        condition_met = directory.directory? && !directory.symlink? && "
    "directory.stat.uid == Process.uid && directory.writable?\n",
    "        condition_met =\n"
    "          directory.directory? &&\n"
    "          !directory.symlink? &&\n"
    "          directory.stat.uid == Process.uid &&\n"
    "          directory.writable?\n",
    "staging directory line length",
)
core = replace_once(
    core,
    "        descriptor = T.must(retained)\n",
    "        descriptor = retained\n",
    "retained descriptor type",
)
core = replace_once(
    core,
    "      opened = false\n",
    "      opened = T.let(false, T::Boolean)\n",
    "descriptor reader open-state type",
)
core = replace_once(
    core,
    "        condition_met = rack.directory? && !rack.symlink? && valid_formula_name?(rack.basename.to_s)\n"
    "        next unless condition_met\n",
    "        valid_rack = rack.directory? && !rack.symlink? && valid_formula_name?(rack.basename.to_s)\n"
    "        next unless valid_rack\n",
    "base-generation rack predicate",
)
core = replace_once(
    core,
    "          condition_met = keg.directory? && !keg.symlink? && valid_version_name?(keg.basename.to_s)\n"
    "          next unless condition_met\n",
    "          valid_keg = keg.directory? && !keg.symlink? && valid_version_name?(keg.basename.to_s)\n"
    "          next unless valid_keg\n",
    "base-generation keg predicate",
)
core = replace_once(
    core,
    "      condition_met =\n"
    "        active? &&\n"
    "        valid_formula_name?(formula_name) &&\n"
    "        transaction_id.match?(/\\A[1-9][0-9]*-[0-9a-f]{24}\\z/)\n"
    "      unless condition_met\n",
    "      valid_transaction_id =\n"
    "        active? &&\n"
    "        valid_formula_name?(formula_name) &&\n"
    "        transaction_id.match?(/\\A[1-9][0-9]*-[0-9a-f]{24}\\z/)\n"
    "      unless valid_transaction_id\n",
    "build transaction predicate name",
)
core = replace_once(
    core,
    "        condition_met =\n"
    "          directory.directory? &&\n"
    "          !directory.symlink? &&\n"
    "          directory.stat.uid == Process.uid &&\n"
    "          directory.writable?\n"
    "        unless condition_met\n",
    "        safe_staging_directory =\n"
    "          directory.directory? &&\n"
    "          !directory.symlink? &&\n"
    "          directory.stat.uid == Process.uid &&\n"
    "          directory.writable?\n"
    "        unless safe_staging_directory\n",
    "staging directory predicate name",
)

'''
if source.count(core_write_anchor) != 1:
    raise SystemExit("core write anchor changed")
source = source.replace(core_write_anchor, core_finalization + core_write_anchor)

shell_write_anchor = 'shell_path.write_text(shell, encoding="utf-8")\n'
shell_finalization = r'''shell = replace_once(
    shell,
    "  case \"$1\" in\n"
    "    \"~\") printf '%s\\n' \"${HOME}\" ;;\n"
    "    # Match a literal tilde; expansion happens only in the emitted path.\n"
    "    # shellcheck disable=SC2088\n"
    "    \"~/\"*) printf '%s/%s\\n' \"${HOME}\" \"${1#\\~/}\" ;;\n",
    "  # Match a literal tilde; expansion happens only in the emitted path.\n"
    "  # shellcheck disable=SC2088\n"
    "  case \"$1\" in\n"
    "    \"~\") printf '%s\\n' \"${HOME}\" ;;\n"
    "    \"~/\"*) printf '%s/%s\\n' \"${HOME}\" \"${1#\\~/}\" ;;\n",
    "literal tilde ShellCheck directive placement",
)

'''
if source.count(shell_write_anchor) != 1:
    raise SystemExit("shell write anchor changed")
source = source.replace(shell_write_anchor, shell_finalization + shell_write_anchor)

path.write_text(source, encoding="utf-8")
