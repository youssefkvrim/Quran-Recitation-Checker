import Foundation

/// One display word of an ayah and the acoustic words it covers.
public struct DisplayWord: Equatable, Sendable {
  /// Uthmani text, with any attached stop, sajdah or hizb sign.
  public var text: String
  /// First acoustic word index (`WordProgress.wordIndex`, `CorrectionIssue.word`),
  /// or -1 for the display-only bismillah printed at the top of ayah 1.
  public var first: Int
  /// Acoustic words covered: usually 1, 2 for a joined بَعْدَمَا, 0 for the bismillah.
  public var count: Int

  public func covers(_ acousticWord: Int) -> Bool { count > 0 && first <= acousticWord && acousticWord < first + count }
}

/// Uthmani display text (`quran-text.json`), mapped onto the acoustic corpus's
/// word indices. The corpus splits words its own way; every index after a
/// mismatch would otherwise point at the wrong word.
public final class QuranText: Sendable {
  public struct Surah: Equatable, Sendable {
    public let number: Int
    public let name: String
    public let nameEn: String
    public let ayahs: [String]
  }

  public let surahs: [Surah]

  public init(json data: Data) throws {
    struct File: Decodable {
      struct S: Decodable { let n: Int; let name: String; let nameEn: String; let ayahs: [String] }
      let surahs: [S]
    }
    let file = try JSONDecoder().decode(File.self, from: data)
    guard file.surahs.count == 114 else { throw CorpusError.invalid("quran-text.json must contain 114 surahs") }
    surahs = file.surahs.map { Surah(number: $0.n, name: $0.name, nameEn: $0.nameEn, ayahs: $0.ayahs) }
  }

  public func surah(_ n: Int) -> Surah? { n >= 1 && n <= surahs.count ? surahs[n - 1] : nil }

  public func text(surah: Int, ayah: Int) -> String? {
    guard let s = self.surah(surah), ayah >= 1, ayah <= s.ayahs.count else { return nil }
    return s.ayahs[ayah - 1]
  }

  /// The ayah's display words with their acoustic ranges.
  public func words(surah: Int, ayah: Int) -> [DisplayWord] {
    guard let text = text(surah: surah, ayah: ayah) else { return [] }
    return Self.ayahWords(surah: surah, ayah: ayah, text: text)
  }

  public static let bismillahWordCount = 4

  public static func ayahWords(surah: Int, ayah: Int, text: String) -> [DisplayWord] {
    let tokens = splitWords(text)
    let skip = ayah == 1 && surah != 1 && surah != 9 && startsWithBismillah(text) ? bismillahWordCount : 0
    var next = 0
    return tokens.enumerated().map { i, t in
      if i < skip { return DisplayWord(text: t.text, first: -1, count: 0) }
      defer { next += t.words }
      return DisplayWord(text: t.text, first: next, count: t.words)
    }
  }

  /// Words the Uthmani text writes joined but the acoustic corpus splits.
  private static let fused: [String: Int] = ["بعدما": 2]
  private static let rubElHizb: Unicode.Scalar = "\u{06DE}"

  private static func isLetter(_ s: Unicode.Scalar) -> Bool {
    (0x0621...0x064A).contains(s.value) || (0x0671...0x06D3).contains(s.value) || (0x06FA...0x06FF).contains(s.value)
  }

  private static func letters(_ token: Substring) -> String {
    var out = String.UnicodeScalarView()
    for s in token.unicodeScalars {
      let v = s.value
      if (0x0610...0x061A).contains(v) || (0x064B...0x065F).contains(v) || v == 0x0670 || (0x06D6...0x06ED).contains(v) || v == 0x0640 { continue }
      out.append(v == 0x0671 ? "\u{0627}" : s)
    }
    return String(out)
  }

  /// Display words: sign-only tokens (waqf ۖ…ۜ, sajdah ۩) stay with the word
  /// before them, a rub el hizb ۞ with the word after it.
  ///
  /// Splits on Unicode scalars: in `Character` terms a space followed by a
  /// combining stop mark is one whitespace grapheme, and the mark would vanish.
  public static func splitWords(_ text: String) -> [(text: String, words: Int)] {
    var tokens: [String.UnicodeScalarView] = []
    var current = String.UnicodeScalarView()
    for s in text.unicodeScalars where s != "\u{FEFF}" {
      if s.properties.isWhitespace {
        if !current.isEmpty { tokens.append(current) }
        current = String.UnicodeScalarView()
      } else {
        current.append(s)
      }
    }
    if !current.isEmpty { tokens.append(current) }

    var result: [(text: String, words: Int)] = []
    var prefix = ""
    for scalars in tokens {
      let token = String(scalars)
      if !scalars.contains(where: isLetter) {
        if scalars.contains(rubElHizb) || result.isEmpty { prefix += token + " " } else { result[result.count - 1].text += " " + token }
        continue
      }
      result.append((prefix + token, fused[letters(Substring(token))] ?? 1))
      prefix = ""
    }
    if !prefix.isEmpty, !result.isEmpty { result[result.count - 1].text += " " + String(prefix.dropLast()) }
    return result
  }

  public static func startsWithBismillah(_ text: String) -> Bool {
    func strip(_ s: String) -> String {
      String(String.UnicodeScalarView(s.unicodeScalars.filter { s in
        let v = s.value
        return !((0x0610...0x061A).contains(v) || (0x064B...0x065F).contains(v) || v == 0x0670 || (0x06D6...0x06DC).contains(v)
                 || (0x06DF...0x06E4).contains(v) || v == 0x06E7 || v == 0x06E8 || (0x06EA...0x06ED).contains(v))
      }))
    }
    return strip(text).replacingOccurrences(of: "\u{0671}", with: "\u{0627}").hasPrefix("بسم الله الرحمن الرحيم")
  }
}
