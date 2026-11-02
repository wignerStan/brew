#!/bin/bash
set -euo pipefail
: "${FAKE_CRONTAB_FILE:?}" "${FAKE_CRONTAB_WRITES:?}"
case "${1}" in
  -l)
    if [[ -f "${FAKE_CRONTAB_FILE}" ]]
    then
      cat "${FAKE_CRONTAB_FILE}"
    else
      echo 'no crontab for runner' >&2
      exit 1
    fi
    ;;
  -)
    [[ "${FAKE_CRONTAB_FAIL_INSTALL:-0}" == 0 ]] || exit 1
    cat >"${FAKE_CRONTAB_FILE}"
    printf 'write\n' >>"${FAKE_CRONTAB_WRITES}"
    ;;
  *) exit 2 ;;
esac
