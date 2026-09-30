# Quran Recitation Checker

Offline iPhone app that follows a Quran recitation word by word and flags mistakes. Everything runs on device.

## Layout

```
RecitationKit/                    # Swift package: the engine (pure Swift, no UI, no ONNX)
  Sources/RecitationKit/
    Session.swift                 #   RecitationSession: feed / stop / reset / setMode / correct -> [RecitationEvent]
    Fbank.swift, CtcDecoder.swift #   audio features, greedy CTC with peak margins + sibling vowels
    ZipformerRunner.swift         #   windowing over a ZipformerBackend (the app supplies ONNX)
    Search.swift, Tracker.swift, Verdicts.swift, Engine.swift   # locate, track, judge
    Emission.swift, Fallback.swift, Correction.swift            # host events, tallies, live correction
    Corpus.swift, QuranText.swift #   phoneme corpus, display text + display->acoustic word mapping
    *.generated.swift             #   tools/generate-swift-tables.py, do not edit
  Tests/RecitationKitTests/       # Swift Testing; Fixtures/sessions.json = v0.1 golden streams
App/                              # SwiftUI app, XcodeGen project.yml (the .xcodeproj is generated, ignored)
  QuranRecitationChecker/
    Audio/MicrophoneCapture.swift         # AVAudioEngine -> 16 kHz chunks
    Recognition/OnnxZipformerBackend.swift  # ONNX Runtime (ObjC API) ZipformerBackend
    Recognition/RecognitionService.swift    # actor owning the session
    RecitationModel.swift                   # @MainActor @Observable UI state
    Views/                                  # ContentView, PassageView, CorrectionSheet
spec/                             # recitation-engine-spec.md, live-correction.md, vectors/ (frozen oracles)
tools/                            # fetch-assets.sh, swift.sh, generate-swift-tables.py, make-golden.mts, make-quran-text.py
assets/                           # model + corpus from tools/fetch-assets.sh (NPL-1.2, gitignored)
```

## Build & test

```bash
tools/fetch-assets.sh                          # once; the tests and the app need assets/
cd RecitationKit && swift test                 # macOS
tools/swift.sh test                            # Linux (Docker, swift:6.2-noble)
RUN_PERF=1 tools/swift.sh test -c release --filter Performance
cd App && xcodegen generate                    # then build/run QuranRecitationChecker in Xcode
```

The suite must be green before merge. CI (`.github/workflows/ci.yml`) runs it on Linux, then builds the app for the iOS simulator on macOS.

## Engine rules

- **Behaviour is pinned.** `SpecVectorTests` match `spec/vectors/` bit for bit. `GoldenSessionTests` replay the v0.1 TypeScript engine's event streams. An optimisation must leave both untouched. For a deliberate behaviour change, update the spec, regenerate `Fixtures/sessions.json` (`tools/make-golden.mts` against the reference implementation), and explain the event diff in the commit body.
- **Float semantics.** Compute in `Double` and store in `Float`, which mirrors JS `Math.fround` on `Float32Array` writes. Sort with `stableSorted(by:)`, and iterate maps where insertion order matters (`TallyMap`). Split Arabic text on unicode scalars, not `Character`s.
- **One caller at a time.** `feed`, `stop` and `reset` share the streaming encoder state, so they must never overlap. In the app, `RecognitionService` (an actor) serialises them.
- **Hot path.** `feed` runs every 480 ms on device. Keep it allocation-light and incremental. `IncrementalTests` check that caches equal from-scratch recomputation; add to them when you add a cache.
- Add a deterministic test that needs no ONNX with every engine change.

## App rules

- Keep the UI minimal: the passage, one record button and a mode picker, plus the correction sheet.
- Audio and recognition never leave the device, and the app makes no network calls.
- The model and corpus are NPL-1.2. Never commit them, and never gate a feature they power behind payment.

## Worktree + merge discipline

Develop every change in a worktree under `./.worktrees/`, then merge back with `--no-ff`.

```bash
git worktree add .worktrees/<name> -b <name>
cd .worktrees/<name>
# ... implement, test ...
git commit                 # subject: "<area>: <what changed>" (<=72 chars); body: the why + before/after
git merge <name> --no-ff -m "Merge branch '<name>': ..."
git worktree remove .worktrees/<name>
```

Commits are authored as the repository owner, with no co-author trailers. Never skip hooks or bypass signing.
