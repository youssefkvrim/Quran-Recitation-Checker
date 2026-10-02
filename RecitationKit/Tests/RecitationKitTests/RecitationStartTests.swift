import Foundation
import Testing
@testable import RecitationKit

/// v0.2 additions for the start of a recitation: following the istiʿādha and
/// basmala, and deciding surah openings right after the basmala.
@Suite("Recitation start")
struct RecitationStartTests {
  private func progress(_ text: some Collection<Phone>) -> PreambleProgress? { preambleProgress(Phonemes.encode(Array(text))) }

  @Test func followsTheIstiadhaThenTheBasmalaWordByWord() {
    let text = istiadhaPhonemes + basmalaPhonemes
    var seen: [PreambleProgress] = []
    for n in 1...text.count {
      if let p = progress(text[0..<n]), p != seen.last { seen.append(p) }
    }
    #expect(seen == (1...5).map { PreambleProgress(kind: .istiadha, words: $0) } + (1...4).map { PreambleProgress(kind: .basmala, words: $0) })
    #expect(progress(basmalaPhonemes) == PreambleProgress(kind: .basmala, words: 4))
  }

  @Test func toleratesASlipPerWordButNotOtherText() {
    // One wrong consonant in each basmala word.
    var slipped = basmalaPhonemes
    for at in [2, 7, 16, 25] { slipped[at] = Array("ت".utf16)[0] }
    #expect(progress(slipped) == PreambleProgress(kind: .basmala, words: 4))
    #expect(progress("قُل هُوَ للَااهُ ءَحَد".utf16.filter { $0 != 0x20 }) == nil)
  }

  @Test func wordEndsSplitThePhrases() {
    func words(_ p: [Phone], _ ends: [Int]) -> [String] {
      zip([0] + ends.dropLast(), ends).map { String(decoding: p[$0..<$1], as: UTF16.self) }
    }
    #expect(words(istiadhaPhonemes, istiadhaWordEnds) == ["ءَعُۥۥذُ", "بِللَااهِ", "مِنَ", "ششَييطَاانِ", "ررَجِۦۦم"])
    #expect(istiadhaWordEnds.last == istiadhaPhonemes.count && basmalaWordEnds.last == basmalaPhonemes.count)
  }

  @Test(.enabled(if: hasCorpus)) func basmalaWordEndsAreTheCorpusWordsOf1_1() {
    let c = Shared.corpus!
    #expect(Array(c.ayahPhonemes(1, 1)) == basmalaPhonemes)
    #expect((1...4).map { Int(c.wordStart[$0]) } == basmalaWordEnds)
  }

  // MARK: Session

  private func scripted(_ text: [Phone]) -> [Int] {
    let ids = Dictionary(zipformerTokens.enumerated().filter { $0.element.utf16.count == 1 }.map { ($0.element.utf16.first!, $0.offset) },
                         uniquingKeysWith: { a, _ in a })
    return text.flatMap { [ids[$0]!, 250] } + [Int](repeating: 250, count: 60)
  }

  private func run(_ text: [Phone], preamble: Bool) throws -> [RecitationEvent] {
    var options = RecitationSession.Options()
    options.emitRawTranscript = false
    options.emitPreamble = preamble
    options.config.surahOpenings = .standard
    let backend = ScriptedBackend(frames: scripted(text))
    let session = RecitationSession(corpus: Shared.corpus!, backend: backend, options: options)
    var events: [RecitationEvent] = []
    while !backend.done { events += try session.feed([Float](repeating: 0, count: 1365)) }
    return events
  }

