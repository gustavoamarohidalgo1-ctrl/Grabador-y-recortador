#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  Sources/Foco/RecordingTypes.swift Sources/Foco/FrameCompositor.swift Tests/CameraPlacementTest.swift \
  -o dist/camera-placement-test
./dist/camera-placement-test
