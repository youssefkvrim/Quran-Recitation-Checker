import Foundation
import Testing
@testable import RecitationKit

enum Paths {
  static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  static let vectors = repo.appendingPathComponent("spec/vectors")
  static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

  /// `zipformer_quran.json` (NPL-1.2, not committed): `ZIPFORMER_CORPUS` or `assets/`.
  static var corpus: URL? {
    let candidates: [String?] = [ProcessInfo.processInfo.environment["ZIPFORMER_CORPUS"], repo.appendingPathComponent("assets/zipformer_quran.json").path]
    return candidates.compactMap { $0 }.map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
  }
}

enum Shared {
  static let corpus: QuranCorpus? = Paths.corpus.flatMap { try? QuranCorpus(json: Data(contentsOf: $0)) }
  static let index: QuranIndex? = corpus.map { QuranIndex(corpus: $0) }
}

/// Skip corpus-dependent tests when the corpus is not present.
let hasCorpus = Shared.corpus != nil

func vector(_ name: String) throws -> JSONValue {
  try JSONValue.load(Paths.vectors.appendingPathComponent(name))
}

/// Replays a fixed token id per CTC frame (250 = blank), scored like tools/make-golden.mts.
final class ScriptedBackend: ZipformerBackend {
  let frames: [Int]
  let high: Float, second: Float, low: Float
  private(set) var position = 0
  private(set) var runs = 0

  init(frames: [Int], high: Float = Float(log(0.9)), second: Float = Float(log(0.05)), low: Float = Float(log(0.001))) {
    self.frames = frames
    self.high = high
    self.second = second
    self.low = low
  }

  var done: Bool { position >= frames.count }

  func reset() {}

  func run(features: [Float]) throws -> [Float] {
    runs += 1
    var out = [Float](repeating: low, count: 12 * 251)
    for f in 0..<12 {
      let id = position < frames.count ? frames[position] : 250
      position += 1
      out[f * 251 + id] = high
      out[f * 251 + (id + 1) % 251] = second
    }
    return out
  }
}

extension WordVerdict {
  var json: [String: Any] {
    ["surah": surah, "ayah": ayah, "word": word, "wordIndex": wordIndex, "state": state.rawValue,
     "distance": distance, "heardRatio": heardRatio, "margin": margin, "vowelErrors": vowelErrors, "vowelMargin": vowelMargin]
  }
}

extension EngineEvent {
  var json: [String: Any] {
    switch self {
    case let .located(surah, ayah, word, replayed):
      return ["type": "located", "surah": surah, "ayah": ayah, "word": word, "replayed": replayed]
    case let .relocated(from, to, word):
      return ["type": "relocated", "from": ["surah": from.surah, "ayah": from.ayah], "to": ["surah": to.surah, "ayah": to.ayah, "word": word]]
    case let .cursor(surah, ayah, word, wordIndex):
      return ["type": "cursor", "surah": surah, "ayah": ayah, "word": word, "wordIndex": wordIndex]
    case let .verdicts(changes):
      return ["type": "verdicts", "changes": changes.map(\.json)]
    case .lost: return ["type": "lost"]
    case let .idle(reason): return ["type": "idle", "reason": reason.rawValue]
    case let .completed(surah): return ["type": "completed", "surah": surah]
    case .locateFailed: return ["type": "locateFailed"]
    }
  }
}

extension AyahTally {
  var json: [String: Any] {
    var j: [String: Any] = ["surah": surah, "ayah": ayah, "ok": ok, "unsure": unsure, "wrong": wrong, "skipped": skipped,
                            "pending": pending, "words": words, "firstSeen": firstSeen]
    if bridged { j["bridged"] = true }
    return j
  }
}

extension RecitationEvent {
  /// The golden-fixture form of the v0.1 `WorkerOutbound` message.
  var json: [String: Any] {
    switch self {
    case let .verseCandidate(surah, ayah, confidence):
      return ["type": "verse_candidate", "stable": false, "final_flush": false,
              "candidates": [["surah": surah, "ayah": ayah, "confidence": confidence, "rank": 0, "source": "discovery"]]]
    case let .verseMatch(surah, ayah, confidence):
      return ["type": "verse_match", "surah": surah, "ayah": ayah, "confidence": confidence]
    case let .wordProgress(p):
      return ["type": "word_progress", "surah": p.surah, "ayah": p.ayah, "word_index": p.wordIndex,
              "total_words": p.totalWords, "matched_indices": p.matchedIndices]
    case let .rawTranscript(text, confidence):
      return ["type": "raw_transcript", "length": text.utf16.count, "confidence": confidence]
    case let .finalSequence(verses, confidence):
      return ["type": "final_sequence", "confidence": confidence,
              "verses": verses.map { ["surah": $0.surah, "ayah": $0.ayah, "confidence": $0.confidence] }]
    case let .correction(state, totalWords):
      var issue: Any = NSNull()
      if let i = state.issue {
        var j: [String: Any] = ["surah": i.surah, "ayah": i.ayah, "word": i.word, "wordIndex": i.wordIndex, "kind": i.kind.rawValue]
        if let w = i.words { j["words"] = w }
        issue = j
      }
      let resume: Any = state.resume.map { ["surah": $0.surah, "ayah": $0.ayah, "word": $0.word] as [String: Any] } ?? NSNull()
      return ["type": "correction", "totalWords": totalWords,
              "state": ["phase": state.phase.rawValue, "issue": issue, "resume": resume, "attempt": state.attempt,
                        "outcome": state.outcome.map { $0.rawValue as Any } ?? NSNull()]]
    case let .debug(.engine(ev)):
      return ["type": "debug", "event": ev.name, "data": ev.json]
    case let .debug(.fallback(hit)):
      return ["type": "debug", "event": "fallback",
              "data": ["surah": hit.surah, "ayah": hit.ayah, "distance": hit.distance, "how": hit.how.rawValue]]
    }
  }
}

/// Heard chars of a recitation with substitutions, deletions, insertions,
/// repeats (backward cursor moves) and pauses.
func perturbed(_ text: [Phone], seed: UInt32) -> [HeardChar] {
  var s = seed == 0 ? 1 : seed
  func r() -> Double {
    s = s &* 1_664_525 &+ 1_013_904_223
    return Double(s) / 4_294_967_296
  }
  let letters = Array("بتثجحخدذرزسشصضطظعغفقكلمنهوي".utf16)
  var out: [HeardChar] = []
  var frame = 0
  var i = 0
  while i < text.count {
    let roll = r()
    if roll < 0.04 {
      i += 1
      continue
    }
    let ch = roll < 0.1 ? letters[Int(r() * Double(letters.count))] : text[i]
    frame += r() < 0.03 ? 30 : 2
    out.append(HeardChar(ch: ch, frame: frame, margin: 0.3 + 0.7 * r()))
    if r() < 0.03 {
      frame += 1
      out.append(HeardChar(ch: letters[Int(r() * Double(letters.count))], frame: frame, margin: 0.4))
    }
    if r() < 0.01 && i > 12 { i -= 12 }
    i += 1
  }
  return out
}

func recitation(_ corpus: QuranCorpus, _ surah: Int, _ from: Int, _ to: Int) -> [Phone] {
  (from...to).flatMap { corpus.ayahPhonemes(surah, $0) }
}
