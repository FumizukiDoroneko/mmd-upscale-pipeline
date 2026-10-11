<#
.SYNOPSIS
  Resample + frame-interpolate MMD (and other anime/CG) video to a target
  resolution and frame rate, on a local ComfyUI install. No per-use cost.

  Default path is deliberately NON-AI: interpolate at native resolution, then
  resample with Lanczos and optionally sharpen. See "Which path to use" below.

.DESCRIPTION
  Two stages, and long clips are processed in frame-exact segments:

    Pass 1  restore + upscale   OPTIONAL, only with -Restore flashvsr/seedvr2.
                                VHS_LoadVideo (frame range) -> FlashVSR -> encode.
                                Segments are concatenated with stream copy (frame
                                counts match exactly, so no re-encode, no drift).

    Pass 2  interpolation       Segments overlap by one frame, and the first
                                frame of every later segment is dropped during
                                assembly. That makes the joined frame count exact
                                (verified: a 60-frame clip gives 119 frames, the
                                same as interpolating it in one shot).

    Assembly                    One ffmpeg pass joins the segments, resamples to
                                the target size, sharpens if asked, and muxes the
                                ORIGINAL audio back in.

  Which path to use:

    -Restore none (default)  for CLEAN sources such as your own MMD renders.
        Measured on a real 1080p MMD render: the AI restore came back with LESS
        detail than a plain Lanczos scale-up (0.856 vs 1.040 high-frequency
        energy, i.e. 18% softer), while costing 30 minutes instead of 3, flattening
        bright areas, adding temporal flicker and shifting content ~0.15 s. On a
        clean CG render there is nothing to restore - the model only re-imagines
        detail that was already there, and loses.

    -Restore flashvsr        for genuinely DEGRADED sources - compressed web
        rips, soft footage, low bitrate. It needs >= 21 frames per segment.

    -Restore seedvr2         same use case; thrashes above ~1440p on a 12GB card.

  Why segments: at 4K the AI models' float32 frame tensors are enormous (24 frames
  ~2.4GB, 60 frames ~6GB) and FlashVSR's weights add ~6.5GB, so cost grows
  superlinearly with frame count (measured 6.6s/chunk at 24 frames vs 53.9s/chunk
  at 60). The non-AI path has no such limit - it runs at encoder speed.

  Interpolating is cheap either way (60 frames in ~1.5 s); the restore stage is
  what costs hours, which is why it is now opt-in.

  ComfyUI must already be running - start it with scripts/launch-comfyui.ps1,
  which sets PYTHONUTF8=1. On a Windows install whose ANSI code page is not UTF-8,
  the node packs log emoji at import and abort ComfyUI outright without it.

  No install path is hardcoded: the ComfyUI location and its input/output folders
  come from scripts/comfy-env.ps1, and the interpolation segment size is derived
  from the detected VRAM and the clip's real frame size.

