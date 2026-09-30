import Foundation

/// Greedy CTC decoding with peak-frame margins (spec §3). A token is emitted
/// when its run ends (blank or a different class); tokens are never revised.
public final class GreedyCtcDecoder {
  public let symbols: [[Phone]]
  public let blank: Int
  /// For tokens ending in a short vowel: ids of the same token spelled with
  /// fatha, damma, kasra (-1 when absent).
  private let siblings: [[Int]?]
  private var previousBest: Int
  public private(set) var framesDecoded = 0
  private var run: (id: Int, frame: Int, p1: Double, p2: Double, vowels: VowelProbs?)?

  public init(symbols: [String] = zipformerTokens, blank: Int = 250) {
    let units = symbols.map { Array($0.utf16) }
    self.symbols = units
    self.blank = blank
    previousBest = blank
    var byText: [[Phone]: Int] = [:]
    for (i, s) in units.enumerated() { byText[s] = i }
    let vowels = [Phonemes.fatha, Phonemes.damma, Phonemes.kasra]
    siblings = units.map { sym in
      guard let last = sym.last, vowels.contains(last) else { return nil }
      let stem = sym.dropLast()
      return vowels.map { byText[stem + [$0]] ?? -1 }
    }
  }

  public func reset() {
    previousBest = blank
    framesDecoded = 0
    run = nil
  }

  /// Decode `frames` rows of `classes` natural-log probabilities.
  public func consume(_ logProbs: UnsafeBufferPointer<Float>, frames: Int, classes: Int) -> [CtcToken] {
    var out: [CtcToken] = []
    for t in 0..<frames {
      let row = t * classes
      var best = 0
      var p1 = Double(logProbs[row])
      var p2 = -Double.infinity
      for c in 1..<classes {
        let p = Double(logProbs[row + c])
        if p > p1 {
          p2 = p1
          p1 = p
          best = c
        } else if p > p2 {
          p2 = p
        }
      }
      var vowels: VowelProbs?
      if best != blank, let sib = siblings[best] {
        let prob = { (k: Int) -> Double in sib[k] >= 0 ? exp(Double(logProbs[row + sib[k]])) : 0 }
        vowels = VowelProbs(fatha: prob(0), damma: prob(1), kasra: prob(2))
      }
      step(best, p1, p2, vowels, &out)
    }
    return out
  }

  public func consume(_ logProbs: [Float], frames: Int, classes: Int) -> [CtcToken] {
    logProbs.withUnsafeBufferPointer { consume($0, frames: frames, classes: classes) }
  }

  /// End of stream: emit the open run.
  public func flush() -> [CtcToken] {
    var out: [CtcToken] = []
    if let r = run {
      out.append(emit(r))
      run = nil
    }
    previousBest = blank
    return out
  }

  private func step(_ best: Int, _ p1: Double, _ p2: Double, _ vowels: VowelProbs?, _ out: inout [CtcToken]) {
    if best != blank && best != previousBest {
      if let r = run { out.append(emit(r)) }
      run = (best, framesDecoded, p1, p2, vowels)
    } else if best != blank && best == previousBest, let r = run, p1 > r.p1 {
      run = (r.id, r.frame, p1, p2, vowels)
    } else if best == blank, let r = run {
      out.append(emit(r))
      run = nil
    }
    previousBest = best
    framesDecoded += 1
  }

  private func emit(_ r: (id: Int, frame: Int, p1: Double, p2: Double, vowels: VowelProbs?)) -> CtcToken {
    CtcToken(symbol: r.id < symbols.count ? symbols[r.id] : [], frame: r.frame, margin: exp(r.p1) - exp(r.p2), vowels: r.vowels)
  }
}
