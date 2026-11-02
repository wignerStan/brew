#!/bin/bash
# A fake crontab proves recovery without touching the runner's real schedule.
set -euo pipefail
umask 077
trap 'printf "overlay cron test failed at line %s: %s\n" "${LINENO}" "${BASH_COMMAND}" >&2' ERR

repository="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-cron.XXXXXX")"
base="${work}/base"
prefix="${work}/user"
trap 'if [[ -d "${base}" ]]; then sudo -n chown "${UID}" "${base}" 2>/dev/null || true; fi; rm -rf "${work}"' EXIT
mkdir -p "${base}/bin" "${prefix}/bin" "${prefix}/var/homebrew/overlay"
cp "${repository}/Library/Homebrew/test/support/overlay_cron_fake_brew.sh" "${base}/bin/brew"
chmod 0755 "${base}/bin/brew"
chmod 0755 "${base}"
ln -s "${base}/bin/brew" "${prefix}/bin/brew"
if ! sudo -n chown root "${base}" 2>/dev/null
then
  echo 'overlay cron test: SKIP (cannot create a non-owned base)'
  exit 0
fi

fake="${work}/crontab"
cp "${repository}/Library/Homebrew/test/support/overlay_cron_fake_crontab.sh" "${fake}"
chmod 0755 "${fake}"
export HOMEBREW_OVERLAY_CRONTAB_BIN="${fake}"
export FAKE_CRONTAB_FILE="${work}/schedule"
export FAKE_CRONTAB_WRITES="${work}/writes"
export BREW_CALLS="${work}/brew-calls"
today="$(date +%F)"
marker="${prefix}/var/homebrew/overlay/.cron-checked-date"
cron="${repository}/Library/Homebrew/utils/overlay/cron.sh"

printf 'MAILTO=runner@example.invalid\n4 * * * * echo unrelated\n' >"${FAKE_CRONTAB_FILE}"
/bin/bash "${cron}" --ensure "${prefix}" "${base}" "${repository}" "${today}"
grep -Fxq '4 * * * * echo unrelated' "${FAKE_CRONTAB_FILE}"
test "$(grep -Fc '# homebrew-overlay-sync' "${FAKE_CRONTAB_FILE}")" = 1
grep -Fq '17 3 * * * /bin/bash' "${FAKE_CRONTAB_FILE}"
test "$(cat "${marker}")" = "${today}"
test "$(wc -l <"${FAKE_CRONTAB_WRITES}")" = 1

/bin/bash "${cron}" --ensure "${prefix}" "${base}" "${repository}" "${today}"
test "$(wc -l <"${FAKE_CRONTAB_WRITES}")" = 1

# The dated marker permits one daily check; a removed entry is restored on
# the next date, and unrelated user jobs survive the replacement.
grep -Fv '# homebrew-overlay-sync' "${FAKE_CRONTAB_FILE}" >"${work}/unrelated"
cat "${work}/unrelated" >"${FAKE_CRONTAB_FILE}"
export HOMEBREW_PREFIX="${prefix}"
export HOMEBREW_OVERLAY_BASE_PREFIX="${base}"
export HOMEBREW_OVERLAY_ACTIVE=1
export HOMEBREW_REPOSITORY="${repository}"
source "${repository}/Library/Homebrew/utils/overlay/cron-hook.sh"
test "$(grep -Fc '# homebrew-overlay-sync' "${FAKE_CRONTAB_FILE}" || true)" = 0
printf 'yesterday\n' >"${marker}"
export HOMEBREW_PATH="${prefix}/bin:${prefix}/sbin:${base}/bin:${base}/sbin:/usr/bin:/bin"
# shellenv must check cron even when the PATH fast path returns no output.
source "${repository}/Library/Homebrew/cmd/shellenv.sh"
test -z "$(homebrew-shellenv bash)"
test "$(grep -Fc '# homebrew-overlay-sync' "${FAKE_CRONTAB_FILE}")" = 1
test "$(wc -l <"${FAKE_CRONTAB_WRITES}")" = 2

/bin/bash "${cron}" --run "${prefix}" "${base}" "${repository}"
test "$(cat "${BREW_CALLS}")" = 'overlay-sync --repair'
test -s "${prefix}/var/homebrew/overlay/.cron-last-success"

# The administrator base owner has no overlay cron.
owned="${work}/owned"
mkdir -p "${owned}/bin" "${work}/owned-user/var/homebrew/overlay"
touch "${owned}/bin/brew"
chmod 0755 "${owned}/bin/brew"
/bin/bash "${cron}" --ensure "${work}/owned-user" "${owned}" "${repository}" "${today}"
test ! -e "${work}/owned-user/var/homebrew/overlay/.cron-checked-date"
test "$(wc -l <"${FAKE_CRONTAB_WRITES}")" = 2

# Each overlay user has an independent crontab and check marker. A failed
# installation must remain eligible for a retry on the same date.
second="${work}/second-user"
mkdir -p "${second}/var/homebrew/overlay"
export FAKE_CRONTAB_FILE="${work}/second-schedule"
export FAKE_CRONTAB_WRITES="${work}/second-writes"
if FAKE_CRONTAB_FAIL_INSTALL=1 /bin/bash "${cron}" --ensure "${second}" "${base}" "${repository}" "${today}"
then
  echo 'failed crontab installation unexpectedly succeeded' >&2
  exit 1
fi
test ! -e "${second}/var/homebrew/overlay/.cron-checked-date"
/bin/bash "${cron}" --ensure "${second}" "${base}" "${repository}" "${today}"
test "$(cat "${second}/var/homebrew/overlay/.cron-checked-date")" = "${today}"
grep -Fq -- "--run ${second} ${base}" "${FAKE_CRONTAB_FILE}"
test "$(wc -l <"${FAKE_CRONTAB_WRITES}")" = 1

echo 'overlay cron reconciliation test: PASS'
