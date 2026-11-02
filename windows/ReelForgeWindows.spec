from pathlib import Path


windows_root = Path(SPECPATH)
project_root = windows_root.parent
vendor_root = windows_root / "vendor"

binaries = []
for executable in ("ffmpeg.exe", "ffprobe.exe"):
    candidate = vendor_root / executable
    if not candidate.is_file():
        raise FileNotFoundError(
            f"{candidate} is missing. Run windows/build.ps1 after installing FFmpeg."
        )
    binaries.append((str(candidate), "."))

a = Analysis(
    [str(windows_root / "run_reelforge.py")],
    pathex=[str(windows_root)],
    binaries=binaries,
    datas=[],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=1,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="ReelForge",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    disable_windowed_traceback=False,
)
bundle = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name="ReelForge",
)
