/// Istiʿādha as the model spells it (40 chars, not Quran text).
public let istiadhaPhonemes: [Phone] = Array("ءَعُۥۥذُبِللَااهِمِنَششَييطَاانِررَجِۦۦم".utf16)
/// Basmala (32 chars, = 1:1).
public let basmalaPhonemes: [Phone] = Array("بِسمِللَااهِررَحمَاانِررَحِۦۦۦۦم".utf16)

let istiadhaIds = Phonemes.encode(istiadhaPhonemes)
let basmalaIds = Phonemes.encode(basmalaPhonemes)

private let gram = 5
private let bucketBits = 18
private let buckets = 1 << bucketBits
private let bucketMask = UInt32(buckets - 1)
private let windowBits = 5
private let maxPostings = 400
private let candidateWindows = 24
private let verifyMarginBefore = 16
private let verifyMarginAfter = 32
private let minAligned = 20
private let surahGap = 8
private let shortQuery = 100
let preambleMaxDistance = 0.3
private let growingDistance = 0.35

/// FNV-1a over 5 ids, as JS computes it with `Math.imul` (spec §7.1).
@inline(__always)
func fnv1aBucket(_ ids: UnsafeBufferPointer<UInt8>, _ at: Int) -> Int {
  var h = Int32(bitPattern: 2_166_136_261)
  for k in 0..<gram { h = (h ^ Int32(ids[at + k])) &* 16_777_619 }
  return Int(UInt32(bitPattern: h) & bucketMask)
}

public func fnv1aBucket(_ ids: [UInt8], at: Int) -> Int {
  ids.withUnsafeBufferPointer { fnv1aBucket($0, at) }
}

/// Strip a leading istiʿādha and/or basmala (spec §7.6).
public func stripPreambles(_ query: [UInt8], table: CostTable = .shared) -> StripResult {
  var offset = 0
  var basmala = false
  var basmalaOffset = 0
  for (phrase, isBasmala) in [(istiadhaIds, false), (basmalaIds, true)] {
    let rest = query.count - offset
    if rest <= 0 { break }
    let l = phrase.count
    var bestLen = -1
    var bestDist = Double.infinity
    var bestTie = Int.max
    let lo = max(1, l - 4)
    let hi = min(rest, l + 4)
    if lo <= hi {
      for len in lo...hi {
        let d = normalizedDistance(query[offset..<(offset + len)], phrase[0..<min(l, len)], table: table)
        let tie = abs(len - l)
        if d < bestDist || (d == bestDist && tie < bestTie) {
          bestDist = d
          bestLen = len
          bestTie = tie
        }
      }
    }
    if bestLen >= 0 && bestDist <= preambleMaxDistance {
      if isBasmala {
        basmala = true
        basmalaOffset = offset
      }
      offset += bestLen
    }
  }
  return StripResult(offset: offset, basmala: basmala, basmalaOffset: basmalaOffset)
}

private func growingIstiadha(_ query: [UInt8], table: CostTable) -> Bool {
  if query.count > istiadhaIds.count + 4 { return false }
  return normalizedDistance(query, istiadhaIds[0..<min(istiadhaIds.count, query.count)], table: table) <= growingDistance
}

/// Whole-Quran 5-gram index with semi-global verification (spec §7).
public final class QuranIndex: Sendable {
  public let corpus: QuranCorpus
  public let table: CostTable
  private let cfg: EngineConfig
  private let sep: [UInt8]
  private let surahSepStart: [Int]
  private let surahSepLen: [Int]
  private let surahCorpusStart: [Int]
  private let bucketStart: [Int32]
  private let postings: [Int32]
  private let openings: SurahOpenings?

