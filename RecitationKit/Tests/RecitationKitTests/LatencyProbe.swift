import Foundation
import Testing
@testable import RecitationKit

/// Opt-in (`LATENCY=1`): replays the model's real decode of Alafasy reciting
/// al-Fatiha (spec/vectors/ctc_ea_alafasy_multi_001_001_007.json) through the
/// full session in 85 ms microphone chunks, and prints for every word when it
/// was spoken, when the model's output for it became available, and when the
/// app first showed the reciter at or past it.
@Suite("Latency probe", .enabled(if: ProcessInfo.processInfo.environment["LATENCY"] == "1" && hasCorpus))
struct LatencyProbe {
  @Test(arguments: [0, 1, 2]) func fatihaByAlafasy(_ variant: Int) throws {
    let v02 = variant > 0
    let c = Shared.corpus!
    let v = try vector("ctc_ea_alafasy_multi_001_001_007.json")
    let tokens = v["tokens"].array.map { CtcToken($0["sym"].string, frame: $0["frame"].int, margin: $0["margin"].double) }
    var frames = [Int](repeating: 250, count: v["framesDecoded"].int + 200)
    for t in tokens { frames[t.frame] = zipformerTokens.firstIndex(of: String(decoding: t.symbol, as: UTF16.self))! }

    // Which corpus word each heard phoneme belongs to.
    let heard = expandTokens(tokens)
    let from = c.ayahFirstWord(1, 1), to = c.ayahFirstWord(1, 7) + c.ayahWordCount(1, 7)
    let assign = alignGlobal(heard.map { Phonemes.id($0.ch) }, c.ids, from: Int(c.wordStart[from]), to: Int(c.wordStart[to]))
    var firstFrame = [Int: Int](), lastFrame = [Int: Int]()
    for (h, ref) in zip(heard, assign) where ref >= 0 {
      let word = (from..<to).last { Int(c.wordStart[$0]) <= ref + Int(c.wordStart[from]) }!
      firstFrame[word] = min(firstFrame[word] ?? .max, h.frame)
      lastFrame[word] = max(lastFrame[word] ?? -1, h.frame)
    }

    let backend = ScriptedBackend(frames: frames)
    var options = RecitationSession.Options()
    options.emitRawTranscript = false
    if v02 {
      options.emitPreamble = true
      options.config.surahOpenings = .standard
    }
    if variant == 2 {
      options.config.searchEveryChars = 1
      options.config.searchEveryFrames = 12
    }
    let session = RecitationSession(corpus: c, backend: backend, options: options)
    let name = ["original engine", "v0.2 openings + preamble", "v0.2 + search every window"][variant]
    let chunk = [Float](repeating: 0, count: 1365)
    var samples = 0
    var available: [(time: Double, frames: Int)] = []
    var shown = [Int: Double]()       // word -> first time the cursor was at or past it
    var located: Double?
    var log: [String] = []
    while backend.position < frames.count {
      let events = try session.feed(chunk)
      samples += chunk.count
      let t = Double(samples) / 16000
      available.append((t, backend.position))
      for e in events {
        switch e {
        case let .verseCandidate(s, a, _):
          located = located ?? t
          log.append(String(format: "%6.2f s  candidate %d:%d", t, s, a))
        case let .verseMatch(s, a, _):
          located = located ?? t
          log.append(String(format: "%6.2f s  match %d:%d", t, s, a))
        case let .preamble(p):
          log.append(String(format: "%6.2f s  %@ %d/%d", t, p.kind.rawValue, p.words, p.wordCount))
        case let .wordProgress(p):
          let g = try c.wordIndex(p.surah, p.ayah, p.wordIndex)
          for w in from...g where shown[w] == nil { shown[w] = t }
        default: break
        }
      }
    }
    func availableAt(_ frame: Int) -> Double { available.first { $0.frames > frame }?.time ?? .nan }
    print("LATENCY [\(name)] first located at \(located.map { String(format: "%.2f s", $0) } ?? "never")")
    log.forEach { print("LATENCY event \($0)") }
    print("LATENCY word        spoken    end   model-out  shown   lag(shown-start)  engine(shown-avail)")
    var lags: [Double] = [], engine: [Double] = []
    for w in from..<to {
      guard let f0 = firstFrame[w], let f1 = lastFrame[w] else { continue }
      let start = Double(f0) * 0.04, end = Double(f1 + 1) * 0.04, avail = availableAt(f0)
      let s = shown[w] ?? .nan
      lags.append(s - start); engine.append(s - avail)
      let loc = c.location(ofWord: w)
      print(String(format: "LATENCY %d:%d:%-2d     %6.2f  %6.2f  %6.2f   %6.2f   %6.2f            %6.2f",
                   loc.surah, loc.ayah, loc.word, start, end, avail, s, s - start, s - avail))
    }
    let sorted = lags.filter { !$0.isNaN }.sorted(), es = engine.filter { !$0.isNaN }.sorted()
    print(String(format: "LATENCY lag p50 %.2f s  max %.2f s   engine-only p50 %.2f s  max %.2f s  (%d words)",
                 sorted[sorted.count / 2], sorted.last!, es[es.count / 2], es.last!, sorted.count))
  }
}

