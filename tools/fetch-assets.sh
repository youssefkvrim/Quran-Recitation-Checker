#!/usr/bin/env bash
# Fetch the Zipformer model and phoneme corpus (NPL-1.2, not committed) into assets/.
# The Xcode project bundles them from there; RecitationKit's tests read the corpus.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO/assets"
BASE="https://github.com/yazinsai/tilawa/releases/download/v0.3.0"
mkdir -p "$DEST"

fetch() {
  local name="$1" sha="$2"
  if [[ -f "$DEST/$name" ]] && echo "$sha  $DEST/$name" | sha256sum -c --status 2>/dev/null; then
    echo "ok       $name"; return
  fi
  echo "download $name"
  curl -fL --retry 3 --retry-delay 2 -o "$DEST/$name.part" "$BASE/$name"
  echo "$sha  $DEST/$name.part" | sha256sum -c --status || { echo "checksum mismatch for $name" >&2; exit 1; }
  mv "$DEST/$name.part" "$DEST/$name"
}

command -v sha256sum >/dev/null || sha256sum() { shasum -a 256 "$@"; }
fetch zipformer_interp_gentle_a05.int8.onnx eaf099afefbe5cc8c9aee74df864ce7cc69744271e4f3bb46ef6c17612fbe335
fetch zipformer_quran.json 24360c05ec88fcacf3419c1fe6cd81d69e653326a0bf0e4fb507e7b98fc88127
