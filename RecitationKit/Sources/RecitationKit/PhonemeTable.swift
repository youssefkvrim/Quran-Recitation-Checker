/// Phoneme alphabet and substitution costs (spec §5).
public enum Phonemes {
  /// Order is id. 41 letters + 3 short vowels + 7 other marks.
  public static let alphabet: [Phone] = Array("ءابتثجحخدذرزسشصضطظعغفقكلمنهويۥۦں۾ٲأإآؤئٱىَُِڇؙۣ۪ٞۜـ".utf16)
  public static let alphabetSize = 51
  public static let tableSize = 52
  public static let unknownId: UInt8 = 51

  public static let fatha: Phone = 0x064E
  public static let damma: Phone = 0x064F
  public static let kasra: Phone = 0x0650

  /// Code unit -> id, `unknownId` for anything outside the alphabet.
  static let ids: [UInt8] = {
    var t = [UInt8](repeating: unknownId, count: 65_536)
    for (i, ch) in alphabet.enumerated().reversed() { t[Int(ch)] = UInt8(i) }
    return t
  }()

  @inline(__always)
  public static func id(_ ch: Phone) -> UInt8 { ids[Int(ch)] }

  public static func encode<C: Collection>(_ text: C) -> [UInt8] where C.Element == Phone {
    text.map { ids[Int($0)] }
  }

  public static func encode(_ text: String) -> [UInt8] { encode(Array(text.utf16)) }

  static func isShortVowel(_ ch: Phone) -> Bool { ch == fatha || ch == damma || ch == kasra }

  private static let canonicalMap: [Phone: Phone] = [
    0x06E6: 0x064A,  // ۦ -> ي
    0x06E5: 0x0648,  // ۥ -> و
    0x06BA: 0x0646,  // ں -> ن
    0x06FE: 0x0645,  // ۾ -> م
    0x0671: 0x0627,  // ٱ -> ا
    0x0649: 0x064A,  // ى -> ي
  ]
  private static let hamza = Set("ءأإآاؤئٲ".utf16)
  private static let otherMarks = Set("ڇؙۣ۪ٞۜـ".utf16)
  private static let neighbors: Set<UInt32> = {
    var s = Set<UInt32>()
    func add(_ a: Phone, _ b: Phone) { s.insert(pairKey(a, b)) }
    for group in ["ذدضتط", "ظزذصسث", "جزش", "ةهت", "قكغ", "فبم"] {
      let g = Array(group.utf16)
      for i in 0..<g.count { for j in (i + 1)..<g.count { add(g[i], g[j]) } }
    }
    for pair in ["هح", "غخ", "ءع", "نم", "نل", "ظض"] {
      let p = Array(pair.utf16)
      add(p[0], p[1])
    }
    return s
  }()

  private static func pairKey(_ a: Phone, _ b: Phone) -> UInt32 {
    a < b ? UInt32(a) << 16 | UInt32(b) : UInt32(b) << 16 | UInt32(a)
  }

  static func canonical(_ ch: Phone) -> Phone { canonicalMap[ch] ?? ch }

  /// Substitution cost of hearing `heard` where `expected` is written.
  public static func charCost(_ heard: Phone, _ expected: Phone) -> Double {
    if heard == expected { return 0 }
    let ch = canonical(heard)
    let ce = canonical(expected)
    if ch == ce { return 0 }
    let hm = isShortVowel(heard) || otherMarks.contains(heard)
    let em = isShortVowel(expected) || otherMarks.contains(expected)
    if hm || em {
      if hm && em { return isShortVowel(heard) && isShortVowel(expected) ? 0.1 : 0.25 }
      return 1
    }
    if hamza.contains(ch) && hamza.contains(ce) { return 0.1 }
    if neighbors.contains(pairKey(ch, ce)) { return 0.25 }
    return 1
  }
}

/// Dense float32 `size × size` substitution matrix, `matrix[heard * size + expected]`.
public final class CostTable: Sendable {
  public let size = Phonemes.tableSize
  public let matrix: [Float]

  public static let shared = CostTable()

  private init() {
    let n = Phonemes.tableSize
    var m = [Float](repeating: 1, count: n * n)
    for i in 0..<Phonemes.alphabetSize {
      for j in 0..<Phonemes.alphabetSize {
        m[i * n + j] = Float(Phonemes.charCost(Phonemes.alphabet[i], Phonemes.alphabet[j]))
      }
    }
    matrix = m
  }

  @inline(__always)
  public func cost(_ heard: UInt8, _ expected: UInt8) -> Float {
    matrix[Int(heard) * size + Int(expected)]
  }
}
