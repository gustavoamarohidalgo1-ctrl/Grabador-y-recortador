#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/Foco.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -whole-module-optimization -target arm64-apple-macos15.0 \
  -framework SwiftUI -framework AppKit -framework ScreenCaptureKit -framework AVFoundation \
  -framework CoreImage -framework CoreMedia -framework CoreVideo -framework AudioToolbox -framework AVKit \
  Sources/Foco/*.swift -o "$APP/Contents/MacOS/Foco"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f dist/AppIcon.icns ]; then cp dist/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
codesign --force --sign - --entitlements entitlements.plist "$APP"
codesign --verify --deep --strict "$APP"
printf 'Aplicación compilada: %s\n' "$APP"
