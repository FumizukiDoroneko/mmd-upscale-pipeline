<#
.SYNOPSIS
  Start the ComfyUI found on this machine, with the environment the node packs need.

.DESCRIPTION
  Replaces the old start_comfyui.bat, which hardcoded one machine's install path.
  This finds ComfyUI by probing (see comfy-env.ps1), then launches it with:

    PYTHONUTF8=1 / PYTHONIOENCODING=utf-8   Python writes stdout as UTF-8 instead
        of the legacy console code page. Without this, node packs that log emoji
        during import (SeedVR2 does) abort ComfyUI at startup with
        UnicodeEncodeError on any non-UTF8 Windows install - which is most of them.
    PYTHONUNBUFFERED=1   progress bars stream to the console instead of appearing
        only when a buffer happens to fill.

  If a server already answers on the port, it says so and exits rather than
  starting a second copy that cannot bind.

.EXAMPLE
  .\scripts\launch-comfyui.ps1                     # foreground, logs in the console
  .\scripts\launch-comfyui.ps1 -Background         # detached, logs next to ComfyUI
  .\scripts\launch-comfyui.ps1 -Port 8000
  .\scripts\launch-comfyui.ps1 -HfEndpoint https://hf-mirror.com   # restricted network
#>
[CmdletBinding()]
param(
    [string]$ComfyRoot = '',
    [int]$Port = 8188,
    [string]$Listen = '127.0.0.1',
    [string]$HfEndpoint = '',
    [switch]$Background,
    [switch]$SkipRunningCheck
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'comfy-env.ps1')

$layout = if ($ComfyRoot) { Resolve-ComfyLayout -Root $ComfyRoot } else { Find-ComfyLayout }
if (-not $layout) {
    throw 'No ComfyUI install found. Pass -ComfyRoot, or run scripts/probe-env.ps1 to see what this machine has.'
}
if (-not $layout.Python) {
    throw "Found ComfyUI at $($layout.CodeDir) but no interpreter (looked for python_embeded\python.exe and .venv\Scripts\python.exe)."
}

$url = "http://127.0.0.1:$Port"
if (-not $SkipRunningCheck -and (Test-ComfyServer -Url $url -TimeoutSec 4)) {
    Write-Host "ComfyUI is already answering on $url - nothing to do." -ForegroundColor Yellow
    return
}

$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUNBUFFERED = '1'
if ($HfEndpoint) { $env:HF_ENDPOINT = $HfEndpoint }

$mainPy = Join-Path $layout.CodeDir 'main.py'
$arguments = @('-s', $mainPy)
if ($layout.Portable) { $arguments += '--windows-standalone-build' }
$arguments += @('--port', "$Port", '--listen', $Listen)

Write-Host ''
Write-Host ("ComfyUI  : {0}{1}" -f $layout.Root, $(if ($layout.Portable) { '  (portable)' } else { '  (source)' }))
Write-Host ("python   : {0}" -f $layout.Python)
Write-Host ("listening: {0}" -f $url)
if ($HfEndpoint) { Write-Host ("HF mirror: {0}" -f $HfEndpoint) }
Write-Host ''

if ($Background) {
    $outLog = Join-Path $layout.Root 'comfyui.stdout.log'
    $errLog = Join-Path $layout.Root 'comfyui.stderr.log'
    Start-Process -FilePath $layout.Python -ArgumentList $arguments -WorkingDirectory $layout.CodeDir `
        -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    Write-Host "Started detached. Logs: $errLog" -ForegroundColor Green
    Write-Host 'Wait for "To see the GUI go to" before running a job.'
    return
}

Push-Location $layout.CodeDir
try { & $layout.Python @arguments } finally { Pop-Location }
