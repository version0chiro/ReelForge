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
  "$project_root/Sources/ReelForgeMac/Models.swift" \
  "$project_root/Sources/ReelForgeMac/HighlightDetector.swift" \
  "$project_root/Sources/ReelForgeMac/PublicGoogleDrive.swift" \
  "$project_root/Sources/ReelForgeMac/SafeElementBinding.swift" \
  "$project_root/Tools/NativeTests/main.swift" \
  -o "$build_root/native-tests" \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVFoundation

"$build_root/native-tests"
