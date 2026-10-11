# Discovery helpers shared by probe-env.ps1, mmd_upscale_batch.ps1 and
# launch-comfyui.ps1. Dot-source it; do not run it directly.
#
# Nothing here hardcodes one machine's layout - everything is probed, so the skill
# works for whoever downloaded it.

# Candidate roots, most specific first. COMFYUI_PATH / COMFYUI_CODE_PATH are what
# the comfyui-mcp server uses, so honour them when a user already set them.
function Get-ComfyRootCandidates {
    $list = @()
    foreach ($v in @($env:COMFYUI_PATH, $env:COMFYUI_CODE_PATH, $env:COMFYUI_HOME)) {
        if ($v) { $list += $v }
    }
    $list += @(
        (Join-Path $env:USERPROFILE 'ComfyUI'),
        (Join-Path $env:USERPROFILE 'Documents\ComfyUI'),
        (Join-Path $env:USERPROFILE 'Desktop\ComfyUI'),
        (Join-Path $env:USERPROFILE 'AppData\Local\Programs\@comfyorgcomfyui-electron'),
        'C:\ComfyUI', 'C:\ComfyUI_windows_portable',
        'D:\ComfyUI', 'D:\ComfyUI_windows_portable',
        'E:\ComfyUI', 'E:\ComfyUI_windows_portable'
    )
    # Also anything literally called ComfyUI* sitting one level under a drive root.
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem)) {
        $root = $drive.Root
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like 'ComfyUI*' })) {
            $list += $d.FullName
        }
    }
    return @($list | Where-Object { $_ } | Select-Object -Unique)
}

# Turn a candidate root into a layout descriptor, or $null if it is not ComfyUI.
# Covers the two shapes that exist in the wild:
#   portable : <root>\ComfyUI\main.py + <root>\python_embeded\python.exe
#   source   : <root>\main.py         + <root>\.venv\Scripts\python.exe
function Resolve-ComfyLayout {
    param([string]$Root)
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return $null }

    $codeDir = $null
    $portable = $false
    if (Test-Path -LiteralPath (Join-Path $Root 'ComfyUI\main.py')) {
        $codeDir = Join-Path $Root 'ComfyUI'
        $portable = $true
    }
    elseif (Test-Path -LiteralPath (Join-Path $Root 'main.py')) {
        $codeDir = $Root
    }
    else { return $null }

    $python = $null
    foreach ($candidate in @(
            (Join-Path $Root 'python_embeded\python.exe'),
            (Join-Path $codeDir '.venv\Scripts\python.exe'),
            (Join-Path $codeDir 'venv\Scripts\python.exe'))) {
        if (Test-Path -LiteralPath $candidate) { $python = $candidate; break }
    }

    return [pscustomobject]@{
        Root      = (Resolve-Path -LiteralPath $Root).Path
        CodeDir   = (Resolve-Path -LiteralPath $codeDir).Path
        ModelsDir = (Join-Path $codeDir 'models')
        InputDir  = (Join-Path $codeDir 'input')
        OutputDir = (Join-Path $codeDir 'output')
        NodesDir  = (Join-Path $codeDir 'custom_nodes')
        Python    = $python
        Portable  = $portable
    }
}

# First candidate that actually looks like a ComfyUI install.
function Find-ComfyLayout {
    foreach ($candidate in (Get-ComfyRootCandidates)) {
        $layout = Resolve-ComfyLayout -Root $candidate
        if ($layout) { return $layout }
    }
    return $null
}

# GPU name / total / free VRAM in MB, or $null when nvidia-smi is unavailable.
# Non-NVIDIA machines get unknown VRAM and therefore conservative defaults.
function Get-GpuInfo {
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return $null }
    $raw = & nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits 2>$null
    if (-not $raw) { return $null }
    $parts = (($raw | Select-Object -First 1) -split ',') | ForEach-Object { $_.Trim() }
    if ($parts.Count -lt 3) { return $null }
    return [pscustomobject]@{ Name = $parts[0]; TotalMB = [int]$parts[1]; FreeMB = [int]$parts[2] }
}

function Test-ComfyServer {
    param([string]$Url = 'http://127.0.0.1:8188', [int]$TimeoutSec = 6)
    try { $null = Invoke-RestMethod -Uri "$Url/system_stats" -TimeoutSec $TimeoutSec; return $true }
    catch { return $false }
}

# Is the ANSI code page non-UTF8? On such Windows installs Python's stdio defaults
# to the legacy code page, and node packs that log emoji crash ComfyUI at import.
# Every launch path here therefore sets PYTHONUTF8=1; this reports whether it
# matters on this machine rather than assuming it does.
function Get-ConsoleEncodingInfo {
    try {
        $cp = [int](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' `
                -Name ACP -ErrorAction Stop).ACP
    }
    catch { $cp = 0 }
    return [pscustomobject]@{ AnsiCodePage = $cp; IsUtf8 = ($cp -eq 65001) }
}

# Interpolation segments are sized from real VRAM instead of a hardcoded number.
# RIFE holds the input frames plus the interpolated output (about 2x the input) in
# float32, so N input frames cost roughly 3 * N * width * height * 12 bytes. This
# reproduces what was found to work on the reference 12GB card at 4K (20 frames)
# without the user having to know that number.
function Get-AutoInterpSegmentFrames {
    param([int]$FrameWidth, [int]$FrameHeight, [int]$VramTotalMB,
          [int]$HardMax = 48, [int]$HardMin = 6)
    if ($VramTotalMB -le 0 -or $FrameWidth -le 0 -or $FrameHeight -le 0) { return 12 }
    $bytesPerFrame = [double]$FrameWidth * $FrameHeight * 12.0
    $budget = [double]$VramTotalMB * 1MB * 0.55
    $n = [int][math]::Floor($budget / (3.0 * $bytesPerFrame))
    return [math]::Max($HardMin, [math]::Min($HardMax, $n))
}

function Get-RequiredNodePacks {
    return @(
        @{ Dir = 'seedvr2_videoupscaler';       Name = 'ComfyUI-SeedVR2_VideoUpscaler' },
        @{ Dir = 'ComfyUI-FlashVSR';            Name = 'ComfyUI-FlashVSR' },
        @{ Dir = 'ComfyUI-Frame-Interpolation'; Name = 'ComfyUI-Frame-Interpolation' },
        @{ Dir = 'ComfyUI-VideoHelperSuite';    Name = 'ComfyUI-VideoHelperSuite' }
    )
}