.EXAMPLE
  # the recommended job: 1440p60, no AI, sharpened
  .\mmd_upscale_batch.ps1 -InputDir 'D:\mmd renders' -OutputDir 'D:\mmd out' -TargetShortEdge 1440

  # 4K costs nothing extra on this path
  .\mmd_upscale_batch.ps1 -InputDir 'D:\mmd renders' -OutputDir 'D:\mmd 4k' -TargetShortEdge 2160

  # interpolation only, untouched resolution
  .\mmd_upscale_batch.ps1 -InputDir 'D:\mmd renders' -Mode interp

  # AI restore, only for a degraded source
  .\mmd_upscale_batch.ps1 -InputDir 'D:\web rips' -Restore flashvsr -TargetShortEdge 1440
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputDir,

    [string]$OutputDir = "$PSScriptRoot\upscaled",

    [ValidateSet('both', 'upscale', 'interp')]
    [string]$Mode = 'both',

    # Restore stage.
    #   none     - no AI at all. Interpolate at native resolution, then resample
    #              (and optionally sharpen) in the final ffmpeg pass.
    #   flashvsr - AI restore. Reaches 4K; needs ~21 frames minimum; introduces a
    #              measured ~8-10 frame content lead and flattening of bright
    #              areas.
    #   seedvr2  - AI restore, thrashes above ~1440p output on a 12GB card.
    #
    # 'none' is the DEFAULT deliberately. On a real clean MMD render the AI
    # restore came back SOFTER than a plain Lanczos scale-up (measured 0.856 vs
    # 1.040 detail energy, i.e. 18% less high-frequency content) while costing
    # 30 minutes instead of 3 and adding highlight flattening, temporal flicker
    # and content drift. AI restoration earns its keep on genuinely degraded
    # sources - compressed web rips, soft or low-resolution footage - not on a
    # clean CG render that already carries real detail.
    [ValidateSet('none', 'flashvsr', 'seedvr2')]
    [string]$Restore = 'none',

    # Target resolution of the SHORTEST edge in pixels. 2160 => 4K for 16:9.
    # With -Restore none this is reached by resampling in the final pass, so it
    # costs nothing extra; with an AI restore it is reached by the model.
    [int]$TargetShortEdge = 2160,

    # Unsharp amount applied in the final pass. 0 disables. 0.7 is the value
    # validated on the real MMD render (detail energy 0.921 of a Lanczos
    # reference, versus 0.821 for the AI path, with no visible halo on line art).
    [double]$Sharpen = 0.7,

    # Frame-rate multiplier for RIFE. 2 => 30fps becomes 60fps.
    [int]$Multiplier = 2,

    # Frames per restore segment. Ignored when the clip is shorter.
    [int]$SegmentFrames = 30,

    # Frames per interpolation segment. 0 (the default) derives it from real VRAM
    # and the actual frame size - RIFE materialises the input and the interpolated
    # output at once, so a 4K clip needs far smaller segments than a 1080p one.
    # Set a positive value to override.
    [int]$InterpSegmentFrames = 0,

    # h264 (libx264) is the default: encoding is NOT the bottleneck here, and on
    # this build VHS's 'video/nvenc_h264-mp4' path dies with `OSError: [Errno 22]`
    # while writing frames to ffmpeg. The nvenc value is kept only for retrying
    # after that VHS/ffmpeg issue is fixed.
    [ValidateSet('h264', 'nvenc')]
    [string]$Encode = 'h264',

    # Quality of the per-segment intermediate encodes. Their frames get decoded
    # again for the final assembly, so this is generation loss; lower is better
    # but bigger. 0 means lossless-ish (very large files).
    [int]$IntermediateCrf = 12,

    # Quality of the final assembly encode (and of any resample). 16 is visually
    # transparent for this content at 1440p; for a 4K source where generations
    # matter, 14 or lower is reasonable.
    [int]$FinalCrf = 16,

    # Offset applied to the audio when muxing, in milliseconds.
    # The AI restore path was measured to shift picture content ~8-10 output
    # frames (0.13-0.17 s) EARLIER than the source, which desyncs a soundtrack.
    # -Restore none measured zero offset. If you do use an AI restore on a clip
    # with audio, try about -150 here to pull the audio back in line.
    [int]$AudioOffsetMs = 0,

    # FlashVSR preset. 'Long Video (Low VRAM)' is the one to reach for when a 4K
    # run thrashes; 'Balanced (2x Quality)' is the faster default at 1440p and
    # below. See references/measurements.md.
    [string]$FlashVsrPreset = 'Balanced (2x Quality)',
    # Frees the main model from VRAM before the VAE decodes the upscaled frames.
    # Defaults to false because the measured-good configuration kept the model
    # resident across segments (reloading it per segment costs ~60s each) and the
    # pass handoff is handled by /free. Set true only to chase down an OOM.
    [bool]$FlashVsrUnloadModel = $false,

    # SeedVR2 only: downscale factor applied before the restorer.
    [double]$Downscale = 0.5,
    [int]$BatchSize = 5,
    [int]$BlocksToSwap = 16,
    [int]$TemporalOverlap = 2,

    [string]$DitModel = 'seedvr2_ema_3b_fp8_e4m3fn.safetensors',
    [string]$VaeModel = 'ema_vae_fp16.safetensors',
    [string]$RifeModel = 'rife_v4.26.safetensors',

    [string]$ComfyUrl = 'http://127.0.0.1:8188',
    # Left empty on purpose: both are discovered from the ComfyUI install found on
    # this machine (see scripts/comfy-env.ps1). Pass them only to override, e.g.
    # when the server runs with a custom --base-directory.
    [string]$ComfyInput = '',
    [string]$ComfyOutput = '',

    [string[]]$Extensions = @('.mp4', '.mkv', '.mov', '.avi', '.webm'),

    # Per segment, not per clip - segments are deliberately small.
    [int]$PerSegmentTimeoutMin = 45,

    # Keep the per-segment files and the restored intermediate for inspection.
    [switch]$KeepIntermediate
)

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'comfy-env.ps1')

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) }

function Invoke-Ffmpeg {
    param([string[]]$FfArgs, [string]$What)
    $out = & ffmpeg -hide_banner -loglevel error -y @FfArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("{0} failed (ffmpeg exit {1}): {2}" -f $What, $LASTEXITCODE, ($out -join ' '))
    }
}

function Get-VideoFps([string]$Path) {
    $raw = & ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate `
        -of default=noprint_wrappers=1:nokey=1 $Path 2>$null
    if (-not $raw) { return 30.0 }
    $parts = $raw.Trim() -split '/'
    if ($parts.Count -eq 2 -and [double]$parts[1] -ne 0) {
        return [math]::Round(([double]$parts[0] / [double]$parts[1]), 3)
    }
    return [double]$raw
}

function Get-VideoDims([string]$Path) {
    $raw = & ffprobe -v error -select_streams v:0 -show_entries stream=width,height `
        -of csv=p=0 $Path 2>$null
    if (-not $raw) { return [pscustomobject]@{ Width = 1920; Height = 1080 } }
    $dims = ($raw.Trim() -split ',')
    if ($dims.Count -lt 2) { return [pscustomobject]@{ Width = 1920; Height = 1080 } }
    return [pscustomobject]@{ Width = [int]$dims[0]; Height = [int]$dims[1] }
}

function Get-EvenInt([double]$Value) {
    $n = [int][math]::Round($Value)
    if ($n % 2 -ne 0) { $n++ }
    return [math]::Max(2, $n)
}

