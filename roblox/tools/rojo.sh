#!/bin/bash
# Run the Rojo pinned in rokit.toml (never whatever `rojo` is first on PATH).
# Rokit's shim picks the version from the nearest rokit.toml, so run it from
# this directory; then refuse to go on if the version doesn't match the pin.
#   tools/rojo.sh build default.project.json -o NandaTownS0.rbxlx
#   tools/rojo.sh serve default.project.json
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
rokit="${ROKIT:-$HOME/.rokit/bin/rokit}"
shim="$(dirname "$rokit")/rojo"
want="$(sed -n 's/^rojo *= *"rojo-rbx\/rojo@\(.*\)"/\1/p' rokit.toml)"
if ! [ -x "$shim" ] || ! "$shim" --version >/dev/null 2>&1; then
  "$rokit" install
fi
have="$("$shim" --version | awk '{print $2}')"
if [ "$have" != "$want" ]; then
  echo "rojo $have != pinned $want; run: $rokit install" >&2
  exit 1
fi
exec "$shim" "$@"
