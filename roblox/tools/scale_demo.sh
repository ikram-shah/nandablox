#!/bin/bash
# The oversight demo, headless: step through DEMO.md beats in simulated time
#   tools/scale_demo.sh            # 60 s per beat, seed 1
#   tools/scale_demo.sh 45 3 json  # 45 s per beat, seed 3, JSON lines
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
rokit="${ROKIT:-$HOME/.rokit/bin/rokit}"
shim="$(dirname "$rokit")/lune"
if ! [ -x "$shim" ]; then "$rokit" install; fi
exec "$shim" run tools/scale_demo.luau "$@"
