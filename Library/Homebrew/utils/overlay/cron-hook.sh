# shellcheck shell=bash
# Source from brew shellenv or a lightweight shell startup file.
# This file uses only Bash and Zsh common syntax.
homebrew_overlay_cron_check() {
  local base="${HOMEBREW_OVERLAY_BASE_PREFIX:-/home/linuxbrew/.linuxbrew}"
  local prefix="${HOMEBREW_PREFIX:-${HOME}/.linuxbrew}"
  local repository="${HOMEBREW_REPOSITORY:-${base}/Homebrew}"
  [[ -d "${base}" && ! -O "${base}" && "${prefix}" != "${base}" &&
    -x "${prefix}/bin/brew" ]] || return 0

  local marker="${prefix}/var/homebrew/overlay/.cron-checked-date"
  local today checked=''
  today="$(date +%F)" || return 1
  if [[ -r "${marker}" && ! -L "${marker}" ]]
  then
    IFS= read -r checked <"${marker}" || true
  fi
  [[ "${checked}" == "${today}" ]] && return 0

  if ! /bin/bash "${repository}/Library/Homebrew/utils/overlay/cron.sh" \
     --ensure "${prefix}" "${base}" "${repository}" "${today}"
  then
    printf 'Warning: could not restore the Homebrew overlay cron job.\n' >&2
    return 1
  fi
}
homebrew_overlay_cron_check
unset -f homebrew_overlay_cron_check
