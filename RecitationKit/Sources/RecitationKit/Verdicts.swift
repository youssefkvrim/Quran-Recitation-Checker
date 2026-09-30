private let segmentCut = 300
private let contextChars = 6
/// How far past a word's span `stopBoundary` looks for a pause.
private let stopLookahead = 4

private let fathatan: Phone = 0x064B
private let dammatan: Phone = 0x064C
private let kasratan: Phone = 0x064D
private let taMarbuta: Phone = 0x0629
private let alif: Phone = 0x0627
private let cluster = Set("نںم۾وۥيۦلر".utf16)

/// The stopped (waqf) pronunciation of a word, or nil to judge the flowing
/// form only (spec §9.1).
public func pausalPhonemes(_ phonemes: [Phone], plain: String, atAyahEnd: Bool) -> [Phone]? {
  if atAyahEnd || phonemes.count < 2 { return nil }
  let plainUnits = Set(plain.utf16)
  var result: [Phone]?
  if let tanween = [fathatan, dammatan, kasratan].first(where: { plainUnits.contains($0) }) {
    var stem = phonemes
    if let last = stem.last, cluster.contains(last) {
      var i = stem.count - 1
      while i >= 0 && stem[i] == last { i -= 1 }
      stem = Array(stem[0...i])
    }
    let vowel: Phone = tanween == fathatan ? Phonemes.fatha : tanween == dammatan ? Phonemes.damma : Phonemes.kasra
    guard stem.last == vowel else { return nil }
    if tanween == fathatan && !plainUnits.contains(taMarbuta) {
      result = stem + [alif, alif]
    } else {
      result = Array(stem.dropLast())
    }
  } else if let last = phonemes.last, Phonemes.isShortVowel(last) {
    result = Array(phonemes.dropLast())
  }
  guard let r = result, !r.isEmpty, r != phonemes else { return nil }
  return r
}

private func stopBoundary(_ heard: [HeardChar], from: Int, to: Int, settleFrames: Int) -> Int {
  let end = min(heard.count, to + stopLookahead)
  var i = from + 1
  while i <= end {
    if i == heard.count { return i }
    if heard[i].frame - heard[i - 1].frame >= settleFrames { return i }
    i += 1
  }
  return -1
}

/// Aligned short-vowel substitutions inside one word, and the smallest
/// p(heard vowel) − p(expected vowel) among them. The expected word's final
/// vowel is ignored: waqf drops it, and the model's prior rewrites case endings.
public func vowelMismatches(
  heard: [HeardChar], from: Int, heardSlice: [Phone], expected: [Phone], table: CostTable = .shared
) -> (errors: Int, margin: Double) {
  if heardSlice.isEmpty || expected.isEmpty { return (0, 0) }
  let assign = alignGlobal(Phonemes.encode(heardSlice), Phonemes.encode(expected), from: 0, to: expected.count, table: table)
  var errors = 0
  var margin = Double.infinity
  let lastVowel = Phonemes.isShortVowel(expected[expected.count - 1]) ? expected.count - 1 : -1
  for (i, j) in assign.enumerated() where j >= 0 {
    let hc = heardSlice[i]
    let ec = expected[j]
    if hc == ec || !Phonemes.isShortVowel(hc) || !Phonemes.isShortVowel(ec) { continue }
    if j == lastVowel { continue }
    errors += 1
    var m = 0.0
    if from + i < heard.count {
      let h = heard[from + i]
      m = h.margin
      if let v = h.vowels { m = v[vowelIndex(hc)] - v[vowelIndex(ec)] }
    }
    if m < margin { margin = m }
  }
  return (errors, errors > 0 ? margin : 0)
}

private func vowelIndex(_ ch: Phone) -> Int {
  ch == Phonemes.fatha ? 0 : ch == Phonemes.damma ? 1 : 2
}

private struct Segment {
  var heardFrom: Int
  var heardTo: Int
  var refFrom: Int
  var refTo: Int
  var run: Int
  var contextFrom: Int
}

private struct SegmentKey: Hashable {
  var contextFrom: Int
  var heardTo: Int
  var refFrom: Int
  var refTo: Int
}

private struct Span {
  var from: Int
  var to: Int
  var run: Int
}

/// A judged word and the only inputs its verdict depends on.
private struct JudgedWord {
  var from: Int
  var to: Int
  var pending: Bool
  var interior: Bool
  var verdict: WordVerdict?
}

