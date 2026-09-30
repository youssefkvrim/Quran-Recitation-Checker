import Foundation
import Testing
@testable import RecitationKit

@Suite("Display text")
struct QuranTextTests {
  static let url = Paths.repo.appendingPathComponent("App/QuranRecitationChecker/Resources/quran-text.json")

  @Test func signsAreNotWords() {
    #expect(QuranText.splitWords("لَمْ يَلِدْ ۖ وَلَمْ يُولَدْ").map(\.text) == ["لَمْ", "يَلِدْ ۖ", "وَلَمْ", "يُولَدْ"])
    #expect(QuranText.splitWords("۞ أَتَأْمُرُونَ ٱلنَّاسَ بِٱلْبِرِّ").map(\.text) == ["۞ أَتَأْمُرُونَ", "ٱلنَّاسَ", "بِٱلْبِرِّ"])
    #expect(QuranText.splitWords("وَهُمْ لَا يَسْتَكْبِرُونَ ۩").map(\.text) == ["وَهُمْ", "لَا", "يَسْتَكْبِرُونَ ۩"])
  }

  @Test func joinedBaadamaCoversTwoWords() {
    let words = QuranText.ayahWords(surah: 8, ayah: 6, text: "يُجَٰدِلُونَكَ فِى ٱلْحَقِّ بَعْدَمَا تَبَيَّنَ")
    #expect(words.map { [$0.first, $0.count] } == [[0, 1], [1, 1], [2, 1], [3, 2], [5, 1]])
    #expect(words[3].covers(4) && !words[3].covers(5))
  }

  @Test func bismillahIsDisplayOnly() {
    let words = QuranText.ayahWords(surah: 112, ayah: 1, text: "بِسْمِ ٱللَّهِ ٱلرَّحْمَٰنِ ٱلرَّحِيمِ قُلْ هُوَ ٱللَّهُ أَحَدٌ")
    #expect(words.prefix(4).allSatisfy { $0.first == -1 && $0.count == 0 })
    #expect(words.dropFirst(4).map(\.first) == [0, 1, 2, 3])
  }

  @Test(.enabled(if: hasCorpus)) func everyAyahMapsOntoTheCorpus() throws {
    let text = try QuranText(json: Data(contentsOf: Self.url))
    let c = Shared.corpus!
    var mismatched: [String] = []
    var total = 0
    for s in text.surahs {
      for a in 1...s.ayahs.count {
        total += 1
        let covered = text.words(surah: s.number, ayah: a).reduce(0) { $0 + $1.count }
        if covered != c.ayahWordCount(s.number, a) { mismatched.append("\(s.number):\(a)") }
      }
    }
    #expect(total == 6236)
    #expect(mismatched.isEmpty, "\(mismatched.prefix(10))")
  }
}

extension QuranTextTests {
  @Test func displayTextSurvivesSplitting() throws {
    let text = try QuranText(json: Data(contentsOf: Self.url))
    for s in text.surahs {
      for (i, ayah) in s.ayahs.enumerated() {
        let joined = QuranText.splitWords(ayah).map(\.text).joined(separator: " ")
        let normalized = ayah.unicodeScalars.split(whereSeparator: \.properties.isWhitespace).map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
        #expect(joined == normalized, "\(s.number):\(i + 1)")
      }
    }
  }
}
