import Foundation

public struct SurahRecord: Equatable, Sendable {
  public let number: Int
  public let name: String
  public let nameEn: String
  public let ayahCount: Int
  /// Global index of the surah's first word; `endWord` is exclusive.
  public let firstWord: Int
  public let endWord: Int
}

public enum CorpusError: Error, Equatable {
  case invalid(String)
  case outOfRange(String)
}

/// The phoneme corpus (`zipformer_quran.json` v2, spec §4) flattened into one
/// phoneme stream with per-word tables.
public final class QuranCorpus: Sendable {
  /// Every word's phonemes, concatenated (UTF-16 code units).
  public let text: [Phone]
  /// `text` encoded with the cost-table alphabet.
  public let ids: [UInt8]
  /// Char offset of each word; `wordStart[wordCount] == text.count`.
  public let wordStart: [Int32]
  public let wordSurah: [Int32]
  public let wordAyah: [Int32]
  public let wordInAyah: [Int32]
  /// Unicode Uthmani text of each word (display fallback, tanween for waqf).
  public let plain: [String]
  public let surahs: [SurahRecord]
  public let wordCount: Int
  private let ayahFirst: [[Int32]]
  private let ayahWords: [[Int32]]

  /// Parse `zipformer_quran.json`.
  public convenience init(json data: Data) throws {
    let object = try JSONSerialization.jsonObject(with: data)
    try self.init(parsed: object)
  }

  public init(parsed object: Any) throws {
    guard let raw = object as? [String: Any], (raw["v"] as? NSNumber)?.intValue == 2 else {
      throw CorpusError.invalid("quran.json must be v2")
    }
    guard let rawSurahs = raw["surahs"] as? [[String: Any]], rawSurahs.count == 114 else {
      throw CorpusError.invalid("quran.json must contain 114 surahs")
    }
    var text: [Phone] = []
    text.reserveCapacity(660_000)
    var wordStart: [Int32] = []
    var wordSurah: [Int32] = []
    var wordAyah: [Int32] = []
    var wordInAyah: [Int32] = []
    var plain: [String] = []
    var ayahFirst: [[Int32]] = []
    var ayahWords: [[Int32]] = []
    var surahs: [SurahRecord] = []
    var w: Int32 = 0
    for s in rawSurahs {
      guard let n = (s["n"] as? NSNumber)?.intValue, let ayahs = s["ayahs"] as? [[String: Any]] else {
        throw CorpusError.invalid("malformed surah")
      }
      let firstWord = Int(w)
      var firsts: [Int32] = []
      var counts: [Int32] = []
      for (ai, a) in ayahs.enumerated() {
        guard (a["n"] as? NSNumber)?.intValue == ai + 1 else {
          throw CorpusError.invalid("surah \(n) ayah index \(ai) out of order")
        }
        guard let words = a["w"] as? [[String]] else { throw CorpusError.invalid("malformed ayah \(n):\(ai + 1)") }
        firsts.append(w)
        counts.append(Int32(words.count))
        for (wi, triple) in words.enumerated() {
          guard triple.count >= 3 else { throw CorpusError.invalid("malformed word \(n):\(ai + 1):\(wi)") }
          wordStart.append(Int32(text.count))
          wordSurah.append(Int32(n))
          wordAyah.append(Int32(ai + 1))
          wordInAyah.append(Int32(wi))
          plain.append(triple[2])
          text.append(contentsOf: triple[1].utf16)
          w += 1
        }
      }
      ayahFirst.append(firsts)
      ayahWords.append(counts)
      surahs.append(SurahRecord(
        number: n, name: s["name"] as? String ?? "", nameEn: s["nameEn"] as? String ?? "",
        ayahCount: ayahs.count, firstWord: firstWord, endWord: Int(w)))
    }
    wordStart.append(Int32(text.count))
    self.text = text
    self.ids = Phonemes.encode(text)
    self.wordStart = wordStart
    self.wordSurah = wordSurah
    self.wordAyah = wordAyah
    self.wordInAyah = wordInAyah
    self.plain = plain
    self.surahs = surahs
    self.wordCount = Int(w)
    self.ayahFirst = ayahFirst
    self.ayahWords = ayahWords
  }

  /// Word containing char `offset`, clamped to the corpus.
  public func wordAt(_ offset: Int) -> Int {
    if offset < 0 { return 0 }
    if offset >= text.count { return wordCount - 1 }
    var lo = 0
    var hi = wordCount
    while lo < hi {
      let mid = (lo + hi + 1) >> 1
      if Int(wordStart[mid]) <= offset { lo = mid } else { hi = mid - 1 }
    }
    return lo
  }

  public func hasAyah(_ surah: Int, _ ayah: Int) -> Bool {
    guard surah >= 1, surah <= surahs.count else { return false }
    return ayah >= 1 && ayah <= surahs[surah - 1].ayahCount
  }

  public func wordIndex(_ surah: Int, _ ayah: Int, _ word: Int) throws -> Int {
    guard hasAyah(surah, ayah) else { throw CorpusError.outOfRange("no ayah \(surah):\(ayah)") }
    guard word >= 0, word < ayahWordCount(surah, ayah) else {
      throw CorpusError.outOfRange("word \(word) out of range for \(surah):\(ayah)")
    }
    return ayahFirstWord(surah, ayah) + word
  }

  public func ayahFirstWord(_ surah: Int, _ ayah: Int) -> Int { Int(ayahFirst[surah - 1][ayah - 1]) }

  public func ayahWordCount(_ surah: Int, _ ayah: Int) -> Int { Int(ayahWords[surah - 1][ayah - 1]) }

  public func ayahPhonemes(_ surah: Int, _ ayah: Int) -> ArraySlice<Phone> {
    let first = ayahFirstWord(surah, ayah)
    let end = first + ayahWordCount(surah, ayah)
    return text[Int(wordStart[first])..<Int(wordStart[end])]
  }

  public func wordPhonemes(_ wordIndex: Int) -> ArraySlice<Phone> {
    text[Int(wordStart[wordIndex])..<Int(wordStart[wordIndex + 1])]
  }

  public func wordIds(_ wordIndex: Int) -> ArraySlice<UInt8> {
    ids[Int(wordStart[wordIndex])..<Int(wordStart[wordIndex + 1])]
  }

  public func location(ofWord index: Int) -> (surah: Int, ayah: Int, word: Int) {
    (Int(wordSurah[index]), Int(wordAyah[index]), Int(wordInAyah[index]))
  }
}
