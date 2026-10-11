<#
.SYNOPSIS
  Report what THIS machine has for the MMD upscale / interpolation pipeline, and
  which jobs are therefore possible.

.DESCRIPTION
  Run this before the first job on any machine, including your own after an
  update. It finds ComfyUI, its interpreter, the required node packs and models,
  ffmpeg, the GPU and its VRAM, and the console code page - then says which
  -Restore modes are viable and prints a ready-to-run command.

  Nothing is written or changed. This is read-only reconnaissance.

.EXAMPLE
  .\scripts\probe-env.ps1
  .\scripts\probe-env.ps1 -Json      # machine-readable
#>
[CmdletBinding()]
param(
    [string]$ComfyUrl = 'http://127.0.0.1:8188',
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'comfy-env.ps1')

function Test-Tool([string]$Name) {
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $c) { return $null }
    $v = (& $Name -version 2>&1 | Select-Object -First 1)
    return [pscustomobject]@{ Path = $c.Source; Version = ("$v").Trim() }
}

$ffmpeg  = Test-Tool 'ffmpeg'
$ffprobe = Test-Tool 'ffprobe'
$gpu     = Get-GpuInfo
$enc     = Get-ConsoleEncodingInfo
$layout  = Find-ComfyLayout
$server  = $false
if ($layout) { $server = Test-ComfyServer -Url $ComfyUrl }

# ---------------------------------------------------------------- node packs
$packs = @()
if ($layout -and (Test-Path -LiteralPath $layout.NodesDir)) {
    foreach ($p in (Get-RequiredNodePacks)) {
        $packs += [pscustomobject]@{
            Name      = $p.Name
            Dir       = $p.Dir
            Installed = (Test-Path -LiteralPath (Join-Path $layout.NodesDir $p.Dir))
        }
    }
}

# ------------------------------------------------------------------- models
function Get-ModelList([string]$Dir, [string]$Filter) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like $Filter } | Select-Object -ExpandProperty Name)
}
$interpModels = @()
$flashModels  = @()
$seedModels   = @()
if ($layout) {
    $interpModels = Get-ModelList (Join-Path $layout.ModelsDir 'frame_interpolation') '*.safetensors'
    $flashModels  = Get-ModelList (Join-Path $layout.ModelsDir 'FlashVSR') '*'
    $seedModels   = Get-ModelList (Join-Path $layout.ModelsDir 'SEEDVR2') '*'
}

# ------------------------------------------------------------ what is viable
$hasVhs   = @($packs | Where-Object { $_.Dir -eq 'ComfyUI-VideoHelperSuite' -and $_.Installed }).Count -gt 0
$hasFlash = (@($packs | Where-Object { $_.Dir -eq 'ComfyUI-FlashVSR' -and $_.Installed }).Count -gt 0) `
            -and (@($flashModels | Where-Object { $_ -like 'FlashVSR*.safetensors' }).Count -gt 0)
$hasSeed  = @($packs | Where-Object { $_.Dir -eq 'seedvr2_videoupscaler' -and $_.Installed }).Count -gt 0
$hasRife  = $interpModels.Count -gt 0

$resampleOnly = [bool]($ffmpeg -and $ffprobe)
$canInterp    = [bool]($layout -and $hasVhs -and $hasRife)     # built-in FrameInterpolate needs no pack
$canAudio     = [bool]$resampleOnly                            # ffmpeg does the muxing

$suggested = @()
if ($resampleOnly) {
    $suggested += '.\scripts\mmd_upscale_batch.ps1 -InputDir <in> -OutputDir <out> -Mode upscale -TargetShortEdge 1440'
}
if ($canInterp) {
    $suggested += '.\scripts\mmd_upscale_batch.ps1 -InputDir <in> -OutputDir <out> -Mode both -TargetShortEdge 1440'
}
if ($canInterp -and $hasFlash) {
    $suggested += '.\scripts\mmd_upscale_batch.ps1 -InputDir <in> -OutputDir <out> -Restore flashvsr   # degraded sources only'
}

$warnings = @()
if (-not $ffmpeg)  { $warnings += 'ffmpeg not found on PATH - every assembly step needs it. Install it (winget install Gyan.FFmpeg) before anything else.' }
if (-not $ffprobe) { $warnings += 'ffprobe not found on PATH - frame counts, fps and durations cannot be probed.' }
if (-not $layout)  { $warnings += 'No ComfyUI install found. Resample-only jobs still work; interpolation and AI restore need ComfyUI.' }
if ($layout -and -not $hasVhs) { $warnings += "ComfyUI-VideoHelperSuite is missing from $($layout.NodesDir) - the pipeline reads and writes frames with VHS nodes, so interpolation and AI restore cannot run." }
if ($layout -and -not $hasRife) { $warnings += "No RIFE/FILM checkpoint in models\frame_interpolation - FrameInterpolate will have an empty model list." }
if ($layout -and -not $server) { $warnings += "ComfyUI is not answering on $ComfyUrl. Start it with scripts\launch-comfyui.ps1." }
if ($gpu -and $gpu.TotalMB -le 9000 -and $hasFlash) { $warnings += 'Less than 9GB VRAM: use -Restore none (default) for clean sources, keep -SegmentFrames near the 21-frame minimum, and avoid 4K output.' }

$autoSeg = if ($gpu) {
    Get-AutoInterpSegmentFrames -FrameWidth 3840 -FrameHeight 2160 -VramTotalMB $gpu.TotalMB
}
else { 12 }

# -------------------------------------------------------------------- report
if ($Json) {
    [pscustomobject]@{
        ffmpeg        = $ffmpeg
        ffprobe       = $ffprobe
        gpu           = $gpu
        console       = $enc
        comfy         = $layout
        comfyServer   = $server
        comfyUrl      = $ComfyUrl
        nodePacks     = $packs
        interpModels  = $interpModels
        flashsrModels = $flashModels
        seedvr2Models = $seedModels
        canResample   = $resampleOnly
        canInterp     = $canInterp
        canFlashVsr   = $hasFlash
        canSeedVr2    = $hasSeed
        autoInterpSegmentFrames4k = $autoSeg
        suggested     = $suggested
        warnings      = $warnings
    } | ConvertTo-Json -Depth 6
    return
}

Write-Host ''
Write-Host 'MMD upscale / interpolation - environment probe' -ForegroundColor Cyan
Write-Host ('=' * 60)

Write-Host "`nTools"
Write-Host ("  ffmpeg         : " + $(if ($ffmpeg) { $ffmpeg.Version } else { 'MISSING' }))
Write-Host ("  ffprobe        : " + $(if ($ffprobe) { 'present' } else { 'MISSING' }))
Write-Host ("  console ACP    : {0}{1}" -f $enc.AnsiCodePage, $(if ($enc.IsUtf8) { ' (UTF-8)' } else { ' (legacy - PYTHONUTF8=1 matters here)' }))

