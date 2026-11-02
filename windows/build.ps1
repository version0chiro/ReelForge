param(
    [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"
$WindowsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $WindowsRoot
$VirtualEnvironment = Join-Path $WindowsRoot ".venv"
$Python = Join-Path $VirtualEnvironment "Scripts\python.exe"
$Vendor = Join-Path $WindowsRoot "vendor"

if (-not (Test-Path $Python)) {
    py -3.12 -m venv $VirtualEnvironment
}

if (-not $SkipInstall) {
    & $Python -m pip install --upgrade pip
    & $Python -m pip install -r (Join-Path $WindowsRoot "requirements-build.txt")
}

$FFmpeg = (Get-Command ffmpeg.exe -ErrorAction Stop).Source
$FFprobe = (Get-Command ffprobe.exe -ErrorAction Stop).Source
New-Item -ItemType Directory -Path $Vendor -Force | Out-Null
Copy-Item $FFmpeg (Join-Path $Vendor "ffmpeg.exe") -Force
Copy-Item $FFprobe (Join-Path $Vendor "ffprobe.exe") -Force

Push-Location $ProjectRoot
try {
    & $Python -m unittest discover -s windows\tests -v
    & $Python -m PyInstaller windows\ReelForgeWindows.spec --noconfirm --clean
    $Archive = Join-Path $ProjectRoot "ReelForge-Windows-x64.zip"
    if (Test-Path $Archive) {
        Remove-Item $Archive -Force
    }
    Compress-Archive -Path (Join-Path $ProjectRoot "dist\ReelForge") -DestinationPath $Archive
    Write-Host $Archive
}
finally {
    Pop-Location
}
