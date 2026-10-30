#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
xcrun swiftc -swift-version 5 -O -D PAUSE_TEST -target arm64-apple-macos15.0 \
  Sources/Foco/RecordingTypes.swift Sources/Foco/RecordingTimeline.swift \
  Sources/Foco/FrameCompositor.swift Sources/Foco/MediaFinalizer.swift \
  Sources/Foco/VideoTrimmer.swift Tests/MediaSelfTest.swift Tests/TrimSelfTest.swift \
  -o dist/trim-self-test
./dist/trim-self-test
