#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -lt 1 ]; then
  printf 'Uso: %s video-sintetico.mov [carpeta-resultados]\n' "$0" >&2
  printf 'Requiere un video sintético de al menos 10 s, 1920×1080 a 60 fps y una pista AAC.\n' >&2
  exit 2
fi
mkdir -p dist
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  Sources/Foco/RecordingTypes.swift Sources/Foco/MediaFinalizer.swift \
  Tests/FinalizerPerformanceTest.swift -o dist/finalizer-performance-test
./dist/finalizer-performance-test "$1" "${2:-dist/finalizer-performance-results}"
