#!/bin/bash
# Headless tests for the pure-Luau core of Red vs. Blue (TownSim, Game,
# Council, Bots, Telemetry), run with the Lune pinned in rokit.toml. No Studio.
#   tools/test.sh            # all of roblox/tests/test_*.luau
#   tools/test.sh council    # only files whose name contains "council"
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
rokit="${ROKIT:-$HOME/.rokit/bin/rokit}"
shim="$(dirname "$rokit")/lune"
want="$(sed -n 's/^lune *= *"lune-org\/lune@\(.*\)"/\1/p' rokit.toml)"
if ! [ -x "$shim" ] || ! "$shim" --version >/dev/null 2>&1; then
  "$rokit" install
fi
have="$("$shim" --version | awk '{print $2}')"
if [ "$have" != "$want" ]; then
  echo "lune $have != pinned $want; run: $rokit install" >&2
  exit 1
fi
exec "$shim" run tests/run.luau "$@"