  public init(corpus: QuranCorpus, config: EngineConfig = .default, table: CostTable = .shared) {
    self.corpus = corpus
    self.openings = config.surahOpenings.map { SurahOpenings(corpus: corpus, rule: $0, table: table) }
    self.cfg = config
    self.table = table
    let nSurah = corpus.surahs.count
    var sepStart = [Int](repeating: 0, count: nSurah)
    var sepLen = [Int](repeating: 0, count: nSurah)
    var corpusStart = [Int](repeating: 0, count: nSurah)
    var sep: [UInt8] = []
    sep.reserveCapacity(corpus.ids.count + nSurah * surahGap)
    for (i, s) in corpus.surahs.enumerated() {
      let cs = Int(corpus.wordStart[s.firstWord])
      let ce = Int(corpus.wordStart[s.endWord])
      sepStart[i] = sep.count
      sepLen[i] = ce - cs
      corpusStart[i] = cs
      sep.append(contentsOf: corpus.ids[cs..<ce])
      if i < nSurah - 1 { sep.append(contentsOf: repeatElement(Phonemes.unknownId, count: surahGap)) }
    }
    var counts = [Int32](repeating: 0, count: buckets)
    var start = [Int32](repeating: 0, count: buckets + 1)
    var postings: [Int32] = []
    sep.withUnsafeBufferPointer { s in
      let last = s.count - gram
      if last >= 0 { for p in 0...last { counts[fnv1aBucket(s, p)] += 1 } }
      for b in 0..<buckets { start[b + 1] = start[b] + counts[b] }
      postings = [Int32](repeating: 0, count: Int(start[buckets]))
      var cursor = start
      if last >= 0 {
        for p in 0...last {
          let b = fnv1aBucket(s, p)
          postings[Int(cursor[b])] = Int32(p)
          cursor[b] += 1
        }
      }
    }
    self.sep = sep
    self.surahSepStart = sepStart
    self.surahSepLen = sepLen
    self.surahCorpusStart = corpusStart
    self.bucketStart = start
    self.postings = postings
  }

  public func search(_ query: [UInt8], hint: SearchHint? = nil, limit: Int = 3) -> SearchResult {
    let none = SearchResult(hits: [], decisive: false)
    if query.count < cfg.searchMinChars { return none }
    if growingIstiadha(query, table: table) { return none }
    let stripped = stripPreambles(query, table: table)
    let rest = Array(query[stripped.offset...])

    // Right after a basmala: a surah opening, when one is clearly heard, and
    // no basmala-anchored lock (al-Fātiḥa, 27:30) while the openings disagree.
    var opening: SurahOpenings.Match?
    if stripped.basmala, let openings, rest.count <= SurahOpenings.maxChars, let m = openings.match(rest[...]) {
      if let hit = openingHit(m, rest: rest, stripped: stripped) { return SearchResult(hits: [hit], decisive: true) }
      if m.distance <= openings.rule.maxDistance { opening = m }
    }
    if rest.count < cfg.searchMinChars { return none }

    if stripped.basmala {
      var inner = searchSlice(Array(query[stripped.basmalaOffset...]), hint: hint, limit: limit, alignedBonus: 0)
      if inner.decisive, let first = inner.hits.first, first.queryStart <= 2, agrees(first, opening) {
        for i in inner.hits.indices { inner.hits[i].queryStart += stripped.basmalaOffset }
        return inner
      }
    }

    var result = searchSlice(rest, hint: hint, limit: limit, alignedBonus: 0)
    var bonus = 0
    var collapsed = Set<Int>()
    for i in result.hits.indices {
      let h = result.hits[i]
      if stripped.basmala && h.surah == 1 && h.ayah == 2 && h.word <= 3 {
        result.hits[i] = SearchHit(surah: 1, ayah: 1, word: 0, wordIndex: 0, refOffset: 0, refEnd: 0, queryStart: 0, distance: h.distance)
        collapsed.insert(i)
        if i == 0 { bonus = stripped.offset - stripped.basmalaOffset }
      }
    }
    result.decisive = isDecisive(result.hits, queryLength: rest.count, alignedBonus: bonus, hint: hint)
      && (result.hits.first.map { agrees($0, opening) } ?? true)
    for i in result.hits.indices {
      if collapsed.contains(i) { result.hits[i].queryStart = stripped.basmalaOffset } else { result.hits[i].queryStart += stripped.offset }
    }
    if result.decisive || query.count <= shortQuery { return result }

    var tail = search(Array(query.suffix(shortQuery)), hint: hint, limit: limit)
    if tail.decisive {
      let add = query.count - shortQuery
      for i in tail.hits.indices { tail.hits[i].queryStart += add }
      return tail
    }
    return result
  }

