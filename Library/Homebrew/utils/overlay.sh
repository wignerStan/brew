# Stable loader for the native overlay shell implementation.
#
# When invoked as a command, execute the implementation so its existing
# BASH_SOURCE dispatch remains authoritative. When sourced by bin/brew, source
# the same implementation into the caller's shell.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]
then
  exec /bin/bash "${BASH_SOURCE[0]%/*}/overlay/core.sh" "$@"
fi

# shellcheck source=Homebrew/utils/overlay/core.sh
source "${BASH_SOURCE[0]%/*}/overlay/core.sh"
