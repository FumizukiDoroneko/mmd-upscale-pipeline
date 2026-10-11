# Measured throughput and model choice

All numbers measured 2026-10-11 on this machine: RTX 5070 (12GB, sm_120),
ComfyUI portable v0.39.0, torch 2.14.0+cu130, 65GB RAM. Sources are synthetic
1080p30 clips (`ffmpeg testsrc2`) with an AAC track; times include the encode
unless stated as "model stage".

## Throughput

| Configuration | Result |
|---|---|
| RIFE ×2, 60 frames @1440p | ~1.5 s |
| SeedVR2 3B fp8 → 1440p, 0.5× downscale, batch 5, overlap 2, VAE tiled | 15 frames: 163 s (cold, includes model load, 3 batches at ~6.3 s each); 60 frames: 706 s → **5.1 source frames/min** |
| SeedVR2 3B fp8 → 4K | **Never completed.** 15 frames ran 4.5 min with VRAM 11.5-11.9GB and power collapsing 168W → 56W. A second attempt with `blocks_to_swap=16` started thrashing immediately (11.6GB / 63W). |
| FlashVSR 1.1, Balanced preset, 4× from 960×540 → 4K | 60 frames: model stage 377 s (7 chunks × 53.9 s) → 9.5 frames/min |
| FlashVSR 1.1, same, 24 frames | Model stage 13 s (2 chunks × 6.6 s); whole job incl. one-time model load, RIFE and encode: 384 s |

Per output pixel, FlashVSR is ~3.4× faster than SeedVR2 (63 vs 18.8 Mpx/min), and
it is the only one of the two that reaches 4K here.

Extrapolation for a 30fps source, model stage only:

- SeedVR2 → 1440p: 1 min video ≈ 5.9 h, 3 min ≈ 17.6 h
- FlashVSR → 4K: 1 min video ≈ 3.2 h, 3 min ≈ 9.5 h
- Interpolation alone: 3 min video ≈ 2 min

## Why the cost is superlinear in frame count

Chunk time went 6.6 s (24 frames) → 53.9 s (60 frames), and the chunk count also
grew. VRAM accounting at 4K:

- ComfyUI `IMAGE` tensors are float32: 24 frames × 3840×2160×3×4B ≈ 2.4GB, 60
  frames ≈ 6GB.
- FlashVSR's weights are fp32: FlashVSR1_1 5.4GB + LQ_proj 0.55GB + TCDecoder
  0.17GB + VAE 0.24GB ≈ 6.4GB.

Together that saturates 12GB, so the pipeline swaps. This is a VRAM ceiling, not a
tuning mistake — segmentation is the fix, not a parameter.

Where the tail time goes: during the phase after FlashVSR reports `7/7`, no
`ffmpeg.exe` process exists, so that time is RIFE at 4K (plus FlashVSR's VAE
decode), not the encode.

## What was tried and did not help

- `blocks_to_swap=16` with SeedVR2 at 4K: made it worse from the start.
- Downscale-first did help SeedVR2 a lot at 1440p — VRAM 11.6GB → 6.4GB, power
  63W → 167W. It is worth keeping for that model.
- `unload_model=true` on FlashVSR: **unproven.** One 24-frame run without it was
  killed at 4 min; the run with it finished at 384 s. Not a controlled comparison,
  so do not claim it helped.

## Two-pass + segmentation: what was verified

Implemented in the batch script after the measurements above. Verified on a 1080p
30fps source, target 1080p, so the numbers are cheap but the invariants are exact:

| Check | Result |
|---|---|
| Restore, 60 frames as 2 segments of 30, joined by stream copy | `restored.mp4` = **60 frames** (exact, no drift) |
| Interpolation, 24 frames as 3 segments (8+9+9) with 1-frame overlap | **47 frames** = 2×24−1, identical to single-shot interpolation |
| Interpolation, 60 frames as 3 segments (20+21+21) | **119 frames** = 2×60−1, artwork intact |
| Audio | original track muxed back; present in every output |
| `/free` between passes | works on this ComfyUI build; unloads the restore model |

Costs at 1080p, 60-frame clip, full run: 2 restore segments × 61s (model reload
dominates) + 3 interp segments × 8s + assembly ≈ 2.5 min.

Full run at **1440p**, same 60-frame clip: 2 restore segments (89s + 165s — the
second is slower, VRAM pressure accumulates) + 3 interp segments × 12s +
assembly ≈ **4.9 min**. Output verified 2560x1440, 60fps, 119 frames, AAC audio.

The pre-scale is computed as exact pixel dimensions (`ImageScale`), not as a
rounded factor: `ImageScaleBy 0.667` sent 1920x1080 to 1281x720 and the error
doubled to a 2562x1440 output. Verified geometry: 1080p → 2160 = 960x540 → 3840x2160;
1080p → 1440 = 1280x720 → 2560x1440; 1080p → 1080 = 960x540 → 1920x1080.

## 4K attempts that did not work

