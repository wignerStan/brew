#!/usr/bin/env python3
"""Resolve the known Homebrew overlay/upstream semantic conflicts.

This script is intentionally strict: every expected conflict and textual anchor
must match exactly. It aborts rather than guessing when upstream changes again.
"""

from __future__ import annotations

import re
import subprocess
from collections.abc import Callable
from pathlib import Path
from typing import NoReturn

ConflictHandler = Callable[[int, str, str], str]
CONFLICT_RE = re.compile(
    r"^<<<<<<< HEAD\n(.*?)^=======\n(.*?)^>>>>>>> [^\n]+\n",
    re.MULTILINE | re.DOTALL,
)


def fail(message: str) -> NoReturn:
    raise SystemExit(message)


def replace_once(text: str, old: str, new: str, *, label: str) -> str:
    count = text.count(old)
    if count != 1:
        fail(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


def resolve_conflicts(path: str, expected_count: int, handler: ConflictHandler) -> str:
    file_path = Path(path)
    text = file_path.read_text(encoding="utf-8")
    matches = list(CONFLICT_RE.finditer(text))
    if len(matches) != expected_count:
        fail(f"{path}: expected {expected_count} conflicts, found {len(matches)}")

    index = 0

    def replacement(match: re.Match[str]) -> str:
        nonlocal index
        current = index
        index += 1
        return handler(current, match.group(1), match.group(2))

    resolved = CONFLICT_RE.sub(replacement, text)
    if "<<<<<<<" in resolved or "=======" in resolved or ">>>>>>>" in resolved:
        fail(f"{path}: conflict markers remain")
    file_path.write_text(resolved, encoding="utf-8")
    return resolved


def shellenv_contents() -> str:
    return r'''# Documentation defined in Library/Homebrew/cmd/shellenv.rb

# HOMEBREW_CELLAR and HOMEBREW_PREFIX are set by extend/ENV/super.rb
# HOMEBREW_REPOSITORY is set by bin/brew
# Leading colon in MANPATH prepends default man dirs to search path in Linux and macOS.
# Trailing colon in INFOPATH appends the default info dirs to the search path.
# Please do not submit PRs to remove it!
# shellcheck disable=SC2154
homebrew-shellenv() {
  local PATH_HELPER_ROOT="${PATH_HELPER_ROOT:-}"
  local HOMEBREW_PATH="${HOMEBREW_PATH:-${PATH:-}}"
  local HOMEBREW_SHELLENV_PATH_PREFIX="${HOMEBREW_PREFIX}/bin:${HOMEBREW_PREFIX}/sbin"
  local HOMEBREW_SHELLENV_INFO_PREFIX="${HOMEBREW_PREFIX}/share/info"
  local HOMEBREW_SHELLENV_BASE_PREFIX=""
  if [[ -n "${HOMEBREW_OVERLAY_ACTIVE:-}" && -n "${HOMEBREW_OVERLAY_BASE_PREFIX:-}" &&
        "${HOMEBREW_OVERLAY_BASE_PREFIX%/}" != "${HOMEBREW_PREFIX}" ]]
  then
    HOMEBREW_SHELLENV_BASE_PREFIX="${HOMEBREW_OVERLAY_BASE_PREFIX%/}"
    HOMEBREW_SHELLENV_PATH_PREFIX+=":${HOMEBREW_SHELLENV_BASE_PREFIX}/bin:${HOMEBREW_SHELLENV_BASE_PREFIX}/sbin"
    HOMEBREW_SHELLENV_INFO_PREFIX+=":${HOMEBREW_SHELLENV_BASE_PREFIX}/share/info"
  fi

  if [[ "${HOMEBREW_PATH}:" == "${HOMEBREW_SHELLENV_PATH_PREFIX}:"* ]]
  then
    return
  fi

  # Use specified shell name parameter, if available.
  HOMEBREW_SHELL_NAME="${1:-}"

  # Use the parent process name, if possible.
  # This is known to fail under some sandboxes.
  if [[ -z "${HOMEBREW_SHELL_NAME}" ]]
  then
    HOMEBREW_SHELL_NAME="$(/bin/ps -p "${PPID}" -c -o comm= 2>/dev/null)"
  fi

  # Fall back to the (login) shell name from the environment.
  if [[ -z "${HOMEBREW_SHELL_NAME}" ]]
  then
    HOMEBREW_SHELL_NAME="${SHELL##*/}"
  fi

  if [[ -n "${HOMEBREW_MACOS}" ]] &&
     [[ "${HOMEBREW_MACOS_VERSION_NUMERIC}" -ge "140000" ]] &&
     [[ -x /usr/libexec/path_helper ]]
  then
    HOMEBREW_PATHS_FILE="${HOMEBREW_PREFIX}/etc/paths"

    if [[ ! -f "${HOMEBREW_PATHS_FILE}" ]]
    then
      printf '%s/bin\n%s/sbin\n' "${HOMEBREW_PREFIX}" "${HOMEBREW_PREFIX}" 2>/dev/null >"${HOMEBREW_PATHS_FILE}"
    fi

    if [[ -r "${HOMEBREW_PATHS_FILE}" ]]
    then
      PATH_HELPER_ROOT="${HOMEBREW_PREFIX}"
    fi
  fi

  case "${HOMEBREW_SHELL_NAME}" in
    fish | -fish)
      echo "set --global --export HOMEBREW_PREFIX \"${HOMEBREW_PREFIX}\";"
      echo "set --global --export HOMEBREW_CELLAR \"${HOMEBREW_CELLAR}\";"
      echo "set --global --export HOMEBREW_REPOSITORY \"${HOMEBREW_REPOSITORY}\";"
      if [[ -n "${HOMEBREW_SHELLENV_BASE_PREFIX}" ]]
      then
        echo "set --global --export HOMEBREW_OVERLAY_ACTIVE 1;"
        echo "set --global --export HOMEBREW_OVERLAY_BASE_PREFIX \"${HOMEBREW_SHELLENV_BASE_PREFIX}\";"
        echo "fish_add_path --global --move --path \"${HOMEBREW_SHELLENV_BASE_PREFIX}/bin\" \"${HOMEBREW_SHELLENV_BASE_PREFIX}/sbin\";"
      fi
      echo "fish_add_path --global --move --path \"${HOMEBREW_PREFIX}/bin\" \"${HOMEBREW_PREFIX}/sbin\";"
      echo "if test -n \"\$MANPATH\"; set --global --export MANPATH (string replace --regex '^:*(.*?):*\$' ':\$1' -- \"\$MANPATH\"); end;"
      if [[ -n "${HOMEBREW_SHELLENV_BASE_PREFIX}" ]]
      then
        echo "if not set --query INFOPATH; set INFOPATH ''; end;"
        echo "if not contains \"${HOMEBREW_SHELLENV_BASE_PREFIX}/share/info\" \$INFOPATH; set --global --prepend INFOPATH \"${HOMEBREW_SHELLENV_BASE_PREFIX}/share/info\"; end;"
        echo "if not contains \"${HOMEBREW_PREFIX}/share/info\" \$INFOPATH; set --global --prepend INFOPATH \"${HOMEBREW_PREFIX}/share/info\"; end;"
      else
        echo "if not set --query INFOPATH; set INFOPATH ''; end; set --global --export INFOPATH \"${HOMEBREW_PREFIX}/share/info\" \$INFOPATH;"
      fi
      ;;
    csh | -csh | tcsh | -tcsh)
      echo "setenv HOMEBREW_PREFIX ${HOMEBREW_PREFIX};"
      echo "setenv HOMEBREW_CELLAR ${HOMEBREW_CELLAR};"
      echo "setenv HOMEBREW_REPOSITORY ${HOMEBREW_REPOSITORY};"
      if [[ -n "${HOMEBREW_SHELLENV_BASE_PREFIX}" ]]
      then
        echo "setenv HOMEBREW_OVERLAY_ACTIVE 1;"
        echo "setenv HOMEBREW_OVERLAY_BASE_PREFIX ${HOMEBREW_SHELLENV_BASE_PREFIX};"
      fi
      if [[ -n "${PATH_HELPER_ROOT}" && -z "${HOMEBREW_SHELLENV_BASE_PREFIX}" ]]
      then
        echo "eval \`/usr/bin/env PATH_HELPER_ROOT=\"${PATH_HELPER_ROOT}\" /usr/libexec/path_helper -c\`;"
      else
        echo "setenv PATH \"${HOMEBREW_SHELLENV_PATH_PREFIX}:\$PATH\";"
      fi
      echo "test \${?MANPATH} -eq 1 && test -n \"\${MANPATH}\" && setenv MANPATH :\`printf '%s' \"\${MANPATH}\" | /usr/bin/sed -e 's/^:*//' -e 's/:*\$//'\`;"
      echo "test \${?INFOPATH} -eq 1 || setenv INFOPATH '';"
      echo "setenv INFOPATH \"${HOMEBREW_SHELLENV_INFO_PREFIX}:\${INFOPATH}\";"
      ;;
    pwsh | -pwsh | pwsh-preview | -pwsh-preview)
      echo "[System.Environment]::SetEnvironmentVariable('HOMEBREW_PREFIX','${HOMEBREW_PREFIX}',[System.EnvironmentVariableTarget]::Process)"
      echo "[System.Environment]::SetEnvironmentVariable('HOMEBREW_CELLAR','${HOMEBREW_CELLAR}',[System.EnvironmentVariableTarget]::Process)"
      echo "[System.Environment]::SetEnvironmentVariable('HOMEBREW_REPOSITORY','${HOMEBREW_REPOSITORY}',[System.EnvironmentVariableTarget]::Process)"
      if [[ -n "${HOMEBREW_SHELLENV_BASE_PREFIX}" ]]
      then
        echo "[System.Environment]::SetEnvironmentVariable('HOMEBREW_OVERLAY_ACTIVE','1',[System.EnvironmentVariableTarget]::Process)"
        echo "[System.Environment]::SetEnvironmentVariable('HOMEBREW_OVERLAY_BASE_PREFIX','${HOMEBREW_SHELLENV_BASE_PREFIX}',[System.EnvironmentVariableTarget]::Process)"
      fi
      echo "[System.Environment]::SetEnvironmentVariable('PATH',\$('${HOMEBREW_SHELLENV_PATH_PREFIX}:'+\$ENV:PATH),[System.EnvironmentVariableTarget]::Process)"
      echo "if (\${ENV:MANPATH}) { [System.Environment]::SetEnvironmentVariable('MANPATH',(':'+\${ENV:MANPATH}.Trim(':')),[System.EnvironmentVariableTarget]::Process) }"
      echo "[System.Environment]::SetEnvironmentVariable('INFOPATH',('${HOMEBREW_SHELLENV_INFO_PREFIX}:'+\${ENV:INFOPATH}),[System.EnvironmentVariableTarget]::Process)"
      ;;
    *)
      echo "export HOMEBREW_PREFIX=\"${HOMEBREW_PREFIX}\";"
      echo "export HOMEBREW_CELLAR=\"${HOMEBREW_CELLAR}\";"
      echo "export HOMEBREW_REPOSITORY=\"${HOMEBREW_REPOSITORY}\";"
      if [[ -n "${HOMEBREW_SHELLENV_BASE_PREFIX}" ]]
      then
        echo "export HOMEBREW_OVERLAY_ACTIVE=1;"
        echo "export HOMEBREW_OVERLAY_BASE_PREFIX=\"${HOMEBREW_SHELLENV_BASE_PREFIX}\";"
      fi
      if [[ "${HOMEBREW_SHELL_NAME}" == "zsh" ]] || [[ "${HOMEBREW_SHELL_NAME}" == "-zsh" ]]
      then
        echo "fpath[1,0]=\"${HOMEBREW_PREFIX}/share/zsh/site-functions\";"
        if [[ -n "${HOMEBREW_SHELLENV_BASE_PREFIX}" ]]
        then
          echo "fpath[2,0]=\"${HOMEBREW_SHELLENV_BASE_PREFIX}/share/zsh/site-functions\";"
        fi
        echo "export FPATH;"
      fi
      if [[ -n "${PATH_HELPER_ROOT}" && -z "${HOMEBREW_SHELLENV_BASE_PREFIX}" ]]
      then
        echo "eval \"\$(/usr/bin/env PATH_HELPER_ROOT=\"${PATH_HELPER_ROOT}\" /usr/libexec/path_helper -s)\""
      else
        echo "export PATH=\"${HOMEBREW_SHELLENV_PATH_PREFIX}\${PATH+:\$PATH}\";"
      fi
      echo "[ -z \"\${MANPATH-}\" ] || { export MANPATH=\"\${MANPATH%\"\${MANPATH##*[!:]}\"}\"; export MANPATH=\":\${MANPATH#\"\${MANPATH%%[!:]*}\"}\"; };"
      echo "export INFOPATH=\"${HOMEBREW_SHELLENV_INFO_PREFIX}:\${INFOPATH:-}\";"
      ;;
  esac
}
'''


def resolve_shellenv() -> None:
    path = Path("Library/Homebrew/cmd/shellenv.sh")
    if len(list(CONFLICT_RE.finditer(path.read_text(encoding="utf-8")))) != 5:
        fail("shellenv.sh: unexpected conflict structure")
    path.write_text(shellenv_contents(), encoding="utf-8")


def resolve_unlink() -> None:
    path = "Library/Homebrew/cmd/unlink.rb"
    text = resolve_conflicts(path, 1, lambda _i, _ours, _theirs: "")
    text = replace_once(
        text,
        "        kegs = args.named.to_default_kegs\n",
        "        kegs, casks = args.named.to_kegs_to_casks\n",
        label=path,
    )
    Path(path).write_text(text, encoding="utf-8")


def resolve_formula_installer() -> None:
    path = "Library/Homebrew/formula_installer.rb"

    def handler(_index: int, ours: str, theirs: str) -> str:
        if 'require "mktemp"' in ours and 'require "overlay"' in theirs:
            return ours + 'require "overlay"\n'
        if "previously_fetched_formula = self.previously_fetched_formula" in ours and \
           "@overlay_install_session" in theirs:
            return ours + (
                "    @overlay_install_session = T.let(\n"
                "      Homebrew::Overlay::InstallSession.new,\n"
                "      Homebrew::Overlay::InstallSession,\n"
                "    )\n"
            )
        if "unlock" in ours and "@overlay_install_session.abort!" in theirs:
            return (
                "  # Overlay rollback, descriptor release, and Homebrew lock release must\n"
                "  # also cover interrupts and process exits during installation.\n"
                "  rescue Exception # rubocop:disable Lint/RescueException\n"
                "    begin\n"
                "      @overlay_install_session.abort!\n"
                "    ensure\n"
                "      begin\n"
                "        @overlay_install_session.close!\n"
                "      ensure\n"
                "        unlock\n"
                "      end\n"
                "    end\n"
                "    raise\n"
            )
        if "HOMEBREW_BUILD_STAGING_PATH" in ours and \
           "@overlay_install_session.build_environment" in theirs:
            return ours
        if "add_build_sandbox_rules" in ours and \
           "@overlay_install_session.apply_build_sandbox_rules" in theirs:
            return ours
        fail("formula_installer.rb: unrecognized conflict")

    text = resolve_conflicts(path, 5, handler)
    text = replace_once(
        text,
        "    with_env(HOMEBREW_BUILD_STAGING_PATH: staging_path, HOMEBREW_BUILD_FETCH_PHASE: nil) do\n",
        "    with_env(\n"
        "      **@overlay_install_session.build_environment,\n"
        "      HOMEBREW_BUILD_STAGING_PATH: staging_path,\n"
        "      HOMEBREW_BUILD_FETCH_PHASE: nil,\n"
        "    ) do\n",
        label=f"{path} build environment",
    )
    text = replace_once(
        text,
        '        add_build_sandbox_rules(sandbox, formula_path, log_name: "build")\n',
        '        add_build_sandbox_rules(sandbox, formula_path, log_name: "build")\n'
        "        @overlay_install_session.apply_build_sandbox_rules(sandbox)\n",
        label=f"{path} build sandbox",
    )
    text = replace_once(
        text,
        '    with_env(HOMEBREW_BUILD_FETCH_PHASE: "1", HOMEBREW_BUILD_STAGING_PATH: staging_path) do\n',
        "    with_env(\n"
        "      **@overlay_install_session.build_environment,\n"
        '      HOMEBREW_BUILD_FETCH_PHASE: "1",\n'
        "      HOMEBREW_BUILD_STAGING_PATH: staging_path,\n"
        "    ) do\n",
        label=f"{path} fetch environment",
    )
    text = replace_once(
        text,
        '        add_build_sandbox_rules(sandbox, formula_path, log_name: "fetch")\n',
        '        add_build_sandbox_rules(sandbox, formula_path, log_name: "fetch")\n'
        "        @overlay_install_session.apply_build_sandbox_rules(sandbox)\n",
        label=f"{path} fetch sandbox",
    )
    Path(path).write_text(text, encoding="utf-8")


def resolve_formula_pin() -> None:
    resolve_conflicts(
        "Library/Homebrew/formula_pin.rb",
        1,
        lambda _i, ours, _theirs: ours,
    )


def resolve_install() -> None:
    path = "Library/Homebrew/install.rb"

    def handler(_index: int, ours: str, theirs: str) -> str:
        if 'require "install/check"' in ours and 'require "overlay"' in theirs:
            return ours + 'require "overlay"\n'
        if "def install_formula?" in theirs:
            return ours
        fail("install.rb: unrecognized conflict")

    resolve_conflicts(path, 2, handler)

    check_path = "Library/Homebrew/install/check.rb"
    text = Path(check_path).read_text(encoding="utf-8")
    text = replace_once(
        text,
        'require "keg"\n',
        'require "keg"\nrequire "overlay"\n',
        label=f"{check_path} require",
    )
    text = replace_once(
        text,
        "        if formula.any_version_installed? &&\n"
        "           (current_tap_name = formula.tap&.name.presence) &&\n",
        "        if formula.any_version_installed? &&\n"
        "           !(Homebrew::Overlay.active? && Homebrew::Overlay.inherited_only_formula?(formula)) &&\n"
        "           (current_tap_name = formula.tap&.name.presence) &&\n",
        label=f"{check_path} inherited tap check",
    )
    text = replace_once(
        text,
        "        keg = Keg.new(Utils::Path.resolved_path(formula.opt_prefix))\n"
        "        tab = keg.tab\n",
        "        keg = Keg.new(Utils::Path.resolved_path(formula.opt_prefix))\n"
        "        return false if Homebrew::Overlay.inherited_keg?(keg.to_path)\n\n"
        "        tab = keg.tab\n",
        label=f"{check_path} inherited tab check",
    )
    Path(check_path).write_text(text, encoding="utf-8")


def resolve_keg() -> None:
    path = "Library/Homebrew/keg.rb"

    def handler(_index: int, ours: str, theirs: str) -> str:
        if "HOMEBREW_REPOSITORY" in ours and "homebrew_site_packages" in theirs:
            return (
                "      *(Homebrew::Overlay.active? ? [] : [HOMEBREW_REPOSITORY]),\n"
                '      *HOMEBREW_PREFIX.glob("lib/python*/site-packages"),\n'
            )
        if "path = resolved_path(path)" in ours and "keg_record_path" in theirs:
            return theirs
        if "resolved_path(linked_keg_record)" in ours and \
           "keg_record_target(linked_keg_record)" in theirs:
            return theirs
        if "resolved_path(opt_record)" in ours and "keg_record_target(opt_record)" in theirs:
            return theirs
        if "FileUtils.rm_r(path)" in ours and "Remove namespace records" in theirs:
            return theirs
        if "@overwritten_cask_symlinks" in ours and "bump_generation!" in theirs:
            return (
                "  rescue => e\n"
                "    raise if dry_run || e.is_a?(AlreadyLinkedError)\n\n"
                "    unlink(verbose:)\n"
                "    @overwritten_cask_symlinks.each do |dst, (_, source)|\n"
                "      dst.dirname.mkpath\n"
                "      FileUtils.ln_sf(source, dst)\n"
                "    end\n"
                "    Homebrew::Overlay.bump_generation! if owns_overlay_mutation\n"
                "    raise\n"
                "  else\n"
                "    count = ObserverPathnameExtension.n\n"
                "    Homebrew::Overlay.bump_generation! if owns_overlay_mutation\n"
                "    count\n"
                "  ensure\n"
                "    @overwritten_cask_symlinks.clear\n"
                "    @cask_symlink_tokens = nil\n"
            )
        if "def optlink" in ours and "record_mutation" in theirs:
            return theirs + "    remove_old_aliases\n"
        if "src = resolved_path(dst)" in ours and "inherited_prefix_link?" in theirs:
            inherited = theirs.split("    src = dst.resolved_path\n", 1)[0]
            if inherited == theirs:
                fail("keg.rb: inherited conflict source anchor missing")
            return inherited + "    src = resolved_path(dst)\n"
        if "src == resolved_path(dst)" in ours and \
           "remove_inherited_prefix_link!" in theirs:
            return (
                "    Homebrew::Overlay.remove_inherited_prefix_link!(dst) unless dry_run\n\n"
                "    if dst.symlink? && src == resolved_path(dst)\n"
            )
        fail("keg.rb: unrecognized conflict")

    resolve_conflicts(path, 9, handler)


def resolve_reinstall() -> None:
    path = "Library/Homebrew/reinstall/reinstall.rb"

    def handler(_index: int, ours: str, theirs: str) -> str:
        if 'require "utils/interrupts"' in ours and 'require "overlay"' in theirs:
            return ours + 'require "overlay"\n'
        if "Utils::Interrupts.ignore" in ours and "overlay_session.rollback!" in theirs:
            return (
                "        Utils::Interrupts.ignore do\n"
                "          if overlay_session\n"
                "            overlay_session.rollback!\n"
                "          elsif keg\n"
                "            restore_backup(keg, link_keg, verbose:)\n"
                "          end\n"
                "        end\n"
            )
        fail("reinstall.rb: unrecognized conflict")

    resolve_conflicts(path, 2, handler)


def resolve_tests() -> None:
    resolve_conflicts(
        "Library/Homebrew/test/cmd/bundle/cleanup_subcommand_spec.rb",
        1,
        lambda _i, ours, _theirs: ours,
    )
    resolve_conflicts(
        "Library/Homebrew/test/cmd/postinstall_spec.rb",
        1,
        lambda _i, ours, theirs: ours.rstrip("\n") + "\n\n" + theirs,
    )
    unlink_path = "Library/Homebrew/test/cmd/unlink_spec.rb"
    text = resolve_conflicts(
        unlink_path,
        1,
        lambda _i, ours, theirs: ours.rstrip("\n") + "\n\n" + theirs,
    )
    text = replace_once(
        text,
        "      allow(cmd.args.named).to receive(:to_default_kegs).and_return([keg])\n",
        "      allow(cmd.args.named).to receive(:to_kegs_to_casks).and_return([[keg], []])\n",
        label=f"{unlink_path} resolver mock",
    )
    Path(unlink_path).write_text(text, encoding="utf-8")


def make_promotion_repository_local() -> None:
    foreign_repository = "wangzheng15534-blip/brew"
    workflow_path = Path(".github/workflows/rebase-upstream-overlay.yml")
    workflow = workflow_path.read_text(encoding="utf-8")
    workflow = re.sub(
        r"^    if: github\.repository == 'wangzheng15534-blip/brew'\n",
        "",
        workflow,
        flags=re.MULTILINE,
    )
    workflow = workflow.replace(foreign_repository, "${GITHUB_REPOSITORY}")
    if foreign_repository in workflow:
        fail("foreign promotion repository remains in overlay workflow")
    workflow_path.write_text(workflow, encoding="utf-8")

    test_path = Path("Library/Homebrew/test/support/overlay_rebase_workflow_test.sh")
    test = test_path.read_text(encoding="utf-8")
    test = test.replace(
        "    \"if: github.repository == 'wangzheng15534-blip/brew'\",\n",
        "",
    )
    dynamic_origin = "    'https://github.com/${GITHUB_REPOSITORY}.git',\n"
    anchor = '    "core.hooksPath /dev/null",\n'
    if dynamic_origin not in test:
        if anchor not in test:
            fail("overlay workflow test anchor changed")
        test = test.replace(anchor, anchor + dynamic_origin, 1)
    safety_anchor = 'if "OVERLAY_PROMOTION_TOKEN" in rebase[:promote_start]:\n'
    safety_check = (
        'if "wangzheng15534-blip/brew" in rebase:\n'
        '    raise SystemExit("overlay workflow targets a foreign repository")\n'
        'if "if: github.repository ==" in prepare:\n'
        '    raise SystemExit("overlay preparation is tied to a copied repository name")\n'
    )
    if safety_check not in test:
        if safety_anchor not in test:
            fail("overlay workflow safety-test anchor changed")
        test = test.replace(safety_anchor, safety_check + safety_anchor, 1)
    test_path.write_text(test, encoding="utf-8")

    docs_path = Path("docs/Overlay-Promotion-Credentials.md")
    docs = docs_path.read_text(encoding="utf-8")
    docs = docs.replace(
        "Promotion requires an environment secret named `OVERLAY_PROMOTION_TOKEN` in "
        "`wangzheng15534-blip/brew`.",
        "Promotion requires an environment secret named `OVERLAY_PROMOTION_TOKEN` in "
        "the repository that runs the workflow.",
    )
    if foreign_repository in docs:
        fail("foreign promotion repository remains in overlay credential docs")
    docs_path.write_text(docs, encoding="utf-8")


def assert_clean_resolution() -> None:
    result = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=U"],
        check=True,
        capture_output=True,
        text=True,
    )
    if result.stdout.strip():
        fail(f"unmerged paths remain:\n{result.stdout}")
    for path in Path(".").rglob("*"):
        if not path.is_file() or ".git" in path.parts:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if "<<<<<<< HEAD" in text or ">>>>>>> " in text:
            fail(f"conflict marker remains in {path}")


def main() -> None:
    resolve_shellenv()
    resolve_unlink()
    resolve_formula_installer()
    resolve_formula_pin()
    resolve_install()
    resolve_keg()
    resolve_reinstall()
    resolve_tests()
    make_promotion_repository_local()

    subprocess.run(
        [
            "git",
            "add",
            "Library/Homebrew/cmd/shellenv.sh",
            "Library/Homebrew/cmd/unlink.rb",
            "Library/Homebrew/formula_installer.rb",
            "Library/Homebrew/formula_pin.rb",
            "Library/Homebrew/install.rb",
            "Library/Homebrew/install/check.rb",
            "Library/Homebrew/keg.rb",
            "Library/Homebrew/reinstall/reinstall.rb",
            "Library/Homebrew/test/cmd/bundle/cleanup_subcommand_spec.rb",
            "Library/Homebrew/test/cmd/postinstall_spec.rb",
            "Library/Homebrew/test/cmd/unlink_spec.rb",
            ".github/workflows/rebase-upstream-overlay.yml",
            "Library/Homebrew/test/support/overlay_rebase_workflow_test.sh",
            "docs/Overlay-Promotion-Credentials.md",
        ],
        check=True,
    )
    assert_clean_resolution()


if __name__ == "__main__":
    main()
