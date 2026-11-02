#!/bin/bash
# Maintain one native overlay sync job in each overlay user's own crontab.
set -euo pipefail
umask 077
export LC_ALL=C

mode="${1:-}"
prefix="${2:-}"
base="${3:-}"
repository="${4:-}"
today="${5:-}"
for path in "${prefix}" "${base}" "${repository}"
do
  [[ "${path}" =~ ^/[A-Za-z0-9_+./-]+$ ]] || exit 2
done
[[ "${prefix}" != "${base}" && -d "${prefix}" && -O "${prefix}" &&
  -d "${base}" && ! -O "${base}" && -x "${base}/bin/brew" ]] || exit 0

state="${prefix}/var/homebrew/overlay"
[[ -d "${state}" && ! -L "${state}" && -O "${state}" ]] || exit 1

case "${mode}" in
  --ensure)
    [[ "${today}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || exit 2
    marker="${state}/.cron-checked-date"
    [[ ! -L "${marker}" ]] || exit 1
    exec 9>"${state}/cron-ensure.lock"
    flock -w 15 9
    checked=''
    if [[ -r "${marker}" ]]
    then
      IFS= read -r checked <"${marker}" || true
    fi
    [[ "${checked}" == "${today}" ]] && exit 0

    cron="${HOMEBREW_OVERLAY_CRONTAB_BIN:-/usr/bin/crontab}"
    if ! current="$("${cron}" -l 2>&1)"
    then
      case "${current}" in
        'no crontab for '*) current='' ;;
        *)
          printf '%s\n' "${current}" >&2
          exit 1
          ;;
      esac
    fi
    tag='# homebrew-overlay-sync'
    desired="17 3 * * * /bin/bash ${repository}/Library/Homebrew/utils/overlay/cron.sh --run ${prefix} ${base} ${repository} ${tag}"
    tagged="$(printf '%s\n' "${current}" | grep -Fc -- "${tag}" || true)"
    exact="$(printf '%s\n' "${current}" | grep -Fxc -- "${desired}" || true)"
    if [[ "${tagged}" != 1 || "${exact}" != 1 ]]
    then
      {
        if [[ -n "${current}" ]]
        then
          printf '%s\n' "${current}" | awk -v tag="${tag}" 'index($0, tag) == 0'
        fi
        printf '%s\n' "${desired}"
      } | "${cron}" -
    fi
    installed="$("${cron}" -l)"
    [[ "$(printf '%s\n' "${installed}" | grep -Fxc -- "${desired}" || true)" == 1 ]] || exit 1
    printf '%s\n' "${today}" >"${marker}"
    ;;
  --run)
    cd "${HOME}"
    if flock -n "${state}/cron-run.lock" env \
       HOMEBREW_OVERLAY=1 \
       HOMEBREW_OVERLAY_BASE_PREFIX="${base}" \
       HOMEBREW_OVERLAY_USER_PREFIX="${prefix}" \
       "${base}/bin/brew" overlay-sync --repair >"${state}/cron-last.log" 2>&1
    then
      date -Is >"${state}/.cron-last-success"
    else
      status=${?}
      printf '%s %s\n' "$(date -Is)" "${status}" >"${state}/.cron-last-failure"
      exit "${status}"
    fi
    ;;
  *) exit 2 ;;
esac
