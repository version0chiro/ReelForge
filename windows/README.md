# ReelForge for Windows

The Windows edition combines local gameplay clips or a public Google Drive
folder, detects sustained high-energy sequences from sound and motion, and
exports a vertical 1080×1920 H.264 Reel.

## Run from source

Use Python 3.12 and install FFmpeg so `ffmpeg.exe` and `ffprobe.exe` are on
`PATH`:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python -m pip install -r .\requirements.txt
.\.venv\Scripts\python .\run_reelforge.py
```

## Build the packaged app

From this directory:

```powershell
.\build.ps1
```

The build script runs the Windows tests, bundles FFmpeg and FFprobe through the
PyInstaller spec, and creates `ReelForge-Windows-x64.zip` at the repository
root. The GitHub release workflow performs the same build on a Windows runner.

Google Drive import is intentionally public-only. It does not request a Google
account or OAuth token, and it does not upload the rendered Reel.
