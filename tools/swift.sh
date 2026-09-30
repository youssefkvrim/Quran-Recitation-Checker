#!/usr/bin/env bash
# Run SwiftPM for RecitationKit on Linux (CI, or anywhere without Xcode) in the
# official Swift image. On a Mac, just use `swift test` in RecitationKit/.
#   tools/swift.sh test            tools/swift.sh test -c release --filter Performance
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
exec docker run --rm -v "$REPO:/repo" -w /repo/RecitationKit \
  -e ZIPFORMER_CORPUS=/repo/assets/zipformer_quran.json -e RUN_PERF \
  "${SWIFT_IMAGE:-swift:6.2-noble}" swift "$@"