/// Per-word verdicts traced from the tracker's cursor trail (spec §9).
///
/// Called several times per audio chunk, so it is memoised on (tracker
/// revision, heard length, settled), and a word's verdict is reused once its
/// span, pending/interior status and the heard chars up to `stopLookahead`
/// past it are unchanged. Heard chars are append-only within a revision.
public final class VerdictTracer {
  private let tracker: Tracker
  private let table: CostTable
  private let cfg: EngineConfig
  private var segmentCache: [SegmentKey: [Int: Span]] = [:]
  private var cacheRevision = -1
  private var words: [Int: JudgedWord] = [:]
  private var memo: [(heardCount: Int, result: [WordVerdict])?] = [nil, nil]

  public init(tracker: Tracker, table: CostTable = .shared, config: EngineConfig = .default) {
    self.tracker = tracker
    self.table = table
    self.cfg = config
  }

  public func verdicts(settled: Bool = false) -> [WordVerdict] {
    let t = tracker
    if cacheRevision != t.revision {
      segmentCache.removeAll()
      words.removeAll()
      memo = [nil, nil]
      cacheRevision = t.revision
    }
    let slot = settled ? 1 : 0
    if let m = memo[slot], m.heardCount == t.heard.count { return m.result }
    let segs = segment(t.trail)
    var spans: [Int: Span] = [:]
    for (s, seg) in segs.enumerated() {
      let got: [Int: Span]
      if s == segs.count - 1 {
        got = alignSegment(seg)
      } else {
        let key = SegmentKey(contextFrom: seg.contextFrom, heardTo: seg.heardTo, refFrom: seg.refFrom, refTo: seg.refTo)
        if let cached = segmentCache[key] {
          got = cached
        } else {
          got = alignSegment(seg)
          segmentCache[key] = got
        }
      }
      for (w, sp) in got { spans[w] = sp }
    }
    let lastRun = segs.last?.run ?? 0
    let result = judge(spans, settled: settled, lastRun: lastRun)
    memo[slot] = (t.heard.count, result)
    return result
  }

  private func segment(_ trail: [Int32]) -> [Segment] {
    let n = trail.count
    if n == 0 { return [] }
    var segs: [Segment] = []
    var run = 0
    var runStart = 0
    var segStart = 0
    var prevSegStart = 0
    func push(_ to: Int) {
      if to <= segStart { return }
      let cell = Int(trail[segStart])
      let refFrom = cell <= 0 ? 0 : Int(tracker.wordStarts[Int(tracker.localWordOfPos[cell - 1])])
      let firstOfRun = segStart == runStart
      let contextFrom = firstOfRun && run == 0 ? segStart : max(prevSegStart, segStart - contextChars)
      segs.append(Segment(heardFrom: segStart, heardTo: to, refFrom: refFrom, refTo: Int(trail[to - 1]), run: run, contextFrom: contextFrom))
      prevSegStart = segStart
    }
    for g in 1...n {
      let newRun = g < n && trail[g] < trail[g - 1]
      let cut = g - segStart >= segmentCut
      if newRun || cut || g == n {
        push(g)
        if newRun {
          run += 1
          runStart = g
        }
        segStart = g
      }
    }
    return segs
  }

  private func alignSegment(_ seg: Segment) -> [Int: Span] {
    let t = tracker
    let ids = t.heard[seg.contextFrom..<seg.heardTo].map { Phonemes.id($0.ch) }
    let assign = alignGlobal(ids, t.ref, from: seg.refFrom, to: seg.refTo, table: table)
    var first: [Int: Int] = [:]
    var last: [Int: Int] = [:]
    for (i, refIndex) in assign.enumerated() where refIndex >= 0 {
      let localWord = Int(t.localWordOfPos[refIndex])
      let gi = seg.contextFrom + i
      if first[localWord] == nil { first[localWord] = gi }
      last[localWord] = gi
    }
    var spans: [Int: Span] = [:]
    for (w, f) in first { spans[w] = Span(from: f, to: last[w]! + 1, run: seg.run) }
    return spans
  }