extension LatencyProbe {
  /// Every search the engine runs while locating, with what it saw.
  @Test func fatihaSearchSteps() throws {
    let c = Shared.corpus!, index = Shared.index!, cfg = EngineConfig.default
    let v = try vector("ctc_ea_alafasy_multi_001_001_007.json")
    let tokens = v["tokens"].array.map { CtcToken($0["sym"].string, frame: $0["frame"].int, margin: $0["margin"].double) }
    var buffer: [HeardChar] = []
    var lastHeard = 0, lastFrame = 0
    for run in 1...40 {
      let decoded = run * 12
      buffer += expandTokens(tokens.filter { $0.frame >= decoded - 12 && $0.frame < decoded })
      let due = buffer.count >= cfg.searchMinChars
        && (buffer.count - lastHeard >= cfg.searchEveryChars || (buffer.count - lastHeard > 0 && decoded - lastFrame >= cfg.searchEveryFrames))
      guard due else { continue }
      lastHeard = buffer.count; lastFrame = decoded
      let ids = buffer.suffix(cfg.searchQueryChars).map { Phonemes.id($0.ch) }
      let strip = stripPreambles(ids)
      let r = index.search(ids)
      let hits = r.hits.map { String(format: "%d:%d:%d d=%.2f q=%d", $0.surah, $0.ayah, $0.word, $0.distance, $0.queryStart) }.joined(separator: " | ")
      let text = String(decoding: buffer.map(\.ch), as: UTF16.self)
      print(String(format: "SEARCH t=%5.2f s  chars %3d  strip %2d basmala %@  decisive %@  %@", Double(48 * run + 61) / 100, ids.count, strip.offset,
                   strip.basmala ? "y" : "n", r.decisive ? "YES" : "no ", hits))
      print("SEARCH        heard: \(text.suffix(60))")
      if r.decisive { break }
    }
  }
}

extension LatencyProbe {
  /// The search with and without `surahOpenings` on basmala + every surah
  /// opening (clean and perturbed), and on basmala + every mid-surah ayah.
  @Test func surahStartSweep() throws {
    let c = Shared.corpus!
    func index(_ minChars: Int, _ quranMargin: Double) -> QuranIndex {
      var cfg = EngineConfig.default
      var rule = SurahOpenings.Rule.standard
      rule.minChars = minChars
      rule.quranMargin = quranMargin
      cfg.surahOpenings = rule
      return QuranIndex(corpus: c, config: cfg)
    }
    let indices = [("original", Shared.index!), ("openings standard", index(10, 0.05)), ("openings min10 q0", index(10, 0))]
    func phones(from word: Int, end: Int) -> [Phone] {
      let a = Int(c.wordStart[word]); return Array(c.text[a..<min(Int(c.wordStart[end]), a + 80)])
    }
    struct Case { let ids: [UInt8]; let truth: Int? }
    var starts: [Case] = [], noisy: [Case] = [], mids: [Case] = []
    for s in c.surahs where s.number != 9 {
      let from = s.number == 1 ? c.ayahFirstWord(1, 2) : s.firstWord
      let text = phones(from: from, end: s.endWord)
      starts.append(Case(ids: Phonemes.encode(text), truth: s.firstWord))
      for seed in 1...3 as ClosedRange<UInt32> {
        noisy.append(Case(ids: perturbed(text, seed: seed + UInt32(s.number) * 7).map { Phonemes.id($0.ch) }, truth: s.firstWord))
      }
      if s.ayahCount >= 2 {
        for a in 2...s.ayahCount where !(s.number == 27 && a == 31) && !(s.number == 1 && a == 2) {
          let text = phones(from: c.ayahFirstWord(s.number, a), end: s.endWord)
          mids.append(Case(ids: Phonemes.encode(text), truth: nil))
          if a % 4 == 0 { mids.append(Case(ids: perturbed(text, seed: UInt32(a)).map { Phonemes.id($0.ch) }, truth: nil)) }
        }
      }
    }
    let basmala = Phonemes.encode(basmalaPhonemes)
    for (name, index) in indices {
      func firstLock(_ ids: [UInt8], upTo: Int) -> (k: Int, w: Int)? {
        for k in 1...min(upTo, ids.count) {
          let r = index.search(basmala + ids[0..<k])
          if r.decisive, let h = r.hits.first { return (k, h.surah == 1 && h.ayah <= 2 ? 0 : h.wordIndex) }
        }
        return nil
      }
      for (set, cases) in [("clean", starts), ("noisy", noisy)] {
        var ks: [Int] = [], wrong: [String] = []
        for cs in cases {
          guard let l = firstLock(cs.ids, upTo: 80) else { continue }
          if l.w == cs.truth { ks.append(l.k) } else { wrong.append("\(c.location(ofWord: cs.truth!).surah)→\(c.location(ofWord: l.w).surah)") }
        }
        ks.sort()
        print("SWEEP \(name) \(set): ok \(ks.count)/\(cases.count) wrong \(wrong.count) \(wrong.prefix(12)) k50 \(ks[ks.count / 2]) k75 \(ks[ks.count * 3 / 4]) k90 \(ks[ks.count * 9 / 10])")
      }
      var falseLocks = 0
      for cs in mids where firstLock(cs.ids, upTo: SurahOpenings.maxChars).map({ c.location(ofWord: $0.w).surah == 1 || c.wordInAyah[$0.w] == 0 && c.wordAyah[$0.w] == 1 }) == true {
        falseLocks += 1
      }
      print("SWEEP \(name) mid-surah: locks on an opening or al-Fātiḥa within \(SurahOpenings.maxChars) chars: \(falseLocks)/\(mids.count)")
    }
  }
}
