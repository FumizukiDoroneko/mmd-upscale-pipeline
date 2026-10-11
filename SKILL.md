---
name: mmd-upscale-pipeline
description: >-
  Resample and frame-interpolate MMD and other anime/CG videos to a target
  resolution and frame rate on a local ComfyUI + ffmpeg stack (RIFE interpolation
  plus Lanczos resample by default, with optional FlashVSR/SeedVR2 AI restoration
  for degraded sources), driven by a bundled batch script that discovers the
  install instead of assuming it. Use when the user wants to 补帧、超分、4K 化、
  提升帧率, or to batch-process their own video files. Not for general video
  editing, cloud/AI video generation, or subtitling.
---

# MMD video resample + frame interpolation

Local, offline, no per-use cost. Everything is installed; this skill is about
driving it without re-deriving the setup — and about picking the right path,
which is where a full day was once wasted.

**Platform: Windows.** The drivers are PowerShell and the verified setup is the
Windows ComfyUI portable build; only `qc_interp.py` is cross-platform. The design
itself is not Windows-specific — any ffmpeg + ComfyUI install would work — but
nothing here has been tested on macOS or Linux, so do not claim it runs there.

## Ask first: does the user control the render?

This user renders their own MMD material. When that is true, **rendering at the
target resolution and frame rate beats anything this pipeline can do** — a native
2160p60 render carries real detail and perfectly clean motion, while upscaling and
interpolation both invent information. Raise this before starting a long job; it has
already been the right answer twice (4K, then smoothness).

The pipeline is for masters whose project is gone, or when re-rendering is genuinely
not worth the time. It is not a substitute for a render setting the user controls.

## Pick the path by source quality — this is the whole ballgame

| Source | Restore stage | Why |
|---|---|---|
| **Clean render you made yourself** (MMD output, high bitrate, no visible blocking) | `-Restore none` (**default**) | There is no noise to clean and real detail already present. The AI re-imagines that detail and loses. |
| Compressed web rip, soft/blurry footage, low bitrate | `-Restore flashvsr` | This is what restoration models are for. |
| Same, but small or badly broken | `-Restore seedvr2` | Thrashes above ~1440p on a 12GB card. |

Measured on the reference machine (RTX 5070, 12GB) from a 1080p MMD render
upscaled to 1440p. Treat these as evidence for the trade-off, not as numbers your
machine will reproduce exactly:

| Version | High-frequency detail (Lanczos scale-up = 1.000) |
|---|---|
| Source, Lanczos to 1440p | 1.000 |
| **Interpolate + Lanczos + unsharp 0.7** | **0.921** |
| FlashVSR AI pipeline | 0.821 |

The AI pipeline came back **softer than plain resampling**, took **30 minutes
instead of 3**, flattened bright areas, added temporal flicker, and shifted content
~0.15 s. `-Restore none` is the default because it wins on every axis for clean
material.

Also measured: pre-downscaling the input before FlashVSR (an earlier default here,
because the generic `video-upscale` guidance says downscale first) cost real detail
on a clean render — 0.883 of reference versus 0.946 fed natively. The AI path now
always feeds native pixels and lets the final pass land on the target size.

**Resolution ceiling:** there is none on the `none` path — 4K is just a bigger
encode, seconds for a 15-second clip. From a 1080p source, though, 4K adds no real
detail (measured 0.909 versus 0.944 at 1440p, each relative to its own resolution),
so it is worth doing only when a delivery spec or a 4K display demands it. If the
user still has the MMD project, **re-rendering at 2160p is the only way to get
genuine 4K detail** — then use this pipeline for interpolation only.

## Step 1 on any machine: probe it, do not assume it

```powershell
.\scripts\probe-env.ps1
```

Read-only reconnaissance. It locates the ComfyUI install, its interpreter, the node
packs, the models, ffmpeg, the GPU and its VRAM, and the console code page — then
prints which jobs are actually possible plus a ready-to-run command. **Report the
findings to the user before starting a long job**, especially VRAM: it decides
segment sizes, whether an AI restore is realistic, and how far upscaling can go.
Missing pieces show up as explicit warnings rather than a confusing failure halfway
through a render.

