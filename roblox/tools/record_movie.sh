#!/bin/bash
# Record the movie place in Studio and cut the finished media into site/media/.
#
#   tools/open_in_studio.sh movie      # once: Studio on build/movie.rbxlx (from Rojo)
#   tools/record_movie.sh              # one take: ~80 s with Studio fullscreen
#
# Studio has no recorder, and Roblox's own capture is a 30 s player feature, so
# this grabs the X11 screen with ffmpeg. It raises the Studio window and makes it
# fullscreen (i3), records the whole screen at 30 fps without the mouse, presses
# F5 (Play) and later Shift+F5 (Stop), then puts the window and the workspace
# back. tools/cut_movie.py finds the crop and the start from the movie's own
# pre-roll marks (a black 16:9 frame on magenta) and writes the MP4, a 720p
# WhatsApp copy and a poster.
#
# PLAY=external leaves Play/Stop to someone else (e.g. the MCP solo_playtest):
# the script prints READY once it is recording.
# Env: SECONDS_TO_RECORD (default 82), PLAY (f5 | external), OUT (default ../site/media).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
export DISPLAY="${DISPLAY:-:0}"
secs="${SECONDS_TO_RECORD:-82}"
play="${PLAY:-f5}"
out="${OUT:-$here/../site/media}"
work="${TMPDIR:-/tmp}/nanda-movie"
mkdir -p "$work"
raw="$work/raw-$(date +%Y%m%d-%H%M%S).mkv"

win="$(xdotool search --name 'NandaTown-movie\.rbxlx - Roblox Studio' | head -1 || true)"
[ -n "$win" ] || { echo "no Studio window on NandaTown-movie.rbxlx; run tools/open_in_studio.sh movie" >&2; exit 1; }
prev_ws="$(i3-msg -t get_workspaces | python3 -c 'import json,sys; print([w["name"] for w in json.load(sys.stdin) if w["focused"]][0])')"
eval "$(xdotool getmouselocation --shell)"; mx=$X; my=$Y

restore() {
  [ "$play" = f5 ] && { xdotool windowactivate --sync "$win" key shift+F5 2>/dev/null || true; sleep 1; }
  i3-msg -q "[id=$win] fullscreen disable" || true
  i3-msg -q "workspace $prev_ws" || true
  xdotool mousemove "$mx" "$my" || true
}
trap restore EXIT

xdotool windowactivate --sync "$win"
i3-msg -q "[id=$win] fullscreen enable"
xdotool mousemove 1919 0     # out of the viewport (the cursor isn't recorded anyway)
sleep 1.5                    # let the compositor finish the workspace fade

ffmpeg -v error -y -thread_queue_size 1024 -f x11grab -draw_mouse 0 -framerate 30 \
  -video_size 1920x1200 -i "$DISPLAY" -t "$secs" \
  -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv444p "$raw" &
ff=$!
sleep 1
if [ "$play" = f5 ]; then
  xdotool windowactivate --sync "$win" key F5
else
  echo READY
fi
# The screen is shared: if anything takes focus from Studio mid-take, stop and
# delete the take rather than keep a recording of someone else's screen.
while kill -0 "$ff" 2>/dev/null; do
  if ! xdotool getactivewindow getwindowname 2>/dev/null | grep -q 'Roblox Studio'; then
    kill "$ff" 2>/dev/null || true
    wait "$ff" 2>/dev/null || true
    rm -f "$raw"
    echo "Studio lost focus during the take; take deleted. Try again when the desktop is free." >&2
    exit 1
  fi
  sleep 0.25
done
wait "$ff"
restore
trap - EXIT

python3 "$here/tools/cut_movie.py" "$raw" "$out"
echo "raw take: $raw"
