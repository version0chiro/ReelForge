#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
build_root="$project_root/.build/native"
app_root="$project_root/dist/ReelForge.app"
sdk_root="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"

if [[ ! -d "$sdk_root" ]]; then
  sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$build_root"
mkdir -p "$app_root/Contents/MacOS"
mkdir -p "$app_root/Contents/Resources"

architecture_binaries=()
for architecture in arm64 x86_64; do
  binary="$build_root/ReelForge-$architecture"
  swiftc \
    -sdk "$sdk_root" \
    -target "$architecture-apple-macos14.0" \
    -O \
    -parse-as-library \
    "$project_root"/Sources/ReelForgeMac/*.swift \
    -o "$binary" \
    -framework SwiftUI \
    -framework AVKit \
    -framework AppKit \
    -framework AVFoundation \
    -framework CoreImage
  architecture_binaries+=("$binary")
done

lipo -create "${architecture_binaries[@]}" -output "$build_root/ReelForge"

cp "$build_root/ReelForge" "$app_root/Contents/MacOS/ReelForge"
cp "$project_root/Resources/Info.plist" "$app_root/Contents/Info.plist"
codesign --force --deep --sign - "$app_root"

echo "$app_root"