Nothing in this skill hardcodes an install path. `mmd_upscale_batch.ps1` and
`launch-comfyui.ps1` both dot-source `scripts/comfy-env.ps1`, which searches
`COMFYUI_PATH` / `COMFYUI_CODE_PATH` / `COMFYUI_HOME`, the usual portable locations,
and any `ComfyUI*` folder directly under a drive root. It understands both the
portable layout (`<root>\ComfyUI\main.py` alongside `python_embeded`) and a source
install (`<root>\main.py` with a `.venv`). The input/output folders and the Python
interpreter come from whatever it finds; `-ComfyInput` / `-ComfyOutput` exist only
to override, for example when the server runs with a custom `--base-directory`.

| File | Role |
|---|---|
| `scripts/probe-env.ps1` | Environment report + which jobs are viable |
| `scripts/comfy-env.ps1` | Shared discovery helpers (dot-sourced, never run directly) |
| `scripts/launch-comfyui.ps1` | Start the discovered ComfyUI with the required env vars |
| `scripts/mmd_upscale_batch.ps1` | The batch driver |
| `scripts/qc_interp.py` | Interpolation quality check |
| `references/measurements.md` | Measurements from the reference machine |

## Running a job

```powershell
# the recommended shape: 1440p60, no AI, sharpened — minutes, not hours
.\scripts\mmd_upscale_batch.ps1 -InputDir 'D:\mmd renders' -OutputDir 'D:\mmd out' -TargetShortEdge 1440

# 4K costs nothing extra on this path
.\scripts\mmd_upscale_batch.ps1 -InputDir 'D:\mmd renders' -OutputDir 'D:\mmd 4k' -TargetShortEdge 2160

# interpolation only, resolution untouched
.\scripts\mmd_upscale_batch.ps1 -InputDir 'D:\mmd renders' -Mode interp

# AI restore, only for a degraded source
.\scripts\mmd_upscale_batch.ps1 -InputDir 'D:\web rips' -Restore flashvsr -TargetShortEdge 1440
```

How it works: the clip is cut into frame-exact segments via `VHS_LoadVideo`'s
`skip_first_frames` / `frame_load_cap`. Interpolation segments overlap by one frame
and the duplicated first frame of each later segment is dropped during assembly, so
the joined frame count is exactly what a single-shot interpolation produces
(verified: 60 frames gives 119). An AI restore adds an earlier pass; between passes
the script calls ComfyUI's `/free` so RIFE does not compete with ~6.5GB of model
weights. One final ffmpeg pass joins, resamples, sharpens, and muxes the
**original soundtrack** back in.

Flags: `-Mode both|upscale|interp`, `-Restore none|flashvsr|seedvr2`,
`-TargetShortEdge`, `-Multiplier`, `-Sharpen` (default 0.7, 0 disables),
`-SegmentFrames`, `-InterpSegmentFrames`, `-IntermediateCrf`, `-AudioOffsetMs`,
`-FinalCrf` (default 16; use 14 or lower for a 4K master), `-RifeModel`,
`-FlashVsrPreset`, `-FlashVsrUnloadModel`, `-Encode`, `-Downscale`,
`-KeepIntermediate`.

Measured on a 2160x3840 30fps 465-frame clip, 2x interpolation only
(`-Mode interp -InterpSegmentFrames 20 -IntermediateCrf 8`): 24 segments at
~20-25 s each, **10.1 minutes total**, output 2160x3840 60fps, 929 frames,
zero content offset.

## Non-negotiable operational details

1. **Launch with `scripts/launch-comfyui.ps1`, not the stock bat.** It sets
   `PYTHONUTF8=1` / `PYTHONIOENCODING=utf-8` / `PYTHONUNBUFFERED=1`. On any Windows
   install whose ANSI code page is not UTF-8 (the probe reports this — 936 and 1252
   are the common ones), Python's stdio defaults to the legacy code page, and node
   packs that log emoji during import (SeedVR2 does) abort ComfyUI at startup with
   `UnicodeEncodeError`. A stock `run_nvidia_gpu.bat` therefore fails; this launcher
   does not. It also refuses to start a second copy when one is already answering.
2. **`-Restore none` only needs ComfyUI for interpolation.** If the clip is already
   at the target frame rate, nothing but ffmpeg is involved.
3. **FlashVSR needs ≥21 input frames.** The script checks and fails with a clear
   message, so short clips get forced into ≥21-frame segments even when asked for
   less.
