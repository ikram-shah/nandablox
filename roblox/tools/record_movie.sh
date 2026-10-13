#!/bin/bash
# Record the movie place in Studio and cut the finished media into site/media/.
#
#   tools/open_in_studio.sh movie      # once: Studio on build/movie.rbxlx (from Rojo)
#   tools/record_movie.sh              # one take: ~80 s with Studio fullscreen
#
# Studio has no recorder, and Roblox's own capture is a 30 s player feature, so
# this grabs the X11 screen with ffmpeg. It switches to Studio's i3 workspace and
# focuses it, checks that Studio really is the focused window and keeps a still
# of the screen ($TMPDIR/nanda-movie/preflight.png), records the whole screen at
# 30 fps without the mouse, presses F5 (Play) and later Shift+F5 (Stop), then
# returns to the previous workspace. Studio only renders while it is visible, so
# the desktop is busy for the ~80 s of the take. tools/cut_movie.py finds the crop and the start from the movie's own
# pre-roll marks (a black 16:9 frame on magenta) and writes the MP4, a 720p
# WhatsApp copy and a poster.
#
# PLAY=external leaves Play/Stop to someone else (e.g. the MCP solo_playtest):
# the script prints READY once it is recording.
# One command, if Studio is open on the movie place:  tools/record_movie.sh
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
  [ "$play" = f5 ] && { xdotool key --window "$win" shift+F5 2>/dev/null || true; sleep 1; }
  i3-msg -q "workspace $prev_ws" || true
  xdotool mousemove "$mx" "$my" || true
}
trap restore EXIT

# i3, not xdotool windowactivate: with i3's default focus_on_window_activation
# (smart), activating a window on a hidden workspace only marks it urgent, so the
# first take recorded whatever workspace was showing. Studio also only renders
# while its workspace is visible.
i3-msg -q "[id=$win] focus"
# (No fullscreen: under Wine, i3's `fullscreen enable` reports success and does
# nothing. cut_movie.py finds the crop from the movie's own marks anyway.)
xdotool mousemove 1919 0     # out of the viewport (the cursor isn't recorded anyway)
sleep 1.5                    # let the compositor finish the workspace fade
# preflight: Studio must be the focused window on the visible workspace
state="$(i3-msg -t get_tree | python3 -c '
import json, sys
w = int(sys.argv[1])
def walk(n):
    if n.get("window") == w:
        return n
    for c in n.get("nodes", []) + n.get("floating_nodes", []):
        r = walk(c)
        if r:
            return r
n = walk(json.load(sys.stdin))
print("ok" if n and n.get("focused") else "bad")' "$win")"
ffmpeg -v error -y -f x11grab -draw_mouse 0 -video_size 1920x1200 -i "$DISPLAY" -frames:v 1 "$work/preflight.png"
if [ "$state" != ok ]; then
  echo "preflight failed: Studio is not the focused window (see $work/preflight.png)" >&2
  exit 1
fi
echo "preflight ok: $work/preflight.png"

ffmpeg -v error -y -thread_queue_size 1024 -f x11grab -draw_mouse 0 -framerate 30 \
  -video_size 1920x1200 -i "$DISPLAY" -t "$secs" \
  -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv444p "$raw" &
ff=$!
sleep 1
if [ "$play" = f5 ]; then
  xdotool key F5   # Studio has focus (checked above)
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
