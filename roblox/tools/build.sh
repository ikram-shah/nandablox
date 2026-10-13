#!/bin/bash
# Build a place from a Rojo project with the pinned Rojo. The output is a build
# artifact (git-ignored): regenerate it, never edit it.
#   tools/build.sh [project]      # default | movie  ->  build/<project>.rbxlx
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
project="${1:-default}"
mkdir -p "$here/build"
"$here/tools/rojo.sh" build "$project.project.json" -o "build/$project.rbxlx" >&2
echo "$here/build/$project.rbxlx"