4K restore segments of 30 frames consistently land in the swapping regime
(VRAM ~11.5GB, GPU ~100% utilisation but only 55-75W, one 30-frame segment still
unfinished after 11 minutes). All of these were tried and none fixed it:

- `AILab_FlashVSR_Advanced` with `precision: bf16` (halves the fp32 weights).
- The same node with `enable_tiling: true`, `tile_size: 384`, `vae_tiling: true`.
- `unload_model: true` (frees the main model before VAE decode), also via
  ComfyUI's `/free` endpoint between passes.
- The `Long Video (Low VRAM)` preset.

One earlier run did report a 13s model stage for a single 24-frame 4K segment, and
that number could not be reproduced afterwards. **Do not quote it as an
expectation.** The reproducible behaviour at 4K on 12GB is thrashing.

Note that FlashVSR's 21-frame minimum also forces short clips into large segments:
a 60-frame clip asked for 24-frame segments still produces 2 × 30, because 3 × 20
would be below the minimum. Only longer clips actually get ~24-frame segments.

## Bugs found while building this (already fixed, do not reintroduce)

- **VHS + nvenc is broken on this build.** `format: video/nvenc_h264-mp4` dies with
  `OSError: [Errno 22] Invalid argument` while writing frames to ffmpeg, even
  though libx264 through the same node works. `-Encode` therefore defaults to
  `h264`. Encoding is not the bottleneck, so this costs little.
- **`-shortest` silently ate a frame.** Muxing audio with `-shortest` trims the
  output to the shorter stream, and the AAC track is routinely a hair shorter than
  the video: 60 frames became 59. Mux by trimming the audio to the video's
  duration instead.
- **PowerShell unrolls single-element arrays returned from functions.** Twice:
  `$produced[0]` became the letter `D` of `D:\...`, and a one-segment result had
  its own `.Count` property (24) read as the segment count. Wrap such calls in
  `@(...)`, and normalise inside helpers.

## Open items

- **SageAttention** (`pip install sageattention triton`): the node exposes a
  `sageattention` switch and the README claims ~20-30%. Deliberately not
  installed: PyPI ships no Windows wheel for `sageattention` (only a py3-none-any
  wrapper plus sdist) and no Windows `triton`, so it needs a third-party triton
  fork and a source build against torch 2.14 / CUDA 13 / sm_120. The expected
  end-to-end gain is ~1%, because in the recommended configuration the FlashVSR
  model stage is a small slice of wall time and the workload is memory-bound.
- Investigate the 4K memory behaviour properly (VRAM attribution per phase) before
  promising 4K on this card.
- `film_net_fp16.safetensors` as a RIFE alternative for large-motion shots.
- FlashVSR `High Quality (Best)` preset (Full model) — untested, much heavier VRAM.

## Network notes (these cost real time to rediscover)

- HuggingFace is unreachable directly from this network (0 MB/s). `hf-mirror.com`
  works well: pass it to the launcher (`.\scripts\launch-comfyui.ps1 -HfEndpoint
  https://hf-mirror.com`), which exports it as `HF_ENDPOINT` for the node packs.
  This is network-specific, so it is a flag rather than a default.
- GitHub release downloads are ~0 MB/s directly. `https://gh-proxy.com/<github-url>`
  measured 24.8 MB/s; the system proxy at `127.0.0.1:7890` only gave 2.2 MB/s for
  the same file, so prefer the mirror.
- When launching a process that carries a URL inline, the sandbox may block the
  command; put the URL in the launcher script or config file instead.

## Second session: the AI restore lost to Lanczos on a real render

First run on real user material: a 1080p30, 15.5 s, 465-frame MMD render, targeted
at 1440p60. The user's verdict was "the upscale is actually blurrier, and all three
artefacts are there". Measuring confirmed it.

### Detail energy (mean absolute luminance gradient, matched frames)

Everything compared at 2560x1440, with the source scaled up by Lanczos as the
reference, so a value below 1.000 means the pipeline carries less high-frequency
content than a plain scale-up:

| Version | Ratio vs Lanczos | Notes |
|---|---|---|
| source -> Lanczos 1440p | 1.000 | but this also preserves the source's own compression noise |
| interpolate + Lanczos | 0.820 | two lossy encodes plus RIFE |
| **interpolate + Lanczos + unsharp 0.7** | **0.921** | the version the user accepted |
| FlashVSR AI pipeline | 0.823 | 30 minutes, and no sharper |

Honest caveat: gradient energy cannot separate real detail from compression noise,
and the source is a 7.4 Mbps H.264 file whose blocking inflates the reference. So
these numbers say the pipeline output is *smoother*, not necessarily that it lost
structure. The user's eye and the visual crops are what settled it.

### The pre-downscale was the one clearly wrong knob

Isolated A/B on a 24-frame window (source 1080p, target 1440p), each ratio against a
Lanczos reference at its own output resolution:

| FlashVSR input | Ratio | Wall time for 24 frames |
|---|---|---|
| pre-scaled to 720p (old default) | 0.883 | 84 s |
| **native 1080p, 2x, then downscale the 2160p result to 1440p** | **0.946** | 139 s |