function Get-VideoFrameCount([string]$Path) {
    $raw = & ffprobe -v error -select_streams v:0 -count_frames `
        -show_entries stream=nb_read_frames -of default=noprint_wrappers=1:nokey=1 $Path 2>$null
    if ($raw -and $raw.Trim() -match '^\d+$') { return [int]$raw.Trim() }
    return 0
}

# Even, frame-exact segments. Never emits a final stub shorter than $MinFrames:
# FlashVSR needs >= 21 frames, and a short tail segment would fail deep inside it.
function Get-Segments {
    param([int]$Total, [int]$Target, [int]$MinFrames)
    if ($Total -le 0) { return @() }
    if ($Target -le 0 -or $Total -le $Target) { return @([pscustomobject]@{ Start = 0; Count = $Total }) }

    $n = [int][math]::Ceiling($Total / [double]$Target)
    while ($n -gt 1 -and [math]::Floor($Total / [double]$n) -lt $MinFrames) { $n-- }

    $segments = @()
    $start = 0
    for ($i = 0; $i -lt $n; $i++) {
        $end = if ($i -eq $n - 1) { $Total } else { [int][math]::Round($Total * ($i + 1) / [double]$n) }
        $segments += [pscustomobject]@{ Start = $start; Count = $end - $start }
        $start = $end
    }
    return $segments
}

# FlashVSR only scales by an integer factor of 2 or 4.
#
# This used to pre-downscale the source so that a factor landed exactly on the
# target. That was WRONG for clean renders: it threw away real detail before the
# model ever saw it. Measured on a 1080p MMD render -> 1440p: pre-scaling to 720p
# left 0.883 of a Lanczos reference's detail, feeding native 1080p and letting the
# final pass downscale the 2160p result back to 1440p left 0.946. So: never
# downscale the input. Pick the smallest integer factor that reaches the target,
# feed native pixels, and let the final assembly land on the exact requested size;
# a downscale there is then a harmless supersample rather than a loss.
function Resolve-FlashVsrScale {
    param([int]$SrcShort, [int]$Target)
    if ($SrcShort -le 0) { $SrcShort = 1080 }
    # Smallest factor in {2,4} that actually reaches the target; 2x is cheaper
    # than 4x, so only jump to 4x when 2x falls short.
    if (($SrcShort * 2) -ge $Target) { return 2 }
    return 4
}

# Even output dimensions for the final resample: the requested short edge exactly,
# the long edge derived from the source aspect ratio. Rounded dimensions matter -
# scaling by a raw factor like 0.667 sent 1920x1080 to 1281x720 and the error
# doubled through the upscale, producing 2562x1440 instead of 2560x1440.
function Resolve-ResampleSize {
    param([int]$Target, [int]$SrcWidth, [int]$SrcHeight)
    if ($SrcWidth -le 0) { $SrcWidth = 1920 }
    if ($SrcHeight -le 0) { $SrcHeight = 1080 }
    if ($SrcWidth -ge $SrcHeight) {
        $outHeight = Get-EvenInt $Target
        $outWidth = Get-EvenInt ($Target * $SrcWidth / $SrcHeight)
    }
    else {
        $outWidth = Get-EvenInt $Target
        $outHeight = Get-EvenInt ($Target * $SrcHeight / $SrcWidth)
    }
    return [pscustomobject]@{ Width = $outWidth; Height = $outHeight }
}

function New-CodecArgs {
    param([string]$Kind, [string]$Quality, [string]$PixFmt)
    if ($Kind -eq 'nvenc') {
        $bitrate = if ($Quality -eq 'high') { 100 } else { 60 }
        return @{ Format = 'video/nvenc_h264-mp4'; Extra = @{
            pix_fmt = $PixFmt; bitrate = $bitrate; megabit = $true; save_metadata = $true } }
    }
    $crf = if ($Quality -eq 'high') { $IntermediateCrf } else { 16 }
    return @{ Format = 'video/h264-mp4'; Extra = @{
        pix_fmt = $PixFmt; crf = $crf; save_metadata = $true; trim_to_audio = $false } }
}

function New-RestoreWorkflow {
    param($Segment, [string]$File, [string]$Prefix, [double]$SrcFps,
          [string]$RestoreMode, [double]$DownscaleFactor, [int]$FlashScale, $Codec)

    $wf = [ordered]@{}
    $wf['1'] = @{ class_type = 'VHS_LoadVideo'; inputs = @{
        video = $File; force_rate = 0; custom_width = 0; custom_height = 0
        frame_load_cap = $Segment.Count; skip_first_frames = $Segment.Start; select_every_nth = 1 } }

    $last = @('1', 0)
    # Only SeedVR2 still takes an optional pre-scale (it is the one model whose
    # target short edge must be reached in-model). FlashVSR is fed native pixels.
    if ($RestoreMode -eq 'seedvr2' -and $DownscaleFactor -ne 1) {
        $wf['2'] = @{ class_type = 'ImageScaleBy'; inputs = @{
            image = $last; upscale_method = 'area'; scale_by = $DownscaleFactor } }
        $last = @('2', 0)
    }

    if ($RestoreMode -eq 'flashvsr') {
        $wf['3'] = @{ class_type = 'AILab_FlashVSR'; inputs = @{
            frames       = $last
            preset       = $FlashVsrPreset
            scale        = $FlashScale
            unload_model = $FlashVsrUnloadModel
            seed         = 1234 } }
        $last = @('3', 0)
    }
    else {
        $wf['3'] = @{ class_type = 'SeedVR2LoadDiTModel'; inputs = @{
            model = $DitModel; device = 'cuda:0'; blocks_to_swap = $BlocksToSwap
            offload_device = 'cpu'; attention_mode = 'sdpa' } }
        $wf['4'] = @{ class_type = 'SeedVR2LoadVAEModel'; inputs = @{
            model = $VaeModel; device = 'cuda:0'; encode_tiled = $true; decode_tiled = $true
            offload_device = 'cpu' } }
        $wf['5'] = @{ class_type = 'SeedVR2VideoUpscaler'; inputs = @{
            image = $last; dit = @('3', 0); vae = @('4', 0); seed = 1234
            resolution = $TargetShortEdge; max_resolution = 0; batch_size = $BatchSize
            uniform_batch_size = $false; color_correction = 'lab'
            temporal_overlap = $TemporalOverlap; prepend_frames = 2; offload_device = 'cpu' } }
        $last = @('5', 0)
    }

    $encodeInputs = [ordered]@{}
    $encodeInputs['images'] = $last
    $encodeInputs['frame_rate'] = $SrcFps
    $encodeInputs['loop_count'] = 0
    $encodeInputs['filename_prefix'] = $Prefix
    $encodeInputs['format'] = $Codec.Format
    foreach ($k in $Codec.Extra.Keys) { $encodeInputs[$k] = $Codec.Extra[$k] }
    $encodeInputs['pingpong'] = $false
    $encodeInputs['save_output'] = $true

    $wf['9'] = @{ class_type = 'VHS_VideoCombine'; inputs = $encodeInputs }
    return $wf
}

function New-InterpWorkflow {
    param($Segment, [string]$File, [string]$Prefix, [double]$OutFps, $Codec)

    $wf = [ordered]@{}
    $wf['1'] = @{ class_type = 'VHS_LoadVideo'; inputs = @{
        video = $File; force_rate = 0; custom_width = 0; custom_height = 0
        frame_load_cap = $Segment.Count; skip_first_frames = $Segment.Start; select_every_nth = 1 } }
    $wf['2'] = @{ class_type = 'FrameInterpolationModelLoader'; inputs = @{ model_name = $RifeModel } }
    $wf['3'] = @{ class_type = 'FrameInterpolate'; inputs = @{
        interp_model = @('2', 0); images = @('1', 0); multiplier = $Multiplier } }

    $encodeInputs = [ordered]@{}
    $encodeInputs['images'] = @('3', 0)
    $encodeInputs['frame_rate'] = $OutFps
    $encodeInputs['loop_count'] = 0
    $encodeInputs['filename_prefix'] = $Prefix
    $encodeInputs['format'] = $Codec.Format
    foreach ($k in $Codec.Extra.Keys) { $encodeInputs[$k] = $Codec.Extra[$k] }
    $encodeInputs['pingpong'] = $false
    $encodeInputs['save_output'] = $true

    $wf['4'] = @{ class_type = 'VHS_VideoCombine'; inputs = $encodeInputs }
    return $wf
}

function Invoke-ComfyWorkflow {
    param($Workflow, [int]$TimeoutMin, [string]$What)
    $body = @{ prompt = $Workflow; client_id = 'mmd-batch' } | ConvertTo-Json -Depth 30 -Compress
    $resp = Invoke-RestMethod -Uri "$ComfyUrl/prompt" -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec 120
    $promptId = $resp.prompt_id
    if (-not $promptId) { throw "$What : ComfyUI rejected the workflow: $($resp | ConvertTo-Json -Depth 6)" }

    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 4
        $hist = Invoke-RestMethod -Uri "$ComfyUrl/history/$promptId" -TimeoutSec 60
        if ($hist.PSObject.Properties.Name -contains $promptId) {
            $entry = $hist.$promptId
            if ($entry.status.status_str -ne 'success') {
                throw ("$What : ComfyUI reported '{0}': {1}" -f $entry.status.status_str,
                    ($entry.status.messages | ConvertTo-Json -Depth 8 -Compress))
            }
            return $entry
        }
    }
    throw "$What : timed out after $TimeoutMin minutes"
}

# The audio-muxed variant is the one worth keeping when audio exists; otherwise
# just take whatever the encoder produced.
function Get-ProducedFile($HistoryEntry) {
    $files = @()
    foreach ($nodeId in $HistoryEntry.outputs.PSObject.Properties.Name) {
        $out = $HistoryEntry.outputs.$nodeId
        foreach ($key in @('images', 'gifs', 'video', 'videos')) {
            if ($out.$key) {
                foreach ($f in $out.$key) {
                    if ($f.type -eq 'output' -or -not $f.type) { $files += (Join-Path $ComfyOutput $f.filename) }
                }
            }
        }
    }
    $existing = @($files | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)
    $withAudio = @($existing | Where-Object { $_ -match '-audio\.' })
    if ($withAudio.Count -gt 0) { return $withAudio[0] }
    if ($existing.Count -gt 0) { return $existing[0] }
    return $null
}

function Copy-ToComfyInput {
    param([string]$Path)
    $name = [IO.Path]::GetFileName($Path)
    $dest = Join-Path $ComfyInput $name
    if ($dest -ne $Path) { Copy-Item -LiteralPath $Path -Destination $dest -Force }
    return $name
}

function Clear-ComfyVram {
    try {
        Invoke-RestMethod -Uri "$ComfyUrl/free" -Method Post -TimeoutSec 60 `
            -Body (@{ unload_models = $true; free_memory = $true } | ConvertTo-Json) `
            -ContentType 'application/json' | Out-Null
        Write-Step '  released ComfyUI models between passes'
    }
    catch {
        Write-Step "  /free unavailable ($($_.Exception.Message)); continuing"
    }
}

# Concatenate frame-exact segments without re-encoding (frame counts already match).
function Join-SegmentsCopy {
    param([string[]]$Parts, [string]$OutPath, [string]$ListPath)
    $lines = foreach ($p in $Parts) { "file '" + ($p -replace '\\', '/') + "'" }
    Set-Content -LiteralPath $ListPath -Value $lines -Encoding UTF8
    Invoke-Ffmpeg -What 'concat (stream copy)' -FfArgs @(
        '-f', 'concat', '-safe', '0', '-i', $ListPath, '-c', 'copy', '-fflags', '+genpts', $OutPath)
}

# Join interpolated segments into a video-only file, dropping the duplicated
# overlap frame at every segment boundary. One re-encode covers the whole clip.
function Join-Interpolated {
    param([string[]]$Parts, [string]$OutPath, [double]$OutFps, [string]$EncodeKind,
          [int]$ResampleWidth = 0, [int]$ResampleHeight = 0)

    $inputs = @()
    $chains = @()
    for ($i = 0; $i -lt $Parts.Count; $i++) {
        $inputs += @('-i', $Parts[$i])
        $label = 'v' + $i
        if ($i -eq 0) {
            $chains += ('[' + $i + ':v]setpts=PTS-STARTPTS[' + $label + ']')
        }
        else {
            $chains += ('[' + $i + ':v]trim=start_frame=1,setpts=PTS-STARTPTS[' + $label + ']')
        }
    }
    $concatIn = (@(0..($Parts.Count - 1)) | ForEach-Object { '[v' + $_ + ']' }) -join ''
    $filter = ($chains -join ';') + ';' + $concatIn + 'concat=n=' + $Parts.Count + ':v=1:a=0[cat]'

    # The resample and the sharpen live here rather than in ComfyUI: a plain
    # ffmpeg scale costs no VRAM, keeps the native detail instead of asking a
    # model to re-imagine it, and can land on any resolution including 4K.
    # Values are formatted with the invariant culture so the decimal separator is
    # always '.' regardless of the machine locale, and assembled with -f because
    # "$name:" inside a double-quoted string parses as a scoped variable.
    $post = @()
    if ($ResampleWidth -gt 0 -and $ResampleHeight -gt 0) {
        $post += ('scale={0}:{1}:flags=lanczos' -f $ResampleWidth, $ResampleHeight)
    }
    if ($Sharpen -gt 0) {
        $sh = $Sharpen.ToString([Globalization.CultureInfo]::InvariantCulture)
        $post += ('unsharp=5:5:{0}:5:5:0.0' -f $sh)
    }
    if ($post.Count -gt 0) {
        $filter += ';[cat]' + ($post -join ',') + '[outv]'
    }
    else {
        $filter += ';[cat]null[outv]'
    }

    $codec = if ($EncodeKind -eq 'nvenc') {
        @('-c:v', 'h264_nvenc', '-b:v', '60M', '-pix_fmt', 'yuv420p')
    }
    else {
        @('-c:v', 'libx264', '-crf', $FinalCrf.ToString(), '-preset', 'medium', '-pix_fmt', 'yuv420p')
    }

    $ffArgs = @($inputs) + @(
        '-filter_complex', $filter,
        '-map', '[outv]',
        '-r', $OutFps.ToString()
    ) + $codec + @(
        '-an', '-movflags', '+faststart', $OutPath)

    Invoke-Ffmpeg -What 'interpolation assembly' -FfArgs $ffArgs
}

# Finish a clip: optionally resample/sharpen, then mux the original audio.
#
# Stream copy whenever nothing needs re-encoding, so the common "AI restore
# already produced the right size" case costs nothing.
#
# Deliberately NOT -shortest: that trims the output to the shorter stream, and
# the audio track is routinely a hair shorter than the video, which silently ate
# the last video frame (measured: 60 frames became 59). Trimming the audio to the
# video's duration instead keeps every frame.
function Add-OriginalAudio {
    param([string]$VideoPath, [string]$Original, [string]$OutPath,
          [int]$ResampleWidth = 0, [int]$ResampleHeight = 0)

    $filters = @()
    if ($ResampleWidth -gt 0 -and $ResampleHeight -gt 0) {
        $filters += ('scale={0}:{1}:flags=lanczos' -f $ResampleWidth, $ResampleHeight)
    }
    if ($Sharpen -gt 0) {
        $sh = $Sharpen.ToString([Globalization.CultureInfo]::InvariantCulture)
        $filters += ('unsharp=5:5:{0}:5:5:0.0' -f $sh)
    }

    $hasAudio = & ffprobe -v error -select_streams a -show_entries stream=index `
        -of csv=p=0 $Original 2>$null

    # Always remux through ffmpeg, even when nothing is re-encoded: a plain file
    # copy would put an MP4 container behind a .mkv name (seen for real - a
    # copied 1440p result probed as "mov,mp4,m4a" while being called .mkv). The
    # cost of a stream copy is negligible.
    $dur = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $VideoPath 2>$null
    $ffArgs = @('-i', $VideoPath)
    if ($hasAudio) {
        # A negative offset advances the audio, which is what the AI restore path
        # needs: it was measured to show picture content ~0.17 s ahead of the
        # source timeline. -Restore none measured zero offset, so default is 0.
        if ($AudioOffsetMs -ne 0) {
            $sec = $AudioOffsetMs / 1000.0
            $ffArgs += @('-itsoffset', $sec.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture))
            Write-Step ("  applying audio offset {0} ms" -f $AudioOffsetMs)
        }
        $ffArgs += @('-i', $Original, '-map', '0:v:0', '-map', '1:a:0', '-c:a', 'copy')
    }
    else {
        $ffArgs += @('-map', '0:v:0', '-an')
    }
    if ($filters.Count -gt 0) {
        $ffArgs += @('-vf', ($filters -join ','), '-c:v', 'libx264', '-crf', $FinalCrf.ToString(),
                     '-preset', 'medium', '-pix_fmt', 'yuv420p')
    }
    else {
        $ffArgs += @('-c:v', 'copy')
    }
    if ($dur -and $dur.Trim() -match '^[\d.]+$') {
        $limit = [double]$dur.Trim() + 0.02
        $ffArgs += @('-t', $limit.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture))
    }
    # +faststart is an MP4/MOV muxer option; passing it for a .mkv target makes
    # ffmpeg fail with "Option movflags not found".
    if ([IO.Path]::GetExtension($OutPath) -match '^\.(mp4|m4v|mov)$') {
        $ffArgs += @('-movflags', '+faststart')
    }
    $ffArgs += $OutPath
    Invoke-Ffmpeg -What 'final assembly' -FfArgs $ffArgs
}

