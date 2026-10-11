"""Quality-check an interpolated video: how much softer are the synthesised frames?

Frame interpolation keeps the source frames and invents the ones in between, so a
2x result alternates original / interpolated / original / ... If the invented
frames carry much less high-frequency detail, playback pulses between crisp and
soft at fps/2, which viewers read as shimmer or ghosting - and it does NOT show up
in a spec check, only in the pixels.

This measures that gap and points at the worst frames so you know where to look.

Usage:
    python qc_interp.py <interpolated-video>

Interpreting the ratio (interpolated detail / original detail):
    >= 0.98   invented frames are visually indistinguishable on average
    0.95-0.98 subtle; verify fast motion by eye at 1:1, the loss concentrates on
              small fast parts (hands, faces) even when the average looks fine
    <  0.95   the pulsing will be visible; consider fewer interpolated frames,
              a different model, or re-rendering the source at the target fps

Needs ffmpeg/ffprobe on PATH plus Pillow and numpy. Run it with the interpreter
that ships alongside ComfyUI - scripts/probe-env.ps1 prints the exact path, and a
portable install keeps it at <root>\\python_embeded\\python.exe. A bare system
Python usually lacks Pillow/numpy.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image


def detail(path: Path) -> float:
    """Mean absolute luminance gradient: higher means more high-frequency content."""
    a = np.asarray(Image.open(path).convert("L"), np.float32)
    return float(np.abs(np.diff(a, axis=1)).mean() + np.abs(np.diff(a, axis=0)).mean())


def frame_count(video: Path) -> int:
    # .mkv carries no frame count in the header, so count by decoding.
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
                        "-show_entries", "stream=nb_read_frames",
                        "-of", "default=noprint_wrappers=1:nokey=1", str(video)],
                       capture_output=True, text=True)
    return int(r.stdout.strip() or 0)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    video = Path(sys.argv[1])
    if not video.exists():
        print(f"not found: {video}")
        return 2

    total = frame_count(video)
    if total < 3:
        print(f"only {total} frames; nothing to judge")
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        # Half size is plenty for a gradient measure and keeps this fast.
        subprocess.run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", str(video),
                        "-vf", "scale=iw/2:ih/2", str(tmp / "f%04d.png")], capture_output=True)
        frames = sorted(tmp.glob("f*.png"))
        if len(frames) < 3:
            print("could not extract frames")
            return 1

        scores = [detail(f) for f in frames]
        originals = np.array(scores[0::2], np.float32)
        invented = np.array(scores[1::2], np.float32)
        n = min(len(originals), len(invented))
        mean_o, mean_i = float(originals[:n].mean()), float(invented[:n].mean())
        ratio = mean_i / mean_o if mean_o else float("nan")

        print(f"video            : {video.name}")
        print(f"frames           : {len(scores)}  ({len(originals)} original, {len(invented)} interpolated)")
        print(f"detail original   : {mean_o:.4f}")
        print(f"detail interpolated: {mean_i:.4f}")
        print(f"ratio            : {ratio:.3f}   (1.000 = invented frames carry the same detail)")

        # Per-frame worst offenders, each compared with its neighbouring original.
        per = []
        for k in range(n):
            ref = (originals[k] + (originals[k + 1] if k + 1 < len(originals) else originals[k])) / 2
            if ref:
                per.append((invented[k] / ref, 2 * k + 1))
        per.sort()
        print("\nsoftest invented frames (output frame index : ratio):")
        for r, idx in per[:5]:
            print(f"  frame {idx:5d} : {r:.3f}")

        if ratio >= 0.98:
            print("\nverdict: invented frames are close to the originals on average.")
        elif ratio >= 0.95:
            print("\nverdict: subtle gap. The average hides the worst cases - crop the "
                  "softest frames above at 1:1 and compare against the adjacent "
                  "original before shipping.")
        else:
            print("\nverdict: visible pulsing. Reduce the multiplier, change the model, "
                  "or re-render the source at the target frame rate.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
