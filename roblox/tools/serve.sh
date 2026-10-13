#!/bin/bash
# The dev loop: serve a Rojo project to the Rojo plugin in Studio (Plugins tab ->
# Rojo -> Connect, localhost:34872). Edits under src/ sync live into the open
# place; nothing is made by hand in Studio.
#   tools/serve.sh [project]      # default | movie
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
exec "$here/tools/rojo.sh" serve "${1:-default}.project.json" --port "${ROJO_PORT:-34872}"
