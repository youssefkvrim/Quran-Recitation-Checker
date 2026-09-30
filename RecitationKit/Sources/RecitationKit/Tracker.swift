private let rateMinN = 24

/// Per-surah online edit-distance tracker (spec §8). Heard chars update one
/// float32 column over the whole surah; the cursor is its argmin.
public final class Tracker {
  public let corpus: QuranCorpus
  public let table: CostTable
  public let cfg: EngineConfig
  public let surah: Int
  public let firstWord: Int
  public let endWord: Int
  /// Phoneme length of the surah.
  public let len: Int
  public let surahStart: Int
  public let ref: [UInt8]
  /// Char offset of each word, relative to the surah.
  public let wordStarts: [Int32]
  public let ayahAtStart: [Int32]
  public let localWordOfPos: [Int32]
  public let startLocal: Int

  public private(set) var column: [Float]
  public private(set) var cursorCell: Int
  public private(set) var cursorLocalWord: Int
  public private(set) var cursorCost: Float
  public private(set) var revision = 0
  public private(set) var trail: [Int32] = []
  public private(set) var costs: [Float] = []
  public private(set) var heard: [HeardChar] = []
  public private(set) var lost = false
  /// Second column buffer: `feedOne` writes here, then swaps it with `column`.
  private var spare: [Float]
  /// min(column). After a feed this is the new cursorCost (the column argmin).
  private var colMin: Float = 0

  public init(corpus: QuranCorpus, table: CostTable = .shared, surah: Int, startWordIndex: Int, config: EngineConfig = .default) {
    self.corpus = corpus
    self.table = table
    self.cfg = config
    self.surah = surah
    let rec = corpus.surahs[surah - 1]
    firstWord = rec.firstWord
    endWord = rec.endWord
    surahStart = Int(corpus.wordStart[rec.firstWord])
    let surahEnd = Int(corpus.wordStart[rec.endWord])
    len = surahEnd - surahStart
    ref = Array(corpus.ids[surahStart..<surahEnd])
    let nWords = rec.endWord - rec.firstWord
    var starts = [Int32](repeating: 0, count: nWords)
    var ayahs = [Int32](repeating: 0, count: nWords)
    for i in 0..<nWords {
      starts[i] = corpus.wordStart[rec.firstWord + i] - Int32(surahStart)
      ayahs[i] = corpus.wordAyah[rec.firstWord + i]
    }
    wordStarts = starts
    ayahAtStart = ayahs
    var wordOfPos = [Int32](repeating: 0, count: len)
    for i in 0..<nWords {
      let a = Int(starts[i])
      let b = i + 1 < nWords ? Int(starts[i + 1]) : len
      if a < b { for p in a..<b { wordOfPos[p] = Int32(i) } }
    }
    localWordOfPos = wordOfPos
    startLocal = max(0, Int(corpus.wordStart[startWordIndex]) - surahStart)
    column = [Float](repeating: 0, count: len + 1)
    spare = [Float](repeating: 0, count: len + 1)
    cursorCell = startLocal
    cursorLocalWord = -1
    cursorCost = 0
    resetColumn()
  }

  public var cursorWordIndex: Int { firstWord + max(0, cursorLocalWord) }

  public var reachedEnd: Bool { cursorCell >= len - 1 }

  public func feed<S: Sequence<HeardChar>>(_ chars: S) {
    for h in chars { feedOne(h) }
  }

  public func costRate(window: Int? = nil) -> Double? {
    let n = costs.count
    if n < rateMinN { return nil }
    let w = min(window ?? cfg.lostWindow, n)
    let before = n - w > 0 ? Double(costs[n - w - 1]) : 0
    return (Double(costs[n - 1]) - before) / Double(w)
  }

  /// Forget the last `n` heard chars: the result is the tracker that never fed
  /// them (spec §8). The host never retracts, so this replays the kept prefix.
  public func retract(_ n: Int) {
    if n <= 0 { return }
    revision += 1
    let replay = heard.prefix(max(0, heard.count - n))
    resetColumn()
    heard.removeAll(keepingCapacity: true)
    trail.removeAll(keepingCapacity: true)
    costs.removeAll(keepingCapacity: true)
    feed(Array(replay))
  }

  private func resetColumn() {
    let jump = Float(cfg.jumpCost)
    for m in column.indices { column[m] = .infinity }
    for s in wordStarts {
      let m = Int(s)
      column[m] = m == startLocal ? 0 : jump
    }
    if len > 0 { for m in 1...len { column[m] = min(column[m], Float(Double(column[m - 1]) + 1)) } }
    cursorCell = startLocal
    cursorLocalWord = -1
    cursorCost = 0
    lost = false
    colMin = column.min() ?? 0
  }

  /// One column of the DP (spec §8) in a single pass: a cell's final value is
  /// the float32 of the cheapest of {substitute, insert, delete from the final
  /// left neighbour, restart}, whatever the comparison order, so each cell is
  /// final when written and the argmin scans it at once. Bit-identical to the
  /// spec's sweep + restart floor + argmin (pinned by the tests).
  private func feedOne(_ h: HeardChar) {
    let jump = Double(colMin) + cfg.jumpCost
    let repeatCost = Double(colMin) + cfg.repeatCost
    let cursorAyah: Int32 = cursorLocalWord < 0 ? -1 : corpus.wordAyah[firstWord + cursorLocalWord]
    let cursorPos = cursorCell
    let row = Int(Phonemes.id(h.ch)) * table.size
    let len = self.len
    var bestCell = 0
    var bestCost: Float = 0
    var bestDist = cursorPos
    column.withUnsafeBufferPointer { prev in
      spare.withUnsafeMutableBufferPointer { next in
        table.matrix.withUnsafeBufferPointer { matrix in
          ref.withUnsafeBufferPointer { ref in
            wordStarts.withUnsafeBufferPointer { starts in
              ayahAtStart.withUnsafeBufferPointer { ayahAt in
                let nStarts = starts.count
                var si = 0
                var v = Float(Double(prev[0]) + 1)
                while si < nStarts && starts[si] == 0 {
                  let r = ayahAt[si] == cursorAyah ? repeatCost : jump
                  if r < Double(v) { v = Float(r) }
                  si += 1
                }
                next[0] = v
                var left = Double(v)
                bestCost = v
                var m = 1
                while m <= len {
                  v = Float(Double(prev[m - 1]) + Double(matrix[row + Int(ref[m - 1])]))
                  let ins = Double(prev[m]) + 1
                  if ins < Double(v) { v = Float(ins) }
                  let del = left + 1
                  if del < Double(v) { v = Float(del) }
                  while si < nStarts && Int(starts[si]) == m {
                    let restart = m <= cursorPos && ayahAt[si] == cursorAyah ? repeatCost : jump
                    if restart < Double(v) { v = Float(restart) }
                    si += 1
                  }
                  next[m] = v
                  left = Double(v)
                  if v <= bestCost {
                    let d = m > cursorPos ? m - cursorPos : cursorPos - m
                    if v < bestCost || d < bestDist {
                      bestCost = v
                      bestCell = m
                      bestDist = d
                    }
                  }
                  m += 1
                }
              }
            }
          }
        }
      }
    }
    swap(&column, &spare)
    colMin = bestCost
    cursorCell = bestCell
    cursorLocalWord = bestCell == 0 ? 0 : Int(localWordOfPos[min(bestCell, len) - 1])
    cursorCost = bestCost
    trail.append(Int32(bestCell))
    costs.append(bestCost)
    heard.append(h)
    if let rate = costRate(window: cfg.lostWindow) { lost = rate >= cfg.lostRate } else { lost = false }
  }
}
