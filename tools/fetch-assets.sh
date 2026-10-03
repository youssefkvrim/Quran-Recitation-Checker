#!/usr/bin/env bash
# Fetch the Zipformer model and phoneme corpus (NPL-1.2, not committed) into assets/.
# The Xcode project bundles them from there; RecitationKit's tests read the corpus.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO/assets"
BASE="https://github.com/yazinsai/tilawa/releases/download"
mkdir -p "$DEST"

# GNU and BSD sha256sum take different flags (macOS 15+ ships the BSD one), so
# compare digests instead of using `-c`.
digest() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

fetch() {
  local name="$1" sha="$2"
  if [[ -f "$DEST/$name" && "$(digest "$DEST/$name")" == "$sha" ]]; then
    echo "ok       $name"; return
  fi
  echo "download $name"
  curl -fL --retry 3 --retry-delay 2 -o "$DEST/$name.part" "$BASE/$3/$name"
  [[ "$(digest "$DEST/$name.part")" == "$sha" ]] || { echo "checksum mismatch for $name" >&2; exit 1; }
  mv "$DEST/$name.part" "$DEST/$name"
}
# a0w-ep1-a0.5: the web app's default since 2026-10-02 (lower PER, no insertion-gate failures).
fetch zipformer_a0w_ep1_a05.int8.onnx bfb5b712695634a6099b45a6a78003bd5103417c4eae6338277d54679254905a zipformer-a0w-ep1-a0.5
fetch zipformer_quran.json 24360c05ec88fcacf3419c1fe6cd81d69e653326a0bf0e4fb507e7b98fc88127 v0.3.0
