#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  -framework AppKit -framework ScreenCaptureKit -framework AVFoundation -framework CoreImage \
  Sources/Foco/RecordingTypes.swift Sources/Foco/FrameCompositor.swift Sources/Foco/CapturePresentation.swift \
  Sources/Foco/PreviewEngine.swift Sources/Foco/LivePreviewController.swift Tests/LivePreviewTest.swift \
  -o dist/live-preview-test
./dist/live-preview-test
