#!/usr/bin/env python3
"""Apply the v4 FormulaInstaller reconciliation, then run the strict base resolver."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType


def load_base(path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location("_overlay_rebase_resolver_base", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"unable to load base resolver from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def install_formula_installer_resolver(base: ModuleType) -> None:
    path = "Library/Homebrew/formula_installer.rb"

    def handler(index: int, ours: str, theirs: str) -> str:
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
        if "retain_tmp = keep_tmp?" in ours and "formula_path = formula.specified_path" in theirs:
            return ours
        if "HOMEBREW_BUILD_STAGING_PATH" in ours and \
           "@overlay_install_session.build_environment" in theirs:
            return ours
        if "add_build_sandbox_rules" in ours and \
           "@overlay_install_session.apply_build_sandbox_rules" in theirs:
            return ours
        base.fail(
            "formula_installer.rb: unrecognized conflict "
            f"{index + 1}\n--- upstream ---\n{ours}\n--- overlay ---\n{theirs}"
        )

    def resolve_formula_installer() -> None:
        text = base.resolve_conflicts(path, 5, handler)
        text = base.replace_once(
            text,
            "    with_env(HOMEBREW_BUILD_STAGING_PATH: staging_path, HOMEBREW_BUILD_FETCH_PHASE: nil) do\n",
            "    with_env(\n"
            "      **@overlay_install_session.build_environment,\n"
            "      HOMEBREW_BUILD_STAGING_PATH: staging_path,\n"
            "      HOMEBREW_BUILD_FETCH_PHASE: nil,\n"
            "    ) do\n",
            label=f"{path} build environment",
        )
        text = base.replace_once(
            text,
            '        add_build_sandbox_rules(sandbox, formula_path, log_name: "build")\n',
            '        add_build_sandbox_rules(sandbox, formula_path, log_name: "build")\n'
            "        @overlay_install_session.apply_build_sandbox_rules(sandbox)\n",
            label=f"{path} build sandbox",
        )
        text = base.replace_once(
            text,
            '    with_env(HOMEBREW_BUILD_FETCH_PHASE: "1", HOMEBREW_BUILD_STAGING_PATH: staging_path) do\n',
            "    with_env(\n"
            "      **@overlay_install_session.build_environment,\n"
            '      HOMEBREW_BUILD_FETCH_PHASE: "1",\n'
            "      HOMEBREW_BUILD_STAGING_PATH: staging_path,\n"
            "    ) do\n",
            label=f"{path} fetch environment",
        )
        text = base.replace_once(
            text,
            '        add_build_sandbox_rules(sandbox, formula_path, log_name: "fetch")\n',
            '        add_build_sandbox_rules(sandbox, formula_path, log_name: "fetch")\n'
            "        @overlay_install_session.apply_build_sandbox_rules(sandbox)\n",
            label=f"{path} fetch sandbox",
        )
        Path(path).write_text(text, encoding="utf-8")

    base.resolve_formula_installer = resolve_formula_installer


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} BASE_RESOLVER")
    base = load_base(Path(sys.argv[1]))
    install_formula_installer_resolver(base)
    base.main()


if __name__ == "__main__":
    main()
