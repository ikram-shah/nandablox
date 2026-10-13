#!/usr/bin/env python3
"""Cut a raw full-screen recording of the movie place into the finished media.

The movie marks its own crop and its own start: during the pre-roll its 16:9
frame is black and the rest of the viewport magenta (Movie.luau). This script

  1. scans the recording at low resolution for the magenta pre-roll,
  2. finds the exact frame rectangle (black inside magenta) in one full-res frame,
  3. starts 0.3 s before the last pre-roll frame (still black inside the crop),
  4. ends 0.3 s after the closing fade to black,
  5. writes a 1920x1080 H.264 MP4 (yuv420p, +faststart, silent), a 720p copy
     under 16 MB for WhatsApp, and a poster PNG from the verdict hold.

A frame that is already 1920x1080 (cinema mode in the Sober client, fullscreen
at 1920x1200: the frame is the full width, below the Roblox menu button) is
cropped exactly and not rescaled; any other size (Studio's viewport) is
scaled to 1080p.

  cut_movie.py RAW.mkv OUTDIR [--name nanda-town-replay]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

SW, SH = 480, 300  # analysis size (the screen is 1920x1200)
FPS = 30


def probe(path: Path) -> dict:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height,r_frame_rate,nb_frames:format=duration", "-of", "json", str(path)],
        check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def frames_small(path: Path):
    """Yield every frame at SWxSH as uint8 HxWx3."""
    p = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-i", str(path), "-vf", f"scale={SW}:{SH}:flags=area",
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    n = SW * SH * 3
    while True:
        b = p.stdout.read(n)
        if len(b) < n:
            break
        yield np.frombuffer(b, np.uint8).reshape(SH, SW, 3)
    p.wait()


def frame_full(path: Path, index: int) -> np.ndarray:
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-vf", f"select=eq(n\\,{index})", "-frames:v", "1",
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], check=True, capture_output=True).stdout
    return np.frombuffer(out, np.uint8).reshape(1200, 1920, 3)


def magenta(a: np.ndarray) -> np.ndarray:
    r, g, b = (a[..., i].astype(int) for i in range(3))
    return (r > 200) & (b > 200) & (g < 60)


def black(a: np.ndarray) -> np.ndarray:
    return a.max(axis=-1) < 24


def find_rect(full: np.ndarray) -> tuple[int, int, int, int]:
    """The black rectangle inside the magenta viewport: (x, y, w, h), even sizes."""
    m = magenta(full)
    ys, xs = np.nonzero(m)
    if len(xs) == 0:
        raise SystemExit("no magenta in the pre-roll frame")
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    view = full[y0:y1 + 1, x0:x1 + 1]
    bk = black(view)
    rows = np.nonzero(bk.mean(axis=1) > 0.5)[0]
    cols = np.nonzero(bk.mean(axis=0) > 0.5)[0]
    ow, oh = cols.max() - cols.min() + 1, rows.max() - rows.min() + 1
    if abs(ow - 1920) <= 4 and abs(oh - 1080) <= 4:
        # a native 1080p frame (the Sober client fullscreen at 1920x1200, cinema
        # mode): take exactly 1920x1080 of it, centred, so nothing is rescaled
        fx0 = int(cols.min()) + (ow - 1920) // 2
        fy0 = int(rows.min()) + (oh - 1080) // 2
        fx0 = max(0, min(fx0, full.shape[1] - 1920 - int(x0)))
        return int(x0 + fx0), int(y0 + fy0), 1920, 1080
    # 2 px inside the black, so no magenta fringe survives compression
    fy0, fy1, fx0, fx1 = rows.min() + 2, rows.max() - 2, cols.min() + 2, cols.max() - 2
    w = (fx1 - fx0 + 1) // 2 * 2
    h = (fy1 - fy0 + 1) // 2 * 2
    return int(x0 + fx0), int(y0 + fy0), int(w), int(h)


def run(*cmd: str) -> None:
    subprocess.run(cmd, check=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("raw", type=Path)
    ap.add_argument("outdir", type=Path)
    ap.add_argument("--name", default="nanda-town-replay")
    a = ap.parse_args()
    a.outdir.mkdir(parents=True, exist_ok=True)

    # 1. scan: magenta share of the screen, and the frames themselves (small)
    mag, blk, small = [], [], []
    for f in frames_small(a.raw):
        mag.append(magenta(f).mean())
        blk.append(black(f).mean())
        small.append(f)
    mag, blk = np.array(mag), np.array(blk)
    # pre-roll: some magenta, and most of the rest one big black frame
    pre = np.nonzero((mag > 0.02) & (blk > 0.3) & (mag + blk > 0.5))[0]
    if len(pre) == 0:
        raise SystemExit("no magenta pre-roll found: did the movie place play?")
    # the pre-roll is one contiguous run; take the last run if there are several
    runs = np.split(pre, np.nonzero(np.diff(pre) > 1)[0] + 1)
    pre_run = runs[-1]
    last_pre = int(pre_run[-1])
    print(f"pre-roll frames {pre_run[0]}..{last_pre} ({len(pre_run) / FPS:.2f} s)")

    # 2. the crop, from a full-resolution pre-roll frame
    x, y, w, h = find_rect(frame_full(a.raw, int(pre_run[len(pre_run) // 2])))
    print(f"frame rect x={x} y={y} w={w} h={h} (aspect {w / h:.4f})")

    # 3-4. start and end inside the crop
    sx, sy, sw, sh = (int(round(v / 4)) for v in (x, y, w, h))
    luma = np.array([f[sy:sy + sh, sx:sx + sw].mean() for f in small])
    start = last_pre - 8
    if luma[start:last_pre + 1].max() > 6:
        raise SystemExit("crop is not black at the start of the cut")
    after = start + 30 * FPS
    dark = np.nonzero(luma[after:] < 3)[0]
    if len(dark) == 0:
        raise SystemExit("no closing fade to black found: record longer")
    fade_end = after + int(dark[0])
    end = min(fade_end + 9, len(small) - 1)
    n = end - start + 1
    print(f"cut frames {start}..{end}: {n} frames, {n / FPS:.2f} s")

    # duplicated consecutive frames while things move = dropped capture frames
    moving = np.array([np.abs(small[i].astype(int) - small[i - 1].astype(int)).mean()
                       for i in range(start + 1, end + 1)])
    print(f"identical consecutive frames in the cut: {(moving == 0).sum()} of {n - 1}")

    # 5. encode
    mp4 = a.outdir / f"{a.name}.mp4"
    wa = a.outdir / f"{a.name}-720p.mp4"
    poster = a.outdir / f"{a.name}-poster.png"
    trim = f"trim=start_frame={start}:end_frame={end + 1},setpts=PTS-STARTPTS,crop={w}:{h}:{x}:{y}"
    native = (w, h) == (1920, 1080)
    print("native 1920x1080 crop, no rescale" if native else f"rescaling {w}x{h} to 1920x1080")
    scale = "" if native else "scale=1920:1080:flags=lanczos,"
    run("ffmpeg", "-v", "error", "-y", "-i", str(a.raw), "-vf",
        f"{trim},{scale}format=yuv420p", "-an", "-c:v", "libx264", "-preset", "slow",
        "-crf", "18", "-r", str(FPS), "-movflags", "+faststart", str(mp4))
    for crf in (24, 27, 30):
        run("ffmpeg", "-v", "error", "-y", "-i", str(mp4), "-vf", "scale=1280:720:flags=lanczos,format=yuv420p",
            "-an", "-c:v", "libx264", "-preset", "slow", "-crf", str(crf), "-movflags", "+faststart", str(wa))
        if wa.stat().st_size < 15.5e6:
            break
    # poster: the verdict hold, 1.2 s before the closing fade starts (fade is 0.8 s)
    pt = (fade_end - start) / FPS - 0.8 - 1.2
    run("ffmpeg", "-v", "error", "-y", "-ss", f"{pt:.3f}", "-i", str(mp4), "-frames:v", "1", str(poster))

    for p in (mp4, wa, poster):
        info = probe(p) if p.suffix == ".mp4" else None
        dur = float(info["format"]["duration"]) if info else 0
        print(f"{p}  {p.stat().st_size / 1e6:.2f} MB" + (f"  {dur:.2f} s" if info else ""))
    json.dump({"rect": [x, y, w, h], "start_frame": start, "end_frame": end, "fps": FPS,
               "poster_t": pt}, open(a.raw.with_suffix(".cut.json"), "w"), indent=1)


if __name__ == "__main__":
    sys.exit(main())
