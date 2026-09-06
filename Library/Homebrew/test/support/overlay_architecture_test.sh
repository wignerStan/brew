#!/bin/bash
        set -euo pipefail

        repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
        repo="$(cd "${repo}" && pwd -P)"
        ruby_loader="${repo}/Library/Homebrew/overlay.rb"
        ruby_impl="${repo}/Library/Homebrew/overlay"
        shell_loader="${repo}/Library/Homebrew/utils/overlay.sh"
        shell_impl="${repo}/Library/Homebrew/utils/overlay"
        formula_installer="${repo}/Library/Homebrew/formula_installer.rb"
        reinstall_adapter="${repo}/Library/Homebrew/reinstall/reinstall.rb"

        [[ "$(wc -l <"${ruby_loader}")" -le 15 ]] || {
          echo "Error: public Ruby overlay loader accumulated implementation" >&2
          exit 1
        }
        [[ "$(wc -l <"${shell_loader}")" -le 20 ]] || {
          echo "Error: public shell overlay loader accumulated implementation" >&2
          exit 1
        }

        grep -Fx 'require "overlay/core"' "${ruby_loader}" >/dev/null || {
          echo "Error: public Ruby overlay loader no longer loads overlay/core" >&2
          exit 1
        }
        grep -Fx 'require "overlay/owned_io"' "${ruby_loader}" >/dev/null || {
          echo "Error: public Ruby overlay loader no longer loads overlay/owned_io" >&2
          exit 1
        }
        grep -Fx 'require "overlay/durable_fs"' "${ruby_loader}" >/dev/null || {
          echo "Error: public Ruby overlay loader no longer loads overlay/durable_fs" >&2
          exit 1
        }
        grep -Fx 'require "overlay/install_session"' "${ruby_loader}" >/dev/null || {
          echo "Error: public Ruby overlay loader no longer loads the install session" >&2
          exit 1
        }
        grep -Fx 'require "overlay/reinstall_session"' "${ruby_loader}" >/dev/null || {
          echo "Error: public Ruby overlay loader no longer loads the reinstall session" >&2
          exit 1
        }
        grep -F 'overlay/core.sh' "${shell_loader}" >/dev/null || {
          echo "Error: public shell overlay loader no longer loads overlay/core.sh" >&2
          exit 1
        }

        grep -F 'Homebrew::Overlay::ReinstallSession.build' "${reinstall_adapter}" >/dev/null || {
          echo "Error: reinstall no longer delegates through the overlay session" >&2
          exit 1
        }
        if grep -Eq 'Homebrew::Overlay::(ReinstallBackup|inherited_keg\?|mutation_active\?|begin_mutation!|sync!)'           "${reinstall_adapter}"
        then
          echo "Error: overlay reinstall policy leaked back into the upstream-facing adapter" >&2
          exit 1
        fi

        grep -F 'Homebrew::Overlay::InstallSession.new' "${formula_installer}" >/dev/null || {
          echo "Error: FormulaInstaller no longer constructs InstallSession" >&2
          exit 1
        }
        grep -F '@overlay_install_session.start!(formula)' "${formula_installer}" >/dev/null || {
          echo "Error: FormulaInstaller no longer passes its current formula at install start" >&2
          exit 1
        }
        if grep -Fq 'InstallSession.new(@formula)' "${formula_installer}"
        then
          echo "Error: FormulaInstaller captured a potentially stale formula in InstallSession" >&2
          exit 1
        fi
        for legacy_state in           @overlay_transaction           @overlay_base_generation           @overlay_local_keg_preexisting           @overlay_local_keg_committed           @overlay_mutation_owned           @overlay_previous_failed           @overlay_base_mutation_lease           verify_overlay_base_generation!           raise_overlay_transaction_failure!           rollback_overlay_uncommitted_local_keg!           finalize_failed_overlay_mutation!           restore_overlay_failure_scope!           release_overlay_base_mutation_lease!
        do
          if grep -Fq "${legacy_state}" "${formula_installer}"
          then
            echo "Error: FormulaInstaller owns legacy overlay state: ${legacy_state}" >&2
            exit 1
          fi
        done

        while IFS= read -r file
        do
          case "${file}" in
            "${ruby_loader}" | "${ruby_impl}"/*) continue ;;
            *) ;;
          esac
          if grep -Eq 'require[[:space:]]+"overlay/' "${file}"
          then
            echo "Error: Homebrew-owned Ruby code bypasses the public overlay loader: ${file#"${repo}/"}" >&2
            exit 1
          fi
        done < <(find "${repo}/Library/Homebrew" -type f -name '*.rb' -print)

        while IFS= read -r file
        do
          case "${file}" in
            "${shell_loader}" | "${shell_impl}"/* | "${repo}/Library/Homebrew/test/"*) continue ;;
            *) ;;
          esac
          if grep -Fq 'overlay/core.sh' "${file}"
          then
            echo "Error: Homebrew-owned shell code bypasses the public overlay loader: ${file#"${repo}/"}" >&2
            exit 1
          fi
        done < <(
          find "${repo}/Library/Homebrew" "${repo}/bin" -type f             \( -name '*.sh' -o -path "${repo}/bin/brew" \) -print
        )

        extracted_methods=(
          open_retained_file
          read_owned_file
          ensure_owned_directory!
          fsync_directory!
          fsync_tree!
          durable_atomic_write!
          durable_unlink!
          remove_tree_durable!
        )
        for extracted_method in "${extracted_methods[@]}"
        do
          if grep -Fq "def self.${extracted_method}" "${ruby_impl}/core.rb"
          then
            echo "Error: extracted overlay method returned to core.rb: ${extracted_method}" >&2
            exit 1
          fi
        done

        for owned_method in open_retained_file read_owned_file
        do
          grep -Fq "def self.${owned_method}" "${ruby_impl}/owned_io.rb" || {
            echo "Error: overlay/owned_io.rb no longer owns ${owned_method}" >&2
            exit 1
          }
        done

        for durable_method in ensure_owned_directory! fsync_directory! fsync_tree! durable_atomic_write! durable_unlink! remove_tree_durable!
        do
          grep -Fq "def self.${durable_method}" "${ruby_impl}/durable_fs.rb" || {
            echo "Error: overlay/durable_fs.rb no longer owns ${durable_method}" >&2
            exit 1
          }
        done

        printf 'overlay architecture boundary: PASS
'