  /// Every verified hit for a query of at least `minChars`, best first,
  /// without the decisiveness rules (the surah-start check uses it).
  public func nearest(_ query: [UInt8], minChars: Int, limit: Int = 8) -> [SearchHit] {
    searchSlice(query, hint: nil, limit: limit, alignedBonus: 0, minChars: minChars).hits
  }

  /// A lock on the opening `m` when it is clearly what follows the basmala:
  /// long enough, close, clear of every other opening, and of everything else
  /// in the Quran.
  private func openingHit(_ m: SurahOpenings.Match, rest: [UInt8], stripped: StripResult) -> SearchHit? {
    guard let rule = openings?.rule, m.isClear(rule), rest.count >= rule.minChars else { return nil }
    let elsewhere = nearest(rest, minChars: 6).filter { abs($0.refOffset - m.refOffset) > 6 }.map(\.distance).min() ?? 1
    guard elsewhere - m.distance >= rule.quranMargin else { return nil }
    let loc = corpus.location(ofWord: m.wordIndex)
    return SearchHit(surah: loc.surah, ayah: loc.ayah, word: loc.word, wordIndex: m.wordIndex,
                     refOffset: Int(corpus.wordStart[m.wordIndex]), refEnd: m.refOffset + rest.count,
                     queryStart: m.includesBasmala ? stripped.basmalaOffset : stripped.offset, distance: m.distance)
  }

  /// Whether a basmala-anchored hit (al-Fātiḥa, 27:30) is the opening that
  /// leads the others by the search's usual decisive margin; always true when
  /// no opening is in play.
  private func agrees(_ hit: SearchHit, _ opening: SurahOpenings.Match?) -> Bool {
    guard let opening else { return true }
    let leads = opening.rival - opening.distance >= cfg.searchDecisiveMargin
    if hit.surah == 1 && hit.ayah <= 2 { return opening.surah == 1 && leads }
    if hit.surah == 27 && (hit.ayah == 30 || hit.ayah == 31) { return opening.wordIndex == corpus.ayahFirstWord(27, 31) && leads }
    return true
  }

