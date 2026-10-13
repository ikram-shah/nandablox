#!/bin/bash
# Build a place with the pinned Rojo and open it in Roblox Studio (Vinegar/Wine
# flatpak). The flatpak can't see ~/prg, so the built place is copied into the
# Wine prefix as C:\nanda\NandaTown-<project>.rbxlx. Studio runs in a detached
# tmux session (default: studio-nanda).
#   tools/open_in_studio.sh [project] [tmux-session]    # project: default | movie | play
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
project="${1:-default}"
session="${2:-studio-nanda}"
prefix="$HOME/.var/app/org.vinegarhq.Vinegar/data/vinegar/prefixes/studio/drive_c/nanda"
if tmux has-session -t "=$session" 2>/dev/null; then
  echo "tmux session '$session' already exists; close that Studio first or pass another name" >&2
  exit 1
fi
place="$("$here/tools/build.sh" "$project")"
mkdir -p "$prefix"
cp "$place" "$prefix/NandaTown-$project.rbxlx"
tmux new-session -d -s "$session" \
  "DISPLAY=\${DISPLAY:-:0} flatpak run org.vinegarhq.Vinegar '$prefix/NandaTown-$project.rbxlx' 2>&1 | tee \${TMPDIR:-/tmp}/$session.log; exec \$SHELL"
echo "Studio starting in tmux session '$session' with C:\\nanda\\NandaTown-$project.rbxlx; press Play (F5)."
