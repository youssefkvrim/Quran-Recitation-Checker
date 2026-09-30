/// Nearest whole ayah to a transcript, used when nothing passed the gate (spec §11).
public func wholeAyahFallback(
  _ text: [Phone], corpus: QuranCorpus, table: CostTable = .shared,
  minChars: Int = EngineConfig.default.searchMinChars, maxDistance: Double = fallbackMaxDistance
) -> FallbackHit? {
  if text.isEmpty { return nil }
  let ids = Phonemes.encode(text)
  let stripped = stripPreambles(ids, table: table)
  let rest = ids[stripped.offset...]
  if stripped.basmala && rest.count < minChars {
    return FallbackHit(surah: 1, ayah: 1, distance: 0, how: .basmala)
  }
  let q = rest.count >= 3 ? Array(rest) : ids
  var best: FallbackHit?
  for s in corpus.surahs {
    for a in 1...s.ayahCount {
      let first = corpus.ayahFirstWord(s.number, a)
      let ayah = corpus.ids[Int(corpus.wordStart[first])..<Int(corpus.wordStart[first + corpus.ayahWordCount(s.number, a)])]
      if Double(ayah.count) > 2.5 * Double(q.count) + 8 || Double(q.count) > 2.5 * Double(ayah.count) + 8 { continue }
      let d = normalizedDistance(q, ayah, table: table)
      if best == nil || d < best!.distance {
        best = FallbackHit(surah: s.number, ayah: a, distance: d, how: .wholeAyah)
      }
    }
  }
  guard let best, best.distance <= maxDistance else { return nil }
  return best
}
