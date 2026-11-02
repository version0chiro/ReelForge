# ReelForge 0.4.0

ReelForge turns several gameplay recordings into an editable vertical montage.
This release includes native macOS and Windows editions.

## Highlights

- Finds sustained high-energy moments from audio onsets, loudness, motion, and
  scene changes across multiple source videos.
- Starts with a strong hook while preserving source diversity.
- Imports MP4, MOV, and M4V files from a public Google Drive folder URL, with no
  Google account or OAuth access.
- Exports a 1080×1920 H.264/AAC Reel with adaptive 9:16 framing, Lanczos
  resampling, and restrained detail recovery.
- Fixes the macOS stale-cut binding crash seen after rescanning or removing a
  selected sequence.
- Adds a Windows x64 desktop app and automated cross-platform release builds.

## Install notes

The macOS app is ad-hoc signed but not Apple-notarized. The Windows executable
is not Authenticode-signed. The operating system may therefore ask for an
extra confirmation on first launch.

Public Drive import is download-only. ReelForge saves the improved Reel to a
local location you choose; it does not upload back to Google Drive.
