#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  Sources/Foco/RecordingTypes.swift Sources/Foco/RecordingTimeline.swift Sources/Foco/FrameCompositor.swift \
  Sources/Foco/MediaFinalizer.swift Tests/MediaSelfTest.swift -o dist/media-self-test
./dist/media-self-test
xcrun swiftc -swift-version 5 -O -D PAUSE_TEST -target arm64-apple-macos15.0 \
  Sources/Foco/RecordingTypes.swift Sources/Foco/RecordingTimeline.swift Sources/Foco/FrameCompositor.swift \
  Sources/Foco/MediaFinalizer.swift Tests/MediaSelfTest.swift Tests/PauseSelfTest.swift -o dist/pause-self-test
./dist/pause-self-test