  private func searchSlice(_ query: [UInt8], hint: SearchHint?, limit: Int, alignedBonus: Int, minChars: Int? = nil) -> SearchResult {
    let minChars = minChars ?? cfg.searchMinChars
    if query.count < minChars { return SearchResult(hits: [], decisive: false) }
    var votes: [Int: Int] = [:]
    query.withUnsafeBufferPointer { q in
      bucketStart.withUnsafeBufferPointer { bucketStart in
        postings.withUnsafeBufferPointer { postings in
          let last = q.count - gram
          guard last >= 0 else { return }
          for u in 0...last {
            let b = fnv1aBucket(q, u)
            let a = Int(bucketStart[b])
            let z = Int(bucketStart[b + 1])
            if z - a > maxPostings { continue }
            for i in a..<z { votes[(Int(postings[i]) - u) >> windowBits, default: 0] += 1 }
          }
        }
      }
    }
    let kept = votes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(candidateWindows)
    var verified: [SearchHit] = []
    for (w, _) in kept {
      let start = w << windowBits
      let from = max(0, start - verifyMarginBefore)
      let to = min(sep.count, start + query.count + verifyMarginAfter)
      let al = alignSemiGlobal(query, sep, from: from, to: to, table: table, headSkipCost: 0.5)
      if query.count - al.queryStart < minChars { continue }
      let refOffset = mapSep(al.refStart)
      let refEnd = mapSep(al.refEnd)
      if refEnd <= refOffset { continue }
      let wordIndex = corpus.wordAt(refOffset)
      let loc = corpus.location(ofWord: wordIndex)
      verified.append(SearchHit(
        surah: loc.surah, ayah: loc.ayah, word: loc.word, wordIndex: wordIndex,
        refOffset: refOffset, refEnd: refEnd, queryStart: al.queryStart, distance: al.distance))
    }
    verified = verified.stableSorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.wordIndex < $1.wordIndex }
    var hits: [SearchHit] = []
    for h in verified {
      if hits.contains(where: { !(h.refEnd <= $0.refOffset || h.refOffset >= $0.refEnd) }) { continue }
      hits.append(h)
      if hits.count >= max(limit, 8) { break }
    }
    applyHint(&hits, hint)
    let out = Array(hits.prefix(limit))
    return SearchResult(hits: out, decisive: isDecisive(out, queryLength: query.count, alignedBonus: alignedBonus, hint: hint))
  }

  private func applyHint(_ hits: inout [SearchHit], _ hint: SearchHint?) {
    guard let hint, let best = hits.first else { return }
    let cap = best.distance + cfg.searchDecisiveMargin
    let hinted = hits.indices.filter { hits[$0].distance <= cap && hits[$0].surah == hint.surah }
    if hinted.isEmpty { return }
    let target = corpus.hasAyah(hint.surah, hint.ayah) ? corpus.ayahFirstWord(hint.surah, hint.ayah) : 0
    let chosen = hinted.stableSorted {
      let da = abs(hits[$0].wordIndex - target), db = abs(hits[$1].wordIndex - target)
      return da != db ? da < db : hits[$0].wordIndex < hits[$1].wordIndex
    }[0]
    let picked = hits.remove(at: chosen)
    hits.insert(picked, at: 0)
  }

  private func isDecisive(_ hits: [SearchHit], queryLength: Int, alignedBonus: Int, hint: SearchHint?) -> Bool {
    guard let best = hits.first else { return false }
    let aligned = queryLength - best.queryStart + alignedBonus
    if best.distance > cfg.searchDecisiveDistance { return false }
    if aligned < minAligned { return false }
    guard let rival = rival(hits, hint) else { return true }
    return rival.distance - best.distance >= cfg.searchDecisiveMargin
  }

  private func rival(_ hits: [SearchHit], _ hint: SearchHint?) -> SearchHit? {
    guard let best = hits.first else { return nil }
    if let hint {
      let cap = best.distance + cfg.searchDecisiveMargin
      if hits.contains(where: { $0.distance <= cap && $0.surah == hint.surah }) {
        return hits.dropFirst().first { $0.distance > cap }
      }
    }
    return hits.count > 1 ? hits[1] : nil
  }

  private func mapSep(_ sepOff: Int) -> Int {
    var lo = 0
    var hi = surahSepStart.count - 1
    while lo < hi {
      let mid = (lo + hi + 1) >> 1
      if surahSepStart[mid] <= sepOff { lo = mid } else { hi = mid - 1 }
    }
    let local = sepOff - surahSepStart[lo]
    let len = surahSepLen[lo]
    let cs = surahCorpusStart[lo]
    if local >= len { return cs + len }
    if local < 0 { return cs }
    return cs + local
  }
}

// MARK: - Surah openings (v0.2; not part of the original engine)

/// After a complete basmala the reciter is almost always starting a surah, so
/// what follows is matched against the surah openings (spec appendix A.2).
/// That decides which surah a basmala-anchored hit may claim: the original
/// search gives al-Fātiḥa every surah that opens like it. It also locks an
/// opening on its own once it is clear of every other opening and of the rest
/// of the Quran.
public final class SurahOpenings: Sendable {
  public struct Match: Equatable, Sendable {
    public var surah: Int
    /// Where to lock: the surah's first word (1:1 for al-Fātiḥa, whose basmala is its first ayah).
    public var wordIndex: Int
    /// Lock including the basmala (al-Fātiḥa) rather than after it.
    public var includesBasmala: Bool
    public var distance: Double
    /// Closest opening of any other surah.
    public var rival: Double
    /// Corpus offset (phoneme) where the matched opening's text starts.
    public var refOffset: Int

    /// Close to what was heard and clear of every other opening.
    public func isClear(_ rule: Rule) -> Bool { distance <= rule.maxDistance && rival - distance >= rule.margin }
  }