  @Test(.enabled(if: hasCorpus)) func sessionReportsThePreambleThenLocates() throws {
    let text = istiadhaPhonemes + basmalaPhonemes + recitation(Shared.corpus!, 112, 1, 4)
    let events = try run(text, preamble: true)
    // One event per change, only ever moving forward (two short words can land in one 480 ms window).
    let preambles = events.compactMap { if case let .preamble(p) = $0 { p } else { nil } }
    let order = preambles.map { ($0.kind == .istiadha ? 0 : 10) + $0.words }
    #expect(order == order.sorted() && Set(order).count == order.count && order.count >= 7)
    #expect(preambles.contains(PreambleProgress(kind: .istiadha, words: 5)) && preambles.last == PreambleProgress(kind: .basmala, words: 4))
    let lastPreamble = try #require(events.lastIndex { if case .preamble = $0 { true } else { false } })
    let located = try #require(events.firstIndex { if case .verseCandidate = $0 { true } else { false } })
    #expect(located > lastPreamble)
    if case let .verseCandidate(surah, ayah, _) = events[located] { #expect(surah == 112 && ayah == 1) }
    #expect(try run(text, preamble: false).allSatisfy { if case .preamble = $0 { false } else { true } })
  }

  // MARK: Surah openings

  private func firstLock(_ index: QuranIndex, after basmala: Bool, _ text: [Phone], upTo: Int = 80) -> SearchHit? {
    let head = basmala ? Phonemes.encode(basmalaPhonemes) : []
    let ids = Phonemes.encode(text)
    for k in 1...min(upTo, ids.count) {
      let r = index.search(head + ids[0..<k])
      if r.decisive { return r.hits.first }
    }
    return nil
  }

  private func opening(_ surah: Int) -> [Phone] {
    let c = Shared.corpus!
    let from = surah == 1 ? c.ayahFirstWord(1, 2) : c.surahs[surah - 1].firstWord
    return Array(c.text[Int(c.wordStart[from])...].prefix(80))
  }

  private static let withOpenings: QuranIndex? = Shared.corpus.map {
    var cfg = EngineConfig.default
    cfg.surahOpenings = .standard
    return QuranIndex(corpus: $0, config: cfg)
  }

  /// al-An'ām, al-Kahf, Sabaʾ and Fāṭir open with al-Fātiḥa's الحمد لله; al-Jumuʿa
  /// and at-Taghābun with يسبح لله. With their basmala, the original engine locks
  /// all six onto al-Fātiḥa.
  @Test(.enabled(if: hasCorpus), arguments: [6, 18, 34, 35, 62, 64])
  func basmalaThenAnOpeningLikeAlFatihasLocksItsOwnSurah(_ surah: Int) throws {
    #expect(firstLock(Shared.index!, after: true, opening(surah))?.surah == 1)
    let hit = try #require(firstLock(Self.withOpenings!, after: true, opening(surah)))
    #expect(hit.surah == surah && hit.ayah == 1 && hit.word == 0)
  }

  @Test(.enabled(if: hasCorpus), arguments: [1, 2, 36, 55, 67, 112, 114])
  func basmalaThenAnOpeningLocksItsFirstWord(_ surah: Int) throws {
    let hit = try #require(firstLock(Self.withOpenings!, after: true, opening(surah)))
    #expect(hit.surah == surah && hit.ayah == 1 && hit.word == 0)
  }

  @Test(.enabled(if: hasCorpus)) func basmalaOf27_30ThenItsNextAyah() throws {
    let c = Shared.corpus!
    // Locks on the basmala that ends 27:30, or on 27:31 itself.
    let hit = try #require(firstLock(Self.withOpenings!, after: true, Array(c.ayahPhonemes(27, 31))))
    #expect(hit.surah == 27 && (hit.ayah == 30 || hit.ayah == 31))
  }

  @Test(.enabled(if: hasCorpus), arguments: [(2, 255), (18, 10), (36, 58), (55, 13), (3, 26)])
  func basmalaThenMidSurahStillFindsTheAyah(_ surah: Int, _ ayah: Int) throws {
    let c = Shared.corpus!
    let text = Array(c.text[Int(c.wordStart[c.ayahFirstWord(surah, ayah)])...].prefix(120))
    let hit = try #require(firstLock(Self.withOpenings!, after: true, text, upTo: 120))
    #expect(hit.surah == surah && hit.ayah == ayah)
  }

  @Test(.enabled(if: hasCorpus)) func withoutABasmalaNothingChanges() throws {
    for (s, a) in [(18, 1), (2, 255), (112, 1), (36, 1)] {
      let c = Shared.corpus!
      let text = Array(c.text[Int(c.wordStart[c.ayahFirstWord(s, a)])...].prefix(80))
      #expect(firstLock(Self.withOpenings!, after: false, text) == firstLock(Shared.index!, after: false, text))
    }
  }
}
