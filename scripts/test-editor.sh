#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -f dist/trim-source.mp4 ]; then bash scripts/test-trim.sh; fi
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  Sources/Foco/RecordingTypes.swift Sources/Foco/VideoTrimmer.swift \
  Sources/Foco/VideoEditorModel.swift Tests/EditorPerformanceTest.swift \
  -o dist/editor-performance-test
dist/editor-performance-test
