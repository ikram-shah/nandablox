#!/bin/bash
# Record cinema mode from the Roblox client (Sober) and cut it into site/media/.
#
#   1. tools/publish.sh                         # the place, published (README "Publish")
#   2. join it in Sober, fullscreen (F11) on the 1920x1200 screen, and wait for the town
#   3. tools/record_sober.sh                    # one take, ~75 s of the screen
#
# What it does: finds the Sober window (flatpak org.vinegarhq.Sober) by name
# with xdotool, focuses it with i3 (switching to its workspace), and checks
# that it is the focused window, 1920x1200 at 0,0 (fullscreen; if it is not,
# it asks i3 to fullscreen it and undoes that afterwards), keeping a still
# of the screen as $TMPDIR/nanda-sober/preflight.png. Then it records the whole
# screen with ffmpeg x11grab at 30 fps (no mouse), presses M (cinema mode: the
# movie take for this player only, with CoreGui and the topbar hidden and the
# fixed overview camera), records for the length of the take, and goes back to
# the workspace and mouse position it started from. If anything else takes
# focus mid-take, it stops and deletes the recording.
#
# The whole screen is recorded (not just the crop) so the movie's pre-roll
# marks are in it: a black 16:9 frame on magenta. At 1920x1200 that frame is
# exactly 1920x1080 at y=92 (full width, below the Roblox menu button), and
# tools/cut_movie.py crops exactly that rectangle without rescaling, so the
# result is native 1080p.
#
# Output: site/media/nanda-town-replay-sober.mp4, -720p.mp4 and -poster.png.
# Env: SECONDS_TO_RECORD (default 75), NAME (default nanda-town-replay-sober),
#      OUT (default ../site/media), SOBER_WINDOW (an X window id, to skip the search).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
export DISPLAY="${DISPLAY:-:0}"
secs="${SECONDS_TO_RECORD:-75}"
name="${NAME:-nanda-town-replay-sober}"
out="${OUT:-$here/../site/media}"
work="${TMPDIR:-/tmp}/nanda-sober"
mkdir -p "$work"
raw="$work/raw-$(date +%Y%m%d-%H%M%S).mkv"

for tool in xdotool i3-msg ffmpeg python3; do
  command -v "$tool" >/dev/null || { echo "needs $tool" >&2; exit 1; }
done
flatpak info org.vinegarhq.Sober >/dev/null 2>&1 || echo "warning: flatpak org.vinegarhq.Sober not found" >&2

# The Sober window: its title is "Sober" (the game's name is not in it). Take
# the largest visible window whose name or class says Sober.
find_sober() {
  local ids id best="" area=0
  ids="$( (xdotool search --onlyvisible --classname '[Ss]ober' 2>/dev/null; \
           xdotool search --onlyvisible --class '[Ss]ober' 2>/dev/null; \
           xdotool search --onlyvisible --name '^Sober' 2>/dev/null) | sort -u)"
  for id in $ids; do
    eval "$(xdotool getwindowgeometry --shell "$id" 2>/dev/null)" || continue
    if [ $((WIDTH * HEIGHT)) -gt "$area" ]; then
      area=$((WIDTH * HEIGHT)); best="$id"
    fi
  done
  echo "$best"
}
win="${SOBER_WINDOW:-$(find_sober)}"
[ -n "$win" ] || { echo "no Sober window: start Sober and join the NANDA Town place first" >&2; exit 1; }
echo "Sober window $win: $(xdotool getwindowname "$win")"

prev_ws="$(i3-msg -t get_workspaces | python3 -c 'import json,sys; print([w["name"] for w in json.load(sys.stdin) if w["focused"]][0])')"
eval "$(xdotool getmouselocation --shell)"; mx=$X; my=$Y
made_fullscreen=0
restore() {
  [ "$made_fullscreen" = 1 ] && { i3-msg -q "[id=$win] fullscreen disable" || true; }
  i3-msg -q "workspace $prev_ws" || true
  xdotool mousemove "$mx" "$my" || true
}
trap restore EXIT

# i3, not xdotool windowactivate (see record_movie.sh): activating a window on a
# hidden workspace only marks it urgent. The client only renders while visible.
i3-msg -q "[id=$win] focus"
xdotool mousemove 1919 1199   # bottom-right corner, out of the way (not recorded anyway)
sleep 1.5                     # compositor fade

# preflight: focused, fullscreen 1920x1200 at the origin, on the visible workspace
preflight() {
  i3-msg -t get_tree | python3 -c '
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
if not n:
    print("not managed by i3")
elif not n.get("focused"):
    print("not focused")
elif not n.get("fullscreen_mode", 0):
    print("not fullscreen")
else:
    r = n["rect"]
    if (r["x"], r["y"], r["width"], r["height"]) != (0, 0, 1920, 1200):
        print("fullscreen but %(width)dx%(height)d at %(x)d,%(y)d, not 1920x1200 at 0,0" % r)
    else:
        print("ok")' "$win"
}
state="$(preflight)"
if [ "$state" = "not fullscreen" ]; then
  # Sober is a native X client, so i3 can fullscreen it (unlike Studio under Wine);
  # undone afterwards
  i3-msg -q "[id=$win] fullscreen enable" && made_fullscreen=1
  sleep 1.5   # the client resizes, the movie's frame follows
  state="$(preflight)"
fi
ffmpeg -v error -y -f x11grab -draw_mouse 0 -video_size 1920x1200 -i "$DISPLAY" -frames:v 1 "$work/preflight.png"
if [ "$state" != ok ]; then
  echo "preflight failed: Sober is $state (see $work/preflight.png)" >&2
  exit 1
fi
echo "preflight ok: $work/preflight.png"

ffmpeg -v error -y -thread_queue_size 1024 -f x11grab -draw_mouse 0 -framerate 30 \
  -video_size 1920x1200 -i "$DISPLAY" -t "$secs" \
  -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv444p "$raw" &
ff=$!
sleep 1
# M starts cinema mode (NandaPlay.client.luau). A real key press to the focused
# window: Sober ignores synthetic events sent to an unfocused --window.
xdotool key --clearmodifiers m
while kill -0 "$ff" 2>/dev/null; do
  if [ "$(xdotool getactivewindow 2>/dev/null)" != "$win" ]; then
    kill "$ff" 2>/dev/null || true
    wait "$ff" 2>/dev/null || true
    rm -f "$raw"
    echo "Sober lost focus during the take; take deleted. Try again when the desktop is free." >&2
    exit 1
  fi
  sleep 0.25
done
wait "$ff"
restore
trap - EXIT

python3 "$here/tools/cut_movie.py" "$raw" "$out" --name "$name"
echo "raw take: $raw"
