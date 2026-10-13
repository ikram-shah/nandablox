#!/bin/bash
# Build the place with Rojo and open it in Roblox Studio (Vinegar/Wine flatpak).
# The flatpak can't see ~/prg, so the place is copied into the Wine prefix
# (C:\nanda\) first. Studio runs in a detached tmux session (default: studio-s0).
#   tools/open_in_studio.sh [tmux-session-name]
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
session="${1:-studio-s0}"
prefix="$HOME/.var/app/org.vinegarhq.Vinegar/data/vinegar/prefixes/studio/drive_c/nanda"
mkdir -p "$prefix"
rojo build "$here/default.project.json" -o "$here/NandaTownS0.rbxlx"
cp "$here/NandaTownS0.rbxlx" "$prefix/NandaTown-S0-replay.rbxlx"
tmux new-session -d -s "$session" \
  "DISPLAY=\${DISPLAY:-:0} flatpak run org.vinegarhq.Vinegar '$prefix/NandaTown-S0-replay.rbxlx' 2>&1 | tee \${TMPDIR:-/tmp}/$session.log; exec \$SHELL"
echo "Studio starting in tmux session '$session' with C:\\nanda\\NandaTown-S0-replay.rbxlx; press Play (F5)."
