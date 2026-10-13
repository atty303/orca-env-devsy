#!/usr/bin/env bash
set -euo pipefail
link=true
for argument in "$@"; do
  case "$argument" in -c|-E|-S|-dumpmachine|--version|-v) link=false ;; esac
done
if [[ "$link" == true && "$ORCA_ENV_DEVSY_TARGET" == *-linux-* ]]; then
  exec zig cc -target "$ORCA_ENV_DEVSY_TARGET" "$@" -Wl,--strip-all
fi
exec zig cc -target "${ORCA_ENV_DEVSY_TARGET:?cross target required}" -isystem "$MOON_TOOLCHAIN_ROOT/cross-headers" "$@"