function Invoke-RestorePass {
    param([string]$Staged, [string]$ClipTag, $Segments, [double]$SrcFps, [string]$WorkDir,
          [string]$RestoreMode, [double]$DownscaleFactor, [int]$FlashScale)

    $Segments = @($Segments)
    $codec = New-CodecArgs -Kind $Encode -Quality 'high' -PixFmt 'yuv420p'
    $parts = @()
    for ($i = 0; $i -lt $Segments.Count; $i++) {
        $seg = $Segments[$i]
        $prefix = "mmdseg_{0}_r{1:d3}" -f $ClipTag, $i
        $what = "restore segment $($i + 1)/$($Segments.Count) (frames $($seg.Start)-$($seg.Start + $seg.Count - 1))"
        Write-Step "  $what ..."
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $wf = New-RestoreWorkflow -Segment $seg -File $Staged -Prefix $prefix -SrcFps $SrcFps `
            -RestoreMode $RestoreMode -DownscaleFactor $DownscaleFactor -FlashScale $FlashScale -Codec $codec
        $hist = Invoke-ComfyWorkflow -Workflow $wf -TimeoutMin $PerSegmentTimeoutMin -What $what
        $produced = Get-ProducedFile $hist
        if (-not $produced) { throw "$what : produced no output file" }
        $dest = Join-Path $WorkDir ("r{0:d3}.mp4" -f $i)
        Copy-Item -LiteralPath $produced -Destination $dest -Force
        $parts += $dest
        $sw.Stop()
        Write-Step ("  segment done in {0:N0}s -> {1}" -f $sw.Elapsed.TotalSeconds, (Split-Path $dest -Leaf))
    }

    $joined = Join-Path $WorkDir 'restored.mp4'
    if ($parts.Count -gt 1) {
        Write-Step "  joining $($parts.Count) segments (stream copy)"
        Join-SegmentsCopy -Parts $parts -OutPath $joined -ListPath (Join-Path $WorkDir 'concat.txt')
    }
    else {
        Copy-Item -LiteralPath $parts[0] -Destination $joined -Force
    }
    return $joined
}

function Invoke-InterpPass {
    param([string]$SourcePath, [string]$Staged, [string]$ClipTag, $Segments, [double]$OutFps,
          [string]$WorkDir, [string]$Original)

    $Segments = @($Segments)
    $codec = New-CodecArgs -Kind $Encode -Quality 'high' -PixFmt 'yuv420p'
    $parts = @()
    for ($i = 0; $i -lt $Segments.Count; $i++) {
        $seg = $Segments[$i]
        $prefix = "mmdseg_{0}_i{1:d3}" -f $ClipTag, $i
        $what = "interp segment $($i + 1)/$($Segments.Count) (frames $($seg.Start)-$($seg.Start + $seg.Count - 1))"
        Write-Step "  $what ..."
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $wf = New-InterpWorkflow -Segment $seg -File $Staged -Prefix $prefix -OutFps $OutFps -Codec $codec
        $hist = Invoke-ComfyWorkflow -Workflow $wf -TimeoutMin $PerSegmentTimeoutMin -What $what
        $produced = Get-ProducedFile $hist
        if (-not $produced) { throw "$what : produced no output file" }
        $dest = Join-Path $WorkDir ("i{0:d3}.mp4" -f $i)
        Copy-Item -LiteralPath $produced -Destination $dest -Force
        $parts += $dest
        $sw.Stop()
        Write-Step ("  segment done in {0:N0}s -> {1}" -f $sw.Elapsed.TotalSeconds, (Split-Path $dest -Leaf))
    }
    return $parts
}

# ------------------------------------------------------------------ preflight

# Read the machine instead of assuming it. Ports and VRAM come from the probe so
# the script behaves the same on a different machine with different hardware.
$comfyLayout = Find-ComfyLayout
if (-not $ComfyInput -or -not $ComfyOutput) {
    if (-not $comfyLayout) {
        throw ("No ComfyUI install found, so the input/output folders are unknown. " +
               "Pass -ComfyInput and -ComfyOutput explicitly, or run scripts/probe-env.ps1 " +
               "to see what this machine has.")
    }
    if (-not $ComfyInput) { $ComfyInput = $comfyLayout.InputDir }
    if (-not $ComfyOutput) { $ComfyOutput = $comfyLayout.OutputDir }
}

$gpuInfo = Get-GpuInfo

try { Invoke-RestMethod -Uri "$ComfyUrl/system_stats" -TimeoutSec 15 | Out-Null }
catch { throw "ComfyUI is not answering at $ComfyUrl. Start it with scripts/launch-comfyui.ps1 first." }

if (-not (Test-Path -LiteralPath $InputDir)) { throw "InputDir not found: $InputDir" }
if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$videos = @(Get-ChildItem -LiteralPath $InputDir -File |
    Where-Object { $Extensions -contains $_.Extension.ToLower() } | Sort-Object Name)
if ($videos.Count -eq 0) { Write-Step "No videos found in $InputDir"; return }

$doRestore = $Mode -in @('both', 'upscale')
$doInterp = $Mode -in @('both', 'interp')
$minRestoreFrames = if ($Restore -eq 'flashvsr') { 21 } else { 5 }
$aiRestoreWanted = $doRestore -and $Restore -ne 'none'

Write-Step ("Mode={0}  restore={1}  target_short_edge={2}  multiplier={3}x  encode={4}" -f `
    $Mode, $(if ($doRestore) { $Restore } else { 'skipped' }), `
    $(if ($doRestore) { $TargetShortEdge } else { 'n/a' }), `
    $(if ($doInterp) { $Multiplier } else { '1' }), $Encode)
Write-Step ("sharpen={0}  intermediate_crf={1}  audio_offset={2}ms" -f $Sharpen, $IntermediateCrf, $AudioOffsetMs)
Write-Step ("segments: restore {0} frames, interp {1}  |  clips: {2}" -f `
    $SegmentFrames, $(if ($InterpSegmentFrames -gt 0) { "$InterpSegmentFrames frames" } else { 'auto from VRAM' }), $videos.Count)

Write-Step ("machine: ComfyUI={0}  input={1}" -f $comfyLayout.CodeDir, $ComfyInput)
if ($gpuInfo) {
    Write-Step ("         GPU={0} ({1} GB)  free now {2} GB" -f $gpuInfo.Name,
        [math]::Round($gpuInfo.TotalMB / 1024, 1), [math]::Round($gpuInfo.FreeMB / 1024, 1))
}
else { Write-Step '         GPU: nvidia-smi unavailable, VRAM unknown - conservative defaults in use' }

# Warn rather than silently rewrite the user's requested parameters. The only
# thing the script chooses on its own is the interpolation segment size above.
if ($aiRestoreWanted -and $gpuInfo -and $gpuInfo.TotalMB -le 12288 -and $TargetShortEdge -gt 1440) {
    Write-Step '         WARNING: AI restore to above 1440p on a 12GB-or-smaller card was' 
    Write-Step '                  measured to thrash (VRAM pegged, GPU ~100% at ~60W). Expect' 
    Write-Step '                  it to be very slow; -Restore none is the recommended path for' 
    Write-Step '                  a clean source.'
}

$ok = 0; $failed = 0

foreach ($video in $videos) {
    $clipSw = [Diagnostics.Stopwatch]::StartNew()
    Write-Step ("=== {0}  ({1:N1} MB)" -f $video.Name, ($video.Length / 1MB))
    $clipTag = [IO.Path]::GetFileNameWithoutExtension($video.Name) -replace '[^A-Za-z0-9_-]', '_'
    if ($clipTag.Length -gt 24) { $clipTag = $clipTag.Substring(0, 24) }
    $workDir = Join-Path $OutputDir ("_work\" + [IO.Path]::GetFileNameWithoutExtension($video.Name))

    try {
        $srcFps = Get-VideoFps $video.FullName
        $dims = Get-VideoDims $video.FullName
        $srcShort = [math]::Min($dims.Width, $dims.Height)
        $totalFrames = Get-VideoFrameCount $video.FullName
        if ($totalFrames -le 0) { throw "could not read a frame count from $($video.Name)" }
        $outFps = if ($doInterp) { [math]::Round($srcFps * $Multiplier, 3) } else { $srcFps }

        if (-not (Test-Path -LiteralPath $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }
        Write-Step ("  {0} frames, {1}fps, short edge {2}px -> output {3}fps" -f $totalFrames, $srcFps, $srcShort, $outFps)

        $staged = Copy-ToComfyInput $video.FullName

        # ---------------------------------------------------------- pass 1
        $currentPath = $video.FullName
        $currentStaged = $staged
        $aiRestore = $doRestore -and $Restore -ne 'none'
        # With no AI restore the upscale is just a resample in the final pass.
        $needResample = $doRestore -and -not $aiRestore

        if ($aiRestore) {
            if ($Restore -eq 'flashvsr') {
                # Feed NATIVE pixels and let the model overshoot; the final pass
                # brings the result down to the requested size. Pre-downscaling
                # first measurably cost detail on a clean render (0.883 of a
                # Lanczos reference versus 0.946 fed natively).
                $flashScale = Resolve-FlashVsrScale -SrcShort $srcShort -Target $TargetShortEdge
                $downscaleFactor = 1
                Write-Step ("  pass 1: flashvsr {0}x from native {1}x{2} -> {3}x{4}, then resampled to target" -f `
                    $flashScale, $dims.Width, $dims.Height, ($dims.Width * $flashScale), ($dims.Height * $flashScale))
                $needResample = $true
            }
            else {
                $downscaleFactor = $Downscale
                $flashScale = 2
                Write-Step ("  pass 1: seedvr2 -> {0}px short edge (downscale {1}x)" -f $TargetShortEdge, $downscaleFactor)
            }

            # @() matters: PowerShell unrolls a one-element array returned from a
            # function, and the lone object's own `Count` property would then be
            # read as the segment count (a 24-frame clip reported "24 segments").
            $segments = @(Get-Segments -Total $totalFrames -Target $SegmentFrames -MinFrames $minRestoreFrames)
            Write-Step ("  {0} restore segment(s): {1}" -f $segments.Count,
                (($segments | ForEach-Object { $_.Count }) -join ' + '))
            $currentPath = Invoke-RestorePass -Staged $currentStaged -ClipTag $clipTag -Segments $segments `
                -SrcFps $srcFps -WorkDir $workDir -RestoreMode $Restore `
                -DownscaleFactor $downscaleFactor -FlashScale $flashScale
            Write-Step "  pass 1 complete: $currentPath"
            $currentStaged = Copy-ToComfyInput $currentPath
        }
        elseif ($doRestore) {
            Write-Step ("  pass 1: skipped (no AI restore) - {0}px short edge happens by resampling at the end" -f $TargetShortEdge)
        }

        $resample = if ($needResample) {
            Resolve-ResampleSize -Target $TargetShortEdge -SrcWidth $dims.Width -SrcHeight $dims.Height
        }
        else { $null }

        # ---------------------------------------------------------- pass 2
        if ($doInterp) {
            if ($aiRestore) { Clear-ComfyVram }
            $interpTotal = Get-VideoFrameCount $currentPath
            if ($interpTotal -le 1) { throw "nothing to interpolate in $currentPath" }

            # Overlap each segment by one frame so the join is seamless: the first
            # frame of every later segment duplicates the previous segment's last.
            $segTarget = $InterpSegmentFrames
            if ($segTarget -le 0) {
                $idims = Get-VideoDims $currentPath
                $segTarget = Get-AutoInterpSegmentFrames -FrameWidth $idims.Width -FrameHeight $idims.Height `
                    -VramTotalMB $(if ($gpuInfo) { $gpuInfo.TotalMB } else { 0 })
                Write-Step ("  auto segment size: {0} frames (from {1}x{2} on {3})" -f $segTarget,
                    $idims.Width, $idims.Height,
                    $(if ($gpuInfo) { "$([math]::Round($gpuInfo.TotalMB / 1024, 1)) GB VRAM" } else { 'unknown VRAM' }))
            }
            $base = @(Get-Segments -Total $interpTotal -Target $segTarget -MinFrames 2)
            $segments = @()
            for ($i = 0; $i -lt $base.Count; $i++) {
                if ($i -eq 0) { $segments += $base[$i] }
                else {
                    $segments += [pscustomobject]@{ Start = $base[$i - 1].Start + $base[$i - 1].Count - 1
                                                    Count = $base[$i].Count + 1 }
                }
            }
            Write-Step ("  pass 2: RIFE x{0}, {1} segment(s): {2}" -f $Multiplier, $segments.Count,
                (($segments | ForEach-Object { $_.Count }) -join ' + '))
            $parts = Invoke-InterpPass -SourcePath $currentPath -Staged $currentStaged -ClipTag $clipTag `
                -Segments $segments -OutFps $outFps -WorkDir $workDir -Original $video.FullName

            $suffix = if ($Mode -eq 'both') {
                "_{0}p{1}x" -f $TargetShortEdge, $Multiplier
            } else { "_{0}x" -f $Multiplier }
            $dest = Join-Path $OutputDir ([IO.Path]::GetFileNameWithoutExtension($video.Name) + $suffix + $video.Extension)
            $joinedVideo = Join-Path $workDir 'interpolated.mp4'
            Write-Step "  joining $($parts.Count) interpolated segment(s)"
            if ($resample) {
                Write-Step ("  resampling to {0}x{1} (lanczos){2}" -f $resample.Width, $resample.Height,
                    $(if ($Sharpen -gt 0) { ", unsharp $Sharpen" } else { '' }))
            }
            Join-Interpolated -Parts $parts -OutPath $joinedVideo -OutFps $outFps -EncodeKind $Encode `
                -ResampleWidth $(if ($resample) { $resample.Width } else { 0 }) `
                -ResampleHeight $(if ($resample) { $resample.Height } else { 0 })
            Write-Step '  muxing original audio'
            Add-OriginalAudio -VideoPath $joinedVideo -Original $video.FullName -OutPath $dest
        }
        else {
            $dest = Join-Path $OutputDir ([IO.Path]::GetFileNameWithoutExtension($video.Name) +
                ("_{0}p" -f $TargetShortEdge) + $video.Extension)
            if ($resample) {
                Write-Step ("  resampling to {0}x{1} (lanczos){2}" -f $resample.Width, $resample.Height,
                    $(if ($Sharpen -gt 0) { ", unsharp $Sharpen" } else { '' }))
            }
            Add-OriginalAudio -VideoPath $currentPath -Original $video.FullName -OutPath $dest `
                -ResampleWidth $(if ($resample) { $resample.Width } else { 0 }) `
                -ResampleHeight $(if ($resample) { $resample.Height } else { 0 })
        }

        $clipSw.Stop()
        $size = if (Test-Path -LiteralPath $dest) { [math]::Round((Get-Item -LiteralPath $dest).Length / 1MB, 1) } else { 0 }
        Write-Step ("  OK -> {0}  ({1:N1} MB, {2:N1} min)" -f $dest, $size, $clipSw.Elapsed.TotalMinutes)
        $ok++

        if (-not $KeepIntermediate) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
        if ($currentStaged -ne $video.Name) { Remove-Item -LiteralPath (Join-Path $ComfyInput $currentStaged) -Force -ErrorAction SilentlyContinue }
        if ($staged -ne $video.Name) { Remove-Item -LiteralPath (Join-Path $ComfyInput $staged) -Force -ErrorAction SilentlyContinue }
    }
    catch {
        $clipSw.Stop()
        Write-Step "  FAILED: $($_.Exception.Message)"
        $failed++
    }
}

if (-not $KeepIntermediate) {
    # Per-clip work dirs are removed as they finish; this clears the now-empty parent.
    $workRoot = Join-Path $OutputDir '_work'
    if ((Test-Path -LiteralPath $workRoot) -and
        -not (Get-ChildItem -LiteralPath $workRoot -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $workRoot -Force -ErrorAction SilentlyContinue
    }
}

Write-Step "Done. succeeded=$ok failed=$failed. Output: $OutputDir"
