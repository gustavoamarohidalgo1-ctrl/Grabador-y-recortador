#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework CoreVideo -framework CoreMedia -framework CoreImage \
  Sources/Foco/RecordingTypes.swift Sources/Foco/FrameCompositor.swift \
  Sources/Foco/CapturePresentation.swift Sources/Foco/NativePreviewView.swift \
  Tests/PresentationPerformanceTest.swift -o dist/presentation-performance-test
./dist/presentation-performance-test