  private func judge(_ spans: [Int: Span], settled: Bool, lastRun: Int) -> [WordVerdict] {
    guard let minWord = spans.keys.min(), let maxWord = spans.keys.max() else { return [] }
    let t = tracker
    let cursorWord = max(0, t.cursorLocalWord)
    let cursorPending = !t.reachedEnd && !settled
    let dwell = settled ? 0 : cfg.commitDwell
    let heardCount = t.heard.count
    var out: [WordVerdict] = []
    for w in minWord...maxWord {
      let span = spans[w]
      var pending = w == cursorWord && cursorPending
      if let span {
        pending = pending || span.to > heardCount - dwell || (span.run < lastRun && w >= cursorWord)
      }
      let interior = minWord < w && w < maxWord
      let from = span?.from ?? -1
      let to = span?.to ?? -1
      let verdict: WordVerdict?
      if let c = words[w], c.from == from, c.to == to, c.pending == pending, c.interior == interior {
        verdict = c.verdict
      } else {
        verdict = judgeWord(w, span, pending: pending, interior: interior)
        // Final once the pause lookahead past the span has been heard.
        if span == nil || to + stopLookahead < heardCount {
          words[w] = JudgedWord(from: from, to: to, pending: pending, interior: interior, verdict: verdict)
        }
      }
      if let verdict { out.append(verdict) }
    }
    return out
  }

  private func judgeWord(_ w: Int, _ span: Span?, pending: Bool, interior: Bool) -> WordVerdict? {
    let t = tracker
    let c = t.corpus
    let globalWord = t.firstWord + w
    let exp = Array(c.wordPhonemes(globalWord))
    let expLen = exp.count
    let heardCount = span.map { $0.to - $0.from } ?? 0
    if !pending && Double(heardCount) < cfg.minHeardFraction * Double(expLen) {
      guard interior else { return nil }
      let ratio = expLen > 0 ? Double(heardCount) / Double(expLen) : 0
      return makeVerdict(globalWord, .skipped, distance: 1, heardRatio: ratio, margin: 0)
    }
    guard let span else { return nil }
    let from = span.from
    var to = span.to
    var heardSlice = sliceHeard(from, to)
    var distance = normalizedDistance(Phonemes.encode(heardSlice), c.wordIds(globalWord), table: table)
    let loc = c.location(ofWord: globalWord)
    let atAyahEnd = loc.word == c.ayahWordCount(loc.surah, loc.ayah) - 1
    var expUsed = exp
    if distance > cfg.okDistance, let pausal = pausalPhonemes(exp, plain: c.plain[globalWord], atAyahEnd: atAyahEnd) {
      let stop = stopBoundary(t.heard, from: from, to: to, settleFrames: cfg.settleFrames)
      if stop >= 0 {
        if stop != to {
          to = stop
          heardSlice = sliceHeard(from, to)
        }
        let d2 = normalizedDistance(Phonemes.encode(heardSlice), Phonemes.encode(pausal), table: table)
        if d2 < distance {
          distance = d2
          expUsed = pausal
        }
      }
    }
    let vowels = pending ? (errors: 0, margin: 0.0) : vowelMismatches(heard: t.heard, from: from, heardSlice: heardSlice, expected: expUsed, table: table)
    var margin = 0.0
    let spanHeard = span.to - span.from
    if spanHeard > 0 {
      for i in span.from..<span.to { margin += t.heard[i].margin }
      margin /= Double(spanHeard)
    }
    let heardRatio = expLen > 0 ? Double(spanHeard) / Double(expLen) : 0
    let state: VerdictState
    if pending {
      state = .pending
    } else if distance <= cfg.okDistance {
      state = .ok
    } else if distance <= cfg.unsureDistance || margin < cfg.minMargin {
      state = .unsure
    } else {
      state = .wrong
    }
    return makeVerdict(globalWord, state, distance: distance, heardRatio: heardRatio, margin: margin,
                       vowelErrors: vowels.errors, vowelMargin: vowels.margin)
  }

  private func sliceHeard(_ from: Int, _ to: Int) -> [Phone] {
    let heard = tracker.heard
    let end = min(to, heard.count)
    return from < end ? heard[from..<end].map(\.ch) : []
  }

  private func makeVerdict(
    _ globalWord: Int, _ state: VerdictState, distance: Double, heardRatio: Double, margin: Double,
    vowelErrors: Int = 0, vowelMargin: Double = 0
  ) -> WordVerdict {
    let loc = tracker.corpus.location(ofWord: globalWord)
    return WordVerdict(surah: loc.surah, ayah: loc.ayah, word: loc.word, wordIndex: globalWord, state: state,
                       distance: distance, heardRatio: heardRatio, margin: margin,
                       vowelErrors: vowelErrors, vowelMargin: vowelMargin)
  }
}
