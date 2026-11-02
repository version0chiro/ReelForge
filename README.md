# ReelForge

ReelForge is a desktop gameplay-montage editor focused on Instagram Reels and
other 9:16 short-form video. Give it several recordings—or a public Google
Drive folder—and it finds sustained high-energy sequences from sound and
visuals, creates an editable cut list, and exports an enhanced vertical MP4.

Version 0.4.0 includes:

- a native SwiftUI + AVFoundation app for macOS 14 or newer;
- a PySide6 + FFmpeg app for Windows x64;
- public Google Drive folder import without sign-in or OAuth;
- multi-video sound, onset, motion, scene-change, and action-position analysis;
- hook-first editing with source diversity, adjustable in/out points, ordering,
  removal, and crop focus;
- adaptive 9:16 framing for low-resolution landscape gameplay;
- 1080×1920 H.264/AAC output with Lanczos scaling, light tonal recovery, and
  restrained sharpening.

## Download

GitHub Releases produces two archives:

- `ReelForge-macOS-universal.zip` (Apple Silicon and Intel)
- `ReelForge-Windows-x64.zip`

The current builds are unsigned developer releases. macOS is ad-hoc signed but
not notarized; Windows is not Authenticode-signed, so either operating system
may ask for confirmation on first launch.

## Public Google Drive flow

1. In Google Drive, set the source folder’s General access to **Anyone with the
   link**.
2. Paste its `/drive/folders/...` URL into ReelForge.
3. ReelForge recursively finds public MP4, MOV, and M4V files, downloads them
   into an app-owned temporary folder, and begins the montage scan.
4. Review the selected cuts and export the improved Reel to a local folder.

This is intentionally public and download-only. ReelForge does not request a
Google account, enumerate private Drive files, or upload the result. Google
may still reject a file when its sharing permission, malware-warning
confirmation, or public-download quota prevents access.

## macOS

Build and open the native app:

```bash
./scripts/test-native.sh
./scripts/build-app.sh
open ./dist/ReelForge.app
```

You can also double-click `start.command`. The build script compiles and
ad-hoc signs the application bundle.

The macOS edition uses one custom AVFoundation/Core Image compositor for both
preview and export. Audio RMS/onsets and visual motion/scene signals are
robustly normalized per source. Candidate clips are ranked using peak,
sustained-window, average, and simultaneous audio/visual strength.

## Windows

The packaged release includes FFmpeg and FFprobe. To run from source or build
the Windows archive yourself, see [`windows/README.md`](windows/README.md).

The Windows edition uses the same detector semantics as macOS. FFmpeg decodes
low-resolution analysis streams, NumPy computes audio and visual features, and
the final filter graph trims and concatenates the selected sequences into a
1080×1920 H.264/AAC export.

Run its deterministic tests:

```powershell
python -m unittest discover -s windows\tests -v
```

## Quality and upscaling

“Enhanced” export is deterministic resampling and detail recovery, not
generative super-resolution. It reduces avoidable softness from browser
recording, low bitrates, and unnecessary extreme center crops while preserving
the original action.

For landscape or low-resolution footage, adaptive mode builds a softly blurred
vertical background and keeps a high-quality full-frame foreground. Portrait
footage can use action-position guidance to fill 9:16. A future optional
Real-ESRGAN/Core ML stage could add neural super-resolution, but it would be
slower and substantially increase the release size.

## Verification

macOS:

```bash
./scripts/test-native.sh
./scripts/build-smoke.sh
./.build/native/reelforge-smoke output.mp4 source-1.mp4 source-2.mp4 source-3.mp4
```

The multi-video sample validation decoded three low-resolution H.264/AAC
sources, selected a scored sequence from every source, and produced a
1080×1920, 30 fps H.264/AAC montage.

GitHub Actions runs:

- macOS detector tests, app compilation, and signature verification;
- Windows detector/Drive tests and an offscreen desktop startup test;
- tag-triggered macOS and Windows packaging, packaged-app smoke tests,
  checksums, and GitHub Release publication.

## Design references

ReelForge was informed by, but does not vendor or copy, these public projects:

- [Kadr](https://github.com/pietrodito/Kadr) and
  [ClipForge](https://github.com/longbridge/ClipForge) for native Swift editor
  structure;
- [Arc-shot’s compositor notes](https://github.com/mameshivaa/Arc-shot/blob/main/docs/articles/compositor-pipeline.md)
  and [VideoLab](https://github.com/ruanjx/VideoLab) for AVFoundation custom
  composition patterns;
- [gdown](https://github.com/wkentaro/gdown) for the established public-folder
  approach of reading Drive’s embedded folder view and following public file
  download confirmations;
- [FFmpeg](https://github.com/FFmpeg/FFmpeg) for cross-platform decoding,
  filter graphs, and H.264/AAC encoding;
- [PyInstaller](https://github.com/pyinstaller/pyinstaller) and
  [Qt for Python](https://github.com/pyside/pyside-setup) for the packaged
  Windows desktop application;
- [Video2X](https://github.com/k4yt3x/video2x) and
  [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) as references for a
  possible future neural-upscaling sidecar.

The public Drive implementation was compared against gdown commit
`b883e7a29e4d4b9209ac41730875347698f09ad4`; only the protocol-level approach
was reimplemented in platform-native code.

## Repository layout

```text
Sources/ReelForgeMac/       native macOS application
Tools/                      macOS deterministic and real-media smoke runners
windows/reelforge_windows/  Windows UI, detector, Drive client, and renderer
.github/workflows/          CI and cross-platform release packaging
```

The root-level HTML/JavaScript files are the earlier browser prototype. They
remain for comparison, but the supported release targets are the native macOS
and Windows applications.
