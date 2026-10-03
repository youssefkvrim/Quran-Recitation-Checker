#!/usr/bin/env bash
# Score the app's recognition on the v1 benchmark (53 real recordings, 16
# reciters, phone and studio) with the full chain, and print time-to-locate.
#
#   tools/benchmark/run.sh [model.onnx]     # default: assets/zipformer_a0w_ep1_a05.int8.onnx
#
# Needs Docker (Swift) and Python 3. The audio comes from tilawa's git history
# (branch autoresearch/setup, benchmark/test_corpus) into a cache dir; nothing
# is committed here. Pass VARIANT=original to score the spec-parity engine.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CACHE="${BENCHMARK_CACHE:-$HOME/.cache/qrc-benchmark}"
MODEL="${1:-$REPO/assets/zipformer_a0w_ep1_a05.int8.onnx}"
VARIANT="${VARIANT:-v02}"
mkdir -p "$CACHE"/{audio,pcm,win,lp}

if [[ ! -d "$CACHE/tilawa" ]]; then
  git clone -q --filter=blob:none --no-checkout https://github.com/yazinsai/tilawa "$CACHE/tilawa"
fi
if [[ ! -f "$CACHE/audio/manifest.json" ]]; then
  for p in $(git -C "$CACHE/tilawa" ls-tree -r --name-only origin/autoresearch/setup benchmark/test_corpus/); do
    [[ "$p" == *.gitkeep ]] || git -C "$CACHE/tilawa" show "origin/autoresearch/setup:$p" > "$CACHE/audio/$(basename "$p")"
  done
fi

[[ -d "$CACHE/venv" ]] || { python3 -m venv "$CACHE/venv"; "$CACHE/venv/bin/pip" -q install onnxruntime numpy av soxr; }
PY="$CACHE/venv/bin/python"
[[ -n "$(ls "$CACHE/pcm")" ]] || "$PY" "$HERE/decode.py" "$CACHE/audio" "$CACHE/pcm"

run() {
  docker run --rm -v "$REPO:/repo" -v "$CACHE:/cache" -w /repo/tools/benchmark \
    -e CORPUS=/repo/assets/zipformer_quran.json "${SWIFT_IMAGE:-swift:6.2-noble}" bash -c "$1"
}
run 'swift build -c release -q --scratch-path /cache/build'
run 'for f in /cache/pcm/*.f32; do /cache/build/release/Benchmark dump $f /cache/win/$(basename $f); done'
for f in "$CACHE"/win/*.f32; do
  "$PY" "$HERE/run_model.py" "$MODEL" "$REPO/spec/vectors/zipformer_io.json" "$f" "$CACHE/lp/$(basename "$f")"
done
run "for f in /cache/pcm/*.f32; do n=\$(basename \$f .f32); echo \"\$n model $VARIANT \$(/cache/build/release/Benchmark replay \$f /cache/lp/\$n.f32 $VARIANT)\"; done" > "$CACHE/results.txt"
"$PY" "$HERE/score.py" "$CACHE/audio/manifest.json" "$CACHE/results.txt" -v
