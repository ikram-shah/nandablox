#!/bin/bash
# Headless tests for NANDA Market (MarketSim, Layout, Gateway), with the Lune
# pinned in rokit.toml. No Studio. Prints the claims table.
#   tools/test-market.sh          # all of roblox/tests/market/test_*.luau
#   tools/test-market.sh claims   # only files whose name contains "claims"
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
exec "$shim" run tests/market/run.luau "$@"