Write-Host "`nGPU"
if ($gpu) {
    Write-Host ("  {0}  {1} MB total, {2} MB free" -f $gpu.Name, $gpu.TotalMB, $gpu.FreeMB)
    Write-Host ("  auto interpolation segment size at 4K: {0} frames" -f $autoSeg)
}
else { Write-Host '  nvidia-smi unavailable - VRAM unknown, conservative defaults will be used' }

Write-Host "`nComfyUI"
if ($layout) {
    Write-Host ("  install        : {0}{1}" -f $layout.Root, $(if ($layout.Portable) { '  (portable layout)' } else { '  (source layout)' }))
    Write-Host ("  code dir       : {0}" -f $layout.CodeDir)
    Write-Host ("  interpreter    : {0}" -f $(if ($layout.Python) { $layout.Python } else { 'not found' }))
    Write-Host ("  input / output : {0}  |  {1}" -f $layout.InputDir, $layout.OutputDir)
    Write-Host ("  API server     : " + $(if ($server) { "answering on $ComfyUrl" } else { "not answering on $ComfyUrl" }))
    Write-Host "  node packs:"
    foreach ($p in $packs) {
        Write-Host ("    [{0}] {1}" -f $(if ($p.Installed) { 'x' } else { ' ' }), $p.Name)
    }
    Write-Host ("  frame_interpolation models : " + $(if ($interpModels) { $interpModels -join ', ' } else { 'none' }))
    Write-Host ("  FlashVSR models            : " + $(if ($flashModels) { "$($flashModels.Count) file(s)" } else { 'none' }))
    Write-Host ("  SeedVR2 models             : " + $(if ($seedModels) { "$($seedModels.Count) file(s)" } else { 'none' }))
}
else { Write-Host '  not found - see warnings' }

Write-Host "`nWhat is possible here"
Write-Host ("  resample only (ffmpeg)      : " + $(if ($resampleOnly) { 'yes' } else { 'no - ffmpeg missing' }))
Write-Host ("  frame interpolation (RIFE)  : " + $(if ($canInterp) { 'yes' } else { 'no' }))
Write-Host ("  AI restore - FlashVSR       : " + $(if ($hasFlash) { 'yes' } else { 'no' }))
Write-Host ("  AI restore - SeedVR2        : " + $(if ($hasSeed) { 'yes' } else { 'no' }))
Write-Host ("  audio passthrough           : " + $(if ($canAudio) { 'yes' } else { 'no' }))

if ($suggested.Count -gt 0) {
    Write-Host "`nReady to run" -ForegroundColor Green
    foreach ($s in $suggested) { Write-Host "  $s" }
}
if ($warnings.Count -gt 0) {
    Write-Host "`nWatch out" -ForegroundColor Yellow
    foreach ($w in $warnings) { Write-Host "  - $w" }
}
Write-Host ''
