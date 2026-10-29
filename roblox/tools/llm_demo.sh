#!/bin/bash
# Play a round of the live town headlessly, with the real LLM harness: the
# same Game / TownSim / LlmPolicy / Harness modules the Roblox server runs,
# driven by Lune at wall-clock speed. Needs harness/run.sh going.
#   tools/llm_demo.sh                 # 90 s, seller-b model-driven
#   tools/llm_demo.sh 60 scripted     # the same round with nobody model-driven
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
rokit="${ROKIT:-$HOME/.rokit/bin/rokit}"
shim="$(dirname "$rokit")/lune"
if ! [ -x "$shim" ]; then "$rokit" install; fi
exec "$shim" run tools/llm_demo.luau "$@"
