#!/bin/bash
# Run the LLM agent harness. Standard library only: no venv, no install.
#
#   harness/run.sh                      # http://127.0.0.1:8790, gemini-2.5-flash
#   harness/run.sh --model gemini-3-pro-preview
#   harness/run.sh --no-llm             # serve the API, never call a model
#
# In tmux, so it outlives the shell and keeps its scrollback:
#   tmux new -s nanda-harness 'harness/run.sh 2>&1 | tee $TMPDIR/nanda-harness/run.log; exec $SHELL'
#
# GEMINI_API_KEY comes from the environment or ~/.env; it is never printed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
mkdir -p "${TMPDIR:-/tmp}/nanda-harness"
exec "${PYTHON:-python3}" -m nanda_harness "$@"