4. **The AI restore path shifts content ~8-10 output frames (0.13-0.17 s) EARLIER
   than the source** — measured −8 at two separate points, while the interpolation
   stage measured 0 offset. Any soundtrack will desync; use `-AudioOffsetMs` with a
   negative value (about -150) to pull the audio forward. `-Restore none` has no
   offset at all.
5. **The AI path at 4K thrashes on a 12GB card**: VRAM pegs ~11.5GB and GPU reads
   100% while power sits at 55-75W. bf16, tiling, `unload_model`, `/free` and the
   'Long Video (Low VRAM)' preset were all tried and none fixed it. Segmentation is
   necessary but not sufficient. Check the probed VRAM before offering AI restore
   above 1440p, and say plainly that it will be slow.
6. **`/interrupt` does not stop these nodes.** Kill the `python.exe` running
   `main.py` and relaunch.
7. **VHS's `video/nvenc_h264-mp4` format is broken on this build** (`OSError:
   [Errno 22]` while writing frames). The script defaults to libx264; encoding is
   not the bottleneck.
8. **Interpolating is where smoothness comes from, and it has a cost.** RIFE keeps
   the real frames and invents the ones between them, so a 2x result alternates
   crisp / soft. Measured on a real 4K clip: invented frames carry 0.964 of the
   originals' high-frequency detail on average, but the worst ones drop to ~0.83 -
   and the loss concentrates on small fast parts (hands, faces), which is what a
   viewer sees as ghosting. **If the user controls the render, rendering at the
   target frame rate is the only way to get perfectly clean motion**; interpolation
   is the fallback for a 30fps master whose project is gone. Say this before
   promising a "smooth" result.
9. **`rife_v4.26_heavy` measured identical to `rife_v4.26`** (ratio 0.976 both).
   Do not expect anything from it.
10. **FILM does not fit at 4K on this card.** `film_net_fp16.safetensors` is
    installed, but at 2160x3840 just 12 frames demanded 19.8GB against an 11.94GB
    limit - it builds multi-scale pyramids. It would need ~4-6 frame segments.
11. **The ComfyUI-Frame-Interpolation pack's ensemble path is unusable as
    installed**: its only checkpoint, `ckpts/rife426.pth`, is a training
    checkpoint (state_dict keys carry a `teacher.` prefix) and fails to load. The
    built-in `FrameInterpolate` node is what works here.
12. **`.mkv` outputs report `nb_frames=N/A`** - the frame count lives in the
    decoder, not the header. Use `ffprobe -count_frames` to verify it.

## Verify the output — specs are not quality

`ffprobe` for width/height, `r_frame_rate`, frame count and audio presence, then
check whether the picture actually improved. A run can be perfect on paper and
softer than the original; that is exactly how the AI path was caught. Compare
high-frequency detail: scale the source frame to the output resolution with Lanczos
and compare mean absolute luminance gradients (`references/measurements.md` has the
script). If the output scores below a plain scale-up, the pipeline is losing detail
and the restore stage is the usual culprit.

**For an interpolated result, run the bundled checker** — this is the failure that
spec checks cannot see:

```powershell
& (.\scripts\probe-env.ps1 -Json | ConvertFrom-Json).comfy.Python .\scripts\qc_interp.py <output.mkv>
```

(or simply run it with the interpreter the probe reported — a portable install keeps
it at `<root>\python_embeded\python.exe`; a bare system Python usually lacks
Pillow/numpy.)

It separates the original frames from the invented ones and reports how much detail
the invented ones carry, then lists the softest frames by index. The average is not
the number that matters: a real 4K job measured 0.964 overall while its worst
invented frames sat at ~0.83. Use the listed indices to crop those exact frames at
1:1 and compare against the adjacent original - if the hands or face go mushy
there, the result will pulse in motion no matter how good the average looks.

Then judge in motion at full speed, not from a still:

- **Line crawl / shimmer** on outlines — a per-frame upscaler causes it.
- **Ghosting or morphing** on fast limbs and half-transparent effects. Lower the
  multiplier, or re-render the source at the target rate (FILM is not an option at
  4K here - see the operational details).
- **Morphing across a cut** — split on scene cuts before interpolating.
- **Content offset** — check a known frame against the source before trusting
  audio sync.

## Background

Throughput numbers, model comparisons, the failure history and the open items are in
[references/measurements.md](references/measurements.md). Read it when tuning
performance, choosing a model, or when a run is unexpectedly slow.
