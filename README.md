# Quran Recitation Checker

An iPhone app that listens while you recite. It works out which ayah you are on, follows you word by word, and in Correction mode stops you on a skipped or wrong word. Recognition runs entirely on the phone: it needs no network, and audio is never stored or sent anywhere.

## Layout

```
RecitationKit/   Swift package: the recognition engine. No UI and no ONNX dependency.
App/             SwiftUI iOS app (project.yml for XcodeGen)
spec/            engine behaviour spec + frozen oracle vectors the engine must match
tools/           asset fetch, Linux test runner, table/fixture generators
assets/          model + phoneme corpus (NPL-1.2, fetched, not committed)
```

## How it works

```
mic (AVAudioEngine, .measurement)  ->  16 kHz mono float
  -> Kaldi fbank, 80 bins                               RecitationKit/Fbank.swift
  -> streaming Zipformer2-CTC, one run per 480 ms        App: OnnxZipformerBackend (ONNX Runtime)
  -> greedy CTC over 251 tajweed phonemes               CtcDecoder.swift
  -> whole-Quran 5-gram index locates the ayah          Search.swift
  -> per-surah DP tracker follows word by word          Tracker.swift
  -> per-word verdicts (ok / unsure / wrong / skipped)  Verdicts.swift
  -> events: verse match, word progress, correction     Session.swift, Emission.swift, Correction.swift
```

`RecitationSession` is the whole engine behind one API: `feed(samples)`, `stop()`, `reset()`, `setMode(_:)` and `correct(_:)`. It takes any `ZipformerBackend`, so tests drive it with a scripted model and the app plugs in ONNX Runtime. In the app, the `RecognitionService` actor owns the session and serialises every call to it. The `@MainActor` `RecitationModel` turns the engine's events into UI state.

## Build and run

Requirements: Xcode 26 or later, and an iPhone on iOS 26 or later.

```bash
brew install xcodegen
cd App && xcodegen generate && open QuranRecitationChecker.xcodeproj
# generate also fetches the 66 MB model + 5.5 MB phoneme corpus into assets/ (tools/fetch-assets.sh)
```

Then, in Xcode:

1. Select the **QuranRecitationChecker** target, then **Signing & Capabilities**. Tick *Automatically manage signing* and pick your Apple ID's team; a free account works ("Personal Team"). If the bundle identifier is taken, change it to anything unique.
2. Plug in the iPhone, unlock it and trust the Mac. Turn on **Settings → Privacy & Security → Developer Mode**, which appears after the phone has been connected to Xcode, then restart the phone.
3. Choose the iPhone as the run destination and press **Run** (⌘R). The first build downloads ONNX Runtime and takes a few minutes.
4. If the phone says "Untrusted Developer", trust your Apple ID under **Settings → General → VPN & Device Management**, then run again.

The scheme runs the **Release** configuration. A Debug build of the engine is too slow to keep up with the microphone. A free account's install lasts 7 days; press Run again to renew it. Use a real device: the simulator's microphone path is not representative.

## Tests

```bash
cd RecitationKit && swift test          # macOS; reads ../assets/zipformer_quran.json
tools/swift.sh test                     # Linux or anywhere with Docker (swift:6.2-noble)
RUN_PERF=1 tools/swift.sh test -c release --filter Performance
tools/benchmark/run.sh                  # the full chain on 53 real recordings (needs Docker + Python)
```

`tools/benchmark/run.sh` runs the app's whole recognition chain on the v1 benchmark: Swift fbank, windowing and session, with ONNX Runtime running the model. That benchmark is 53 real recordings from 16 reciters, studio and phone. With the a0w model and the app's settings it scores **53/53**, the same as the web app's reference stack. It locates the ayah after a median of 3.5 s of audio.

The suite checks four things:

- **Spec vectors.** Every oracle in `spec/vectors/` matches bit-exactly. That covers fbank, CTC decoding, the cost table, alignment, hashing and search, waqf handling, engine events and host emission.
- **v0.1 parity.** 19 scripted sessions recorded from the v0.1 TypeScript engine replay to identical event streams. They cover single ayahs, long passages, skips, relocation, mistakes, pauses, mode switches and correction actions.
- **Invariants.** Incremental caches match a from-scratch recompute, and the correction controller behaves correctly.
- **Word mapping.** Every one of the 6236 ayahs' display words maps exactly onto the acoustic corpus words.

Tests that need the corpus are skipped when it is absent. CI (`.github/workflows/ci.yml`) runs the suite on Linux, then builds a Release app for iPhone on macOS. It publishes the result as an unsigned `QuranRecitationChecker.ipa` artifact, which can be signed and installed with your own Apple ID, for example with Sideloadly.

## Performance

These timings cover the engine's own work per 480 ms chunk: fbank, CTC decode, search, tracking, verdicts and emission. The model is scripted, so ONNX inference time is not included. Each run is a release build of one continuous recitation.

| Recitation | v0 (TS) | v0.1 (TS) | v0.2 (Swift) |
|---|---|---|---|
| al-Baqarah 1–120, 25 min, p50 | 34.9 ms | 5.1 ms | 3.7 ms (p99 5.4 ms) |
| al-Kahf 1–110, p50 | | | 1.95 ms |

Per-chunk cost stays flat over long sessions: v0 grew linearly with the length of the session.

### Latency

`LATENCY=1 tools/swift.sh test --filter LatencyProbe` replays the model's real decode of Alafasy reciting al-Fātiḥa through the session. It prints, for every word, when it was said and when the app showed it. Once the place is found, words appear 0.3–0.7 s after they are said: that is the model's 480 ms window. Finding the place is the long part, because the istiʿādha and basmala cannot say where a recitation is. In that recording al-Fātiḥa 1:2 was located at 9.3 s, with nothing shown before then. The app now follows the istiʿādha and basmala word by word, the first word at 1.1 s. It also locks surah openings right after the basmala, which fixes six surahs that used to lock onto al-Fātiḥa (spec appendix A).

On an iPhone, hold the status line under the record button to show the live profile. It updates every second and shows:

- model and engine time per 480 ms window (p50, p95, max),
- lag from microphone to result,
- the share of real time spent computing,
- thermal state, battery drain and memory headroom.

Touch and hold the readout to copy it.

## Licensing

The app code and RecitationKit are MIT (`LICENSE`). The Zipformer model and phoneme corpus are **NPL-1.2** Derivatives of Quran-Lab's work (`licenses/NPL-1.2.txt`, `NOTICE.md`). That licence forbids charging for the model or any feature it powers, and it is share-alike. So an App Store build that bundles them must be free, and the bundled assets stay NPL-1.2. The Amiri font is SIL OFL 1.1.

## History

- **v0** — the initial import: the `@tilawa/core` TypeScript SDK, the web demo and the Python research lab.
- **v0.1** — an audit of v0. Engine cost per chunk became flat over long sessions (7× faster at 25 minutes), and the demo mapped display words onto acoustic word indices. Stored recitations became readable only by the admin, and CI ran the demo's tests.
- **v0.2** — the native iOS app, with the engine ported to Swift and proven identical to v0.1. The web demo, the SDK and the lab were removed from this branch; they remain in history at v0.1.
