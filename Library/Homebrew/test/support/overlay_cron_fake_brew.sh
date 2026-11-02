#!/bin/sh
printf '%s\n' "${*}" >"${BREW_CALLS:?}"