Feeding native pixels and supersampling back down costs 1.65x the time and buys
~7 points of detail. The script now always feeds native pixels; the pre-scale exists
only for SeedVR2.

### Where the content offset comes from

| Run | Offset vs source |
|---|---|
| Interpolation stage alone (whole 465-frame clip) | **0 frames** |
| Restore stage alone (24-frame segment) | **0 frames** |
| Full AI pipeline | **-8 output frames** consistently at t=5 s and t=10 s |

So the offset appears only when the restore pass runs as part of the whole clip, and
it is a constant lag rather than drift. Not yet root-caused; `-AudioOffsetMs` exists
to compensate it, and the non-AI path does not exhibit it.

### 4K on the non-AI path

Because it is plain ffmpeg there is no VRAM limit: 929 frames of 4K60 encoded in
~20 s. But from a 1080p source it is a 2x interpolation, so it carries no more real
detail — 0.944 at 1440p versus 0.909 at 2160p relative to their own references. The
4K is for delivery specs and 4K displays, not for sharpness. Genuine 4K detail for
MMD means re-rendering the project at 2160p and using this pipeline only to
interpolate.

### Timings on the real clip

| Job | Wall time |
|---|---|
| AI pipeline, 465 frames to 1440p60 | 30.0 min |
| Interpolation only + Lanczos 1440p + unsharp | 2.8 min |
| Resample-only 4K60 encode of the result | ~20 s |

### What changed in the script because of this

- `-Restore` defaults to `none`; the AI models are opt-in for degraded sources.
- The FlashVSR path never pre-downscales; it feeds native pixels and the final pass
  lands on the exact target size.
- `-Sharpen` (default 0.7) and the Lanczos resample moved into the final ffmpeg
  pass, which is where they belong: no VRAM, no model, any resolution.
- `-IntermediateCrf` and `-AudioOffsetMs` added.
- Verified after the change: 1080p -> 1440p60 (2560x1440, 47 frames, audio),
  resample-only 1080p -> 2160p (3840x2160, 24 frames, audio), and the AI path
  (native 4x supersample then 2560x1440) all produce the expected geometry.

## Third session: a native 4K source, interpolation only

The user re-rendered the same material at 2160x3840 (portrait 4K), so no upscaling
was involved: `-Mode interp -InterpSegmentFrames 20 -IntermediateCrf 8` on a
2160x3840 30fps, 465-frame, 24.5 Mbps, audio-less clip.

| Metric | Result |
|---|---|
| Wall time | **10.1 min** (24 segments, 20-25 s each) |
| Output | 2160x3840 60fps, **929 frames** exactly (2x465-1), 15.484 s, 48.1 MB |
| Container | matroska (verified - the earlier MP4-in-a-.mkv bug is gone) |
| Content offset | **0 frames** (SSIM peak 0.960 at the match, 0.844/0.828 either side) |

### The interpolated frames are softer, and it is worst on hands and faces

`scripts/qc_interp.py` splits the output into original frames and invented ones and
compares high-frequency detail:

- whole clip: original 1.4705, invented 1.4179 -> **ratio 0.964**
- worst invented frames: index 515 (0.827), 903 (0.832), 905 (0.842), 517 (0.859),
  907 (0.868)

So the average conceals a 17% loss at specific moments, and those indices cluster -
they are the fast-motion beats. Cropping 340x340 at 1:1 around the hands and face at
frame 420 (original) versus 421 (invented) made it obvious: crisp finger joints and
glossy eye detail become a smear on the invented frame. At 60fps that is a 30Hz
crisp/soft alternation, which reads as shimmer or ghosting.

Nothing tried fixed it:

- `rife_v4.26_heavy`: ratio 0.976 on a 12-frame window, **identical** to
  `rife_v4.26` (0.976). No benefit.
- **FILM** (`film_net_fp16.safetensors`, designed for large motion): OOM at
  **12 frames** of 2160x3840 - 17.82 GiB already allocated, 1.98 GiB more requested,
  11.94 GiB device limit. It builds multi-scale pyramids. Viable only at roughly
  4-6 frame segments, which multiplies segment count and overhead.
- **ComfyUI-Frame-Interpolation's `RIFE VFI`** (which has an `ensemble` switch):
  fails to load its only checkpoint. `ckpts/rife426.pth` is a training checkpoint -
  the state_dict carries a `teacher.` prefix - so the node errors before inference.
  Trying `rife47.pth`/`rife49.pth` would need the correct inference weight fetched
  from upstream; unverified.

### The conclusion that matters more than any knob

Because the user renders this material themselves, **rendering at 60fps is the only
way to get perfectly clean motion** - interpolation is a fallback for a 30fps master
whose project is gone. The same logic already applied to resolution (render 2160p
instead of upscaling); it applies to frame rate too. The pipeline is worth running
when the project is unavailable, not as a substitute for a render setting the user
controls.
