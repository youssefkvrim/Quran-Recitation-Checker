/// A phoneme is one UTF-16 code unit of the corpus alphabet (spec §4: all BMP).
public typealias Phone = UInt16

/// Probabilities, at a token's peak frame, of the same token spelled with
/// fatha, damma and kasra. Only set for tokens ending in a short vowel.
public struct VowelProbs: Equatable, Sendable {
  public var fatha: Double
  public var damma: Double
  public var kasra: Double

  public init(fatha: Double, damma: Double, kasra: Double) {
    self.fatha = fatha
    self.damma = damma
    self.kasra = kasra
  }

  public subscript(index: Int) -> Double {
    switch index {
    case 0: return fatha
    case 1: return damma
    default: return kasra
    }
  }
}

/// One greedy-CTC token (spec §3).
public struct CtcToken: Equatable, Sendable {
  public var symbol: [Phone]
  public var frame: Int
  public var margin: Double
  public var vowels: VowelProbs?

  public init(symbol: [Phone], frame: Int, margin: Double, vowels: VowelProbs? = nil) {
    self.symbol = symbol
    self.frame = frame
    self.margin = margin
    self.vowels = vowels
  }

  public init(_ symbol: String, frame: Int, margin: Double, vowels: VowelProbs? = nil) {
    self.init(symbol: Array(symbol.utf16), frame: frame, margin: margin, vowels: vowels)
  }

  public var text: String { String(decoding: symbol, as: UTF16.self) }
}

/// One heard phoneme: a token split into characters (spec §3, engine-side splitting).
public struct HeardChar: Equatable, Sendable {
  public var ch: Phone
  public var frame: Int
  public var margin: Double
  public var vowels: VowelProbs?

  public init(ch: Phone, frame: Int, margin: Double, vowels: VowelProbs? = nil) {
    self.ch = ch
    self.frame = frame
    self.margin = margin
    self.vowels = vowels
  }
}

public enum VerdictState: String, Sendable {
  case ok, unsure, wrong, skipped, pending
}

/// The acoustic judgement of one word (spec §9). Instances are shared between
/// callers and cached by the tracer, so they are immutable.
public final class WordVerdict: Equatable, Sendable, CustomStringConvertible {
  public let surah: Int
  public let ayah: Int
  public let word: Int
  public let wordIndex: Int
  public let state: VerdictState
  public let distance: Double
  public let heardRatio: Double
  public let margin: Double
  /// Aligned short-vowel substitutions (heard vowel ≠ expected vowel).
  public let vowelErrors: Int
  /// Min over mismatched vowels of p(heard) − p(expected); 0 when none.
  public let vowelMargin: Double

  public init(
    surah: Int, ayah: Int, word: Int, wordIndex: Int, state: VerdictState,
    distance: Double, heardRatio: Double, margin: Double,
    vowelErrors: Int = 0, vowelMargin: Double = 0
  ) {
    self.surah = surah
    self.ayah = ayah
    self.word = word
    self.wordIndex = wordIndex
    self.state = state
    self.distance = distance
    self.heardRatio = heardRatio
    self.margin = margin
    self.vowelErrors = vowelErrors
    self.vowelMargin = vowelMargin
  }

  public static func == (a: WordVerdict, b: WordVerdict) -> Bool {
    a.surah == b.surah && a.ayah == b.ayah && a.word == b.word && a.wordIndex == b.wordIndex
      && a.state == b.state && a.distance == b.distance && a.heardRatio == b.heardRatio
      && a.margin == b.margin && a.vowelErrors == b.vowelErrors && a.vowelMargin == b.vowelMargin
  }

  public var description: String {
    "\(surah):\(ayah):\(word) \(state) d=\(distance) r=\(heardRatio) m=\(margin)"
  }
}

public struct SearchHint: Equatable, Sendable {
  public var surah: Int
  public var ayah: Int
  public init(surah: Int, ayah: Int) {
    self.surah = surah
    self.ayah = ayah
  }
}

public struct SearchHit: Equatable, Sendable {
  public var surah: Int
  public var ayah: Int
  public var word: Int
  public var wordIndex: Int
  public var refOffset: Int
  public var refEnd: Int
  public var queryStart: Int
  public var distance: Double
}

public struct SearchResult: Equatable, Sendable {
  public var hits: [SearchHit]
  public var decisive: Bool
}

public struct StripResult: Equatable, Sendable {
  public var offset: Int
  public var basmala: Bool
  public var basmalaOffset: Int
}

public struct FallbackHit: Equatable, Sendable {
  public enum How: String, Sendable { case basmala, wholeAyah = "whole-ayah" }
  public var surah: Int
  public var ayah: Int
  public var distance: Double
  public var how: How
}

public struct AyahRef: Hashable, Sendable, Comparable {
  public var surah: Int
  public var ayah: Int
  public init(surah: Int, ayah: Int) {
    self.surah = surah
    self.ayah = ayah
  }
  public static func < (a: AyahRef, b: AyahRef) -> Bool {
    (a.surah, a.ayah) < (b.surah, b.ayah)
  }
}

public enum EngineState: String, Sendable { case searching, tracking }

public enum IdleReason: String, Sendable { case silent, lost }

/// What the engine reports to its host (spec §10).
public enum EngineEvent: Equatable, Sendable {
  case located(surah: Int, ayah: Int, word: Int, replayed: Int)
  case relocated(from: AyahRef, to: AyahRef, word: Int)
  case cursor(surah: Int, ayah: Int, word: Int, wordIndex: Int)
  case verdicts([WordVerdict])
  case lost
  case idle(IdleReason)
  case completed(surah: Int)
  case locateFailed

  public var name: String {
    switch self {
    case .located: return "located"
    case .relocated: return "relocated"
    case .cursor: return "cursor"
    case .verdicts: return "verdicts"
    case .lost: return "lost"
    case .idle: return "idle"
    case .completed: return "completed"
    case .locateFailed: return "locateFailed"
    }
  }
}

/// Stable sort (JS `Array.prototype.sort` is stable; Swift's is not guaranteed).
extension Array {
  func stableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
    enumerated()
      .sorted { a, b in
        if areInIncreasingOrder(a.element, b.element) { return true }
        if areInIncreasingOrder(b.element, a.element) { return false }
        return a.offset < b.offset
      }
      .map(\.element)
  }
}
