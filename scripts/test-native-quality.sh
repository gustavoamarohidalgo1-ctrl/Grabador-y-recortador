#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreImage -framework CoreText \
  Sources/Foco/RecordingTypes.swift Sources/Foco/FrameCompositor.swift Sources/Foco/CapturePresentation.swift \
  Sources/Foco/NativePreviewView.swift Sources/Foco/MediaFinalizer.swift Tests/NativeQualityTest.swift \
  -o dist/native-quality-test
./dist/native-quality-test
