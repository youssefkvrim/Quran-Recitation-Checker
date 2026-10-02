/// How far into an opening istiʿādha or basmala the reciter is (v0.2).
///
/// The search skips both: the istiʿādha is not Quran text, and the basmala
/// opens 113 surahs, so neither says where the recitation is. Following them
/// word by word lets the app respond while the reciter is still on them,
/// seconds before the surah is known.
public struct PreambleProgress: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case istiadha, basmala
  }

  public var kind: Kind
  /// Words heard in full: up to 5 for the istiʿādha, 4 for the basmala.
  public var words: Int

  public init(kind: Kind, words: Int) {
    self.kind = kind
    self.words = words
  }

  public var wordCount: Int { kind == .istiadha ? 5 : 4 }
  public var isComplete: Bool { words == wordCount }
}

/// Where each word of `istiadhaPhonemes` and `basmalaPhonemes` ends.
let istiadhaWordEnds = [8, 17, 21, 32, 40]
let basmalaWordEnds = [5, 12, 22, 32]

/// The istiʿādha or basmala `heard` opens with, and how many of its words
/// are in, or nil when it opens with neither.
public func preambleProgress<C: Collection<UInt8>>(_ heard: C, table: CostTable = .shared) -> PreambleProgress? {
  let heard = Array(heard)
  var offset = 0
  var progress: PreambleProgress?
  for (kind, phrase, ends) in [(PreambleProgress.Kind.istiadha, istiadhaIds, istiadhaWordEnds), (.basmala, basmalaIds, basmalaWordEnds)] {
    var words = 0, consumed = 0
    for (i, end) in ends.enumerated() {
      // A word counts once nearly all of it is in: short words need all but one phoneme.
      let length = end - (i == 0 ? 0 : ends[i - 1])
      guard let len = prefixMatch(heard, from: offset, phrase[0..<end], shortBy: min(3, length / 3), table: table) else { break }
      words += 1
      consumed = len
    }
    guard words > 0 else { continue }
    progress = PreambleProgress(kind: kind, words: words)
    if words < ends.count { break }
    offset += consumed
  }
  return progress
}

/// The length of `heard[from...]` that best matches `phrase` (at most
/// `shortBy` shorter, 3 longer), if close enough to count as said.
private func prefixMatch(_ heard: [UInt8], from: Int, _ phrase: ArraySlice<UInt8>, shortBy: Int, table: CostTable) -> Int? {
  let rest = heard.count - from
  let lo = max(1, phrase.count - shortBy), hi = min(rest, phrase.count + 3)
  guard lo <= hi else { return nil }
  var best = Double.infinity, bestLen = 0
  for len in lo...hi {
    let d = normalizedDistance(heard[from..<(from + len)], phrase, table: table)
    if d < best || (d == best && abs(len - phrase.count) < abs(bestLen - phrase.count)) {
      best = d
      bestLen = len
    }
  }
  return best <= preambleMaxDistance ? bestLen : nil
}