  /// When an opening counts as heard, tuned on every opening (clean and
  /// perturbed) against 7,478 basmala-then-mid-surah starts.
  public struct Rule: Equatable, Sendable {
    /// Post-basmala phonemes before an opening can lock on its own.
    public var minChars = 10
    /// Farthest an opening may be from what was heard.
    public var maxDistance = 0.2
    /// Lead over every other surah's opening.
    public var margin = 0.2
    /// Lead over the same phonemes anywhere else in the Quran.
    public var quranMargin = 0.05
    public init() {}
    public static let standard = Rule()
  }

  /// Longest post-basmala stretch matched here; beyond it the general search decides.
  public static let maxChars = 48

  private struct Opening: Sendable {
    let surah: Int
    let wordIndex: Int
    let includesBasmala: Bool
    let refOffset: Int
    let ids: [UInt8]
  }

  public let rule: Rule
  private let openings: [Opening]
  private let table: CostTable

  public init(corpus: QuranCorpus, rule: Rule = .standard, table: CostTable = .shared) {
    self.rule = rule
    func ids(from word: Int, to end: Int) -> [UInt8] {
      let a = Int(corpus.wordStart[word])
      return Array(corpus.ids[a..<min(Int(corpus.wordStart[end]), a + Self.maxChars + 4)])
    }
    var list: [Opening] = []
    for s in corpus.surahs where s.number != 9 {
      // Al-Fātiḥa's basmala is 1:1, so what follows it is 1:2.
      let from = s.number == 1 ? corpus.ayahFirstWord(1, 2) : s.firstWord
      list.append(Opening(surah: s.number, wordIndex: s.firstWord, includesBasmala: s.number == 1,
                          refOffset: Int(corpus.wordStart[from]), ids: ids(from: from, to: s.endWord)))
    }
    // 27:30 ends with the basmala, and 27:31 follows it.
    if corpus.hasAyah(27, 31) {
      let w = corpus.ayahFirstWord(27, 31)
      list.append(Opening(surah: 27, wordIndex: w, includesBasmala: false,
                          refOffset: Int(corpus.wordStart[w]), ids: ids(from: w, to: corpus.surahs[26].endWord)))
    }
    openings = list
    self.table = table
  }

  /// The opening closest to `rest` (the phonemes heard after the basmala),
  /// comparing `rest` with each opening's prefixes of about the same length.
  public func match(_ rest: ArraySlice<UInt8>) -> Match? {
    let n = rest.count
    guard n > 0, n <= Self.maxChars else { return nil }
    var bestIndex = -1, best = Double.infinity, rival = Double.infinity
    for (i, o) in openings.enumerated() {
      let d = prefixDistance(rest, o.ids)
      if d < best {
        if bestIndex >= 0, openings[bestIndex].wordIndex != o.wordIndex { rival = best }
        best = d
        bestIndex = i
      } else if d < rival, o.wordIndex != openings[bestIndex].wordIndex {
        rival = d
      }
    }
    guard bestIndex >= 0 else { return nil }
    let o = openings[bestIndex]
    return Match(surah: o.surah, wordIndex: o.wordIndex, includesBasmala: o.includesBasmala, distance: best, rival: rival, refOffset: o.refOffset)
  }

  /// Least normalized distance between `a` and a prefix of `b` within 3 of its length.
  private func prefixDistance(_ a: ArraySlice<UInt8>, _ b: [UInt8]) -> Double {
    let n = a.count
    let lo = max(1, n - 3), hi = min(b.count, n + 3)
    guard lo <= hi else { return 1 }
    var prev = [Double](repeating: 0, count: hi + 1)
    var cur = prev
    for j in 0...hi { prev[j] = Double(j) }
    table.matrix.withUnsafeBufferPointer { matrix in
      for (i, x) in a.enumerated() {
        cur[0] = Double(i + 1)
        let row = Int(x) * table.size
        for j in 1...hi {
          cur[j] = min(prev[j - 1] + Double(matrix[row + Int(b[j - 1])]), prev[j] + 1, cur[j - 1] + 1)
        }
        swap(&prev, &cur)
      }
    }
    var d = Double.infinity
    for len in lo...hi { d = min(d, prev[len] / Double(max(n, len))) }
    return d
  }
}
