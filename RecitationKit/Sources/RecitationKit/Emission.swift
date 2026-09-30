// Verse emission policy (spec §11): per-word verdicts -> ayah-level events.

public let minWordFraction = 0.5
public let fallbackMaxDistance = 0.5
public let gapMaxWords = 3

public struct AyahTally: Equatable, Sendable {
  public var surah: Int
  public var ayah: Int
  public var ok = 0
  public var unsure = 0
  public var wrong = 0
  public var skipped = 0
  public var pending = 0
  public var words: Int
  public var firstSeen: Int
  /// Filled in by `bridgeGapAyahs`.
  public var bridged = false

  public var ref: AyahRef { AyahRef(surah: surah, ayah: ayah) }

  mutating func count(_ state: VerdictState) {
    switch state {
    case .ok: ok += 1
    case .unsure: unsure += 1
    case .wrong: wrong += 1
    case .skipped: skipped += 1
    case .pending: pending += 1
    }
  }

  /// (ok + unsure) / words.
  public var confidence: Double { words <= 0 ? 0 : Double(ok + unsure) / Double(words) }

  public func meetsGate(minWordFraction fraction: Double = minWordFraction) -> Bool {
    Double(ok + unsure) >= max(1, fraction * Double(words)) && wrong <= ok + unsure
  }
}

/// Insertion-ordered tallies (the reference host relies on JS `Map` order).
public struct TallyMap: Equatable, Sendable {
  public private(set) var order: [AyahRef] = []
  private var byRef: [AyahRef: AyahTally] = [:]

  public init() {}

  public var count: Int { order.count }
  public var values: [AyahTally] { order.map { byRef[$0]! } }
  public subscript(ref: AyahRef) -> AyahTally? { byRef[ref] }

  public mutating func set(_ t: AyahTally) {
    if byRef[t.ref] == nil { order.append(t.ref) }
    byRef[t.ref] = t
  }
}

/// Per-ayah counts from one verdict snapshot (not incremental).
public func snapshotTallies(_ verdicts: [WordVerdict], wordCount: (Int, Int) -> Int) -> TallyMap {
  var map = TallyMap()
  for v in verdicts {
    let ref = AyahRef(surah: v.surah, ayah: v.ayah)
    var t = map[ref] ?? AyahTally(surah: v.surah, ayah: v.ayah, words: wordCount(v.surah, v.ayah), firstSeen: map.count)
    t.count(v.state)
    map.set(t)
  }
  return map
}

/// Add `src` counts into `dest`, keeping the earlier `firstSeen`.
public func accumulateSnapshot(_ dest: inout TallyMap, _ src: TallyMap) {
  for s in src.values {
    guard var t = dest[s.ref] else {
      var copy = s
      copy.firstSeen = dest.count
      dest.set(copy)
      continue
    }
    t.ok += s.ok
    t.unsure += s.unsure
    t.wrong += s.wrong
    t.skipped += s.skipped
    t.pending += s.pending
    t.words = max(t.words, s.words)
    dest.set(t)
  }
}

public func mergeTallies(_ accumulated: TallyMap, _ current: TallyMap) -> TallyMap {
  var out = accumulated
  accumulateSnapshot(&out, current)
  return out
}

public func newlyEligibleAyahs(_ tallies: [AyahTally], alreadyEmitted: Set<AyahRef>, minWordFraction fraction: Double = minWordFraction) -> [AyahTally] {
  tallies.filter { $0.meetsGate(minWordFraction: fraction) && !alreadyEmitted.contains($0.ref) }
    .stableSorted { $0.firstSeen < $1.firstSeen }
}

/// Bridge a below-gate short ayah only when both neighbours already emit (off by default).
public func bridgeGapAyahs(_ accepted: [AyahTally], _ tallies: [AyahTally], gapMaxWords maxWords: Int = gapMaxWords) -> [AyahTally] {
  var have = Set(accepted.map(\.ref))
  var extra: [AyahTally] = []
  for t in tallies {
    if have.contains(t.ref) || t.words > maxWords || t.ok + t.unsure < 1 || t.wrong > t.ok + t.unsure { continue }
    guard have.contains(AyahRef(surah: t.surah, ayah: t.ayah - 1)), have.contains(AyahRef(surah: t.surah, ayah: t.ayah + 1)) else { continue }
    var bridged = t
    bridged.bridged = true
    extra.append(bridged)
    have.insert(t.ref)
  }
  if extra.isEmpty { return accepted }
  return (accepted + extra).stableSorted { $0.firstSeen < $1.firstSeen }
}

public func fallbackConfidence(_ distance: Double) -> Double {
  distance.isFinite ? min(1, max(0, 1 - distance)) : 0
}

public struct FinalVerse: Equatable, Sendable {
  public var surah: Int
  public var ayah: Int
  public var confidence: Double
}

public func buildFinalSequence(_ tallies: [AyahTally], fallback: FallbackHit?, minWordFraction fraction: Double = minWordFraction) -> (verses: [FinalVerse], confidence: Double) {
  let gated = tallies.filter { $0.meetsGate(minWordFraction: fraction) }
    .stableSorted { $0.firstSeen < $1.firstSeen }
    .map { FinalVerse(surah: $0.surah, ayah: $0.ayah, confidence: $0.confidence) }
  if !gated.isEmpty {
    return (gated, gated.reduce(0) { $0 + $1.confidence } / Double(gated.count))
  }
  if let fallback {
    let c = fallbackConfidence(fallback.distance)
    return ([FinalVerse(surah: fallback.surah, ayah: fallback.ayah, confidence: c)], c)
  }
  return ([], 0)
}

public struct WordProgress: Equatable, Sendable {
  public var surah: Int
  public var ayah: Int
  /// The tracker's cursor word within the ayah.
  public var wordIndex: Int
  public var totalWords: Int
  /// Words of this ayah judged ok or unsure.
  public var matchedIndices: [Int]
}

public func wordProgress(cursor: (surah: Int, ayah: Int, word: Int), verdicts: [WordVerdict], totalWords: Int) -> WordProgress {
  let matched = verdicts
    .filter { $0.surah == cursor.surah && $0.ayah == cursor.ayah && ($0.state == .ok || $0.state == .unsure) }
    .map(\.word)
    .sorted()
  return WordProgress(surah: cursor.surah, ayah: cursor.ayah, wordIndex: cursor.word, totalWords: totalWords, matchedIndices: matched)
}

/// `Math.round(x * 100) / 100` (JS rounds ties toward +∞).
func roundToHundredths(_ x: Double) -> Double {
  let y = x * 100
  var r = y.rounded(.toNearestOrAwayFromZero)
  if y < 0 && r - y == -0.5 { r += 1 }
  return r / 100
}
