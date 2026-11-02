#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
build_root="$project_root/.build/native"
sdk_root="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"

if [[ ! -d "$sdk_root" ]]; then
  sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$build_root"
swiftc \
  -sdk "$sdk_root" \
  -O \
  -parse-as-library \
  "$project_root/Sources/ReelForgeMac/PublicGoogleDrive.swift" \
  "$project_root/Tools/PublicDriveSmoke/main.swift" \
  -o "$build_root/public-drive-smoke"

echo "$build_root/public-drive-smoke"
