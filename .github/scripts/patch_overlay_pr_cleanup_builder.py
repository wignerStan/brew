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
    '''    # The listing is removed only on error or after the read completes.\n'''
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

path.write_text(source, encoding="utf-8")
