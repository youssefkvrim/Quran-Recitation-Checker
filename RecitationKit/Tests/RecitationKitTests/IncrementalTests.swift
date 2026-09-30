import Testing
@testable import RecitationKit

/// The tracker DP and the verdict trace are computed incrementally for speed.
/// These pin them to the plain spec definitions (spec §8-§9).
@Suite("Incremental computation")
struct IncrementalTests {
  /// Spec §8 exactly as written: sweep, then restart floor with forward
  /// delete-propagation, then argmin (fresh column each char).
  private struct Reference {
    var column: [Float]
    var cursorCell: Int
    var cursorLocalWord = -1

    mutating func step(_ t: Tracker, _ h: HeardChar) -> Float {
      let cfg = t.cfg
      let prev = column
      var next = [Float](repeating: 0, count: t.len + 1)
      let colMin = prev.min()!
      let jump = Double(colMin) + cfg.jumpCost
      let repeatCost = Double(colMin) + cfg.repeatCost
      let cursorAyah: Int32 = cursorLocalWord < 0 ? -1 : t.corpus.wordAyah[t.firstWord + cursorLocalWord]
      let hid = Phonemes.id(h.ch)
      next[0] = Float(Double(prev[0]) + 1)
      for m in 1...t.len {
        next[m] = Float(Double(prev[m - 1]) + Double(t.table.cost(hid, t.ref[m - 1])))
        if Double(prev[m]) + 1 < Double(next[m]) { next[m] = Float(Double(prev[m]) + 1) }
        if Double(next[m - 1]) + 1 < Double(next[m]) { next[m] = Float(Double(next[m - 1]) + 1) }
      }
      for (i, s) in t.wordStarts.enumerated() {
        let m = Int(s)
        let restart = m <= cursorCell && t.ayahAtStart[i] == cursorAyah ? repeatCost : jump
        if restart < Double(next[m]) {
          next[m] = Float(restart)
          var j = m + 1
          while j <= t.len && Double(next[j - 1]) + 1 < Double(next[j]) {
            next[j] = Float(Double(next[j - 1]) + 1)
            j += 1
          }
        }
      }
      var best = 0
      for m in 1...t.len where next[m] < next[best] || (next[m] == next[best] && abs(m - cursorCell) < abs(best - cursorCell)) {
        best = m
      }
      column = next
      cursorCell = best
      cursorLocalWord = best == 0 ? 0 : Int(t.localWordOfPos[min(best, t.len) - 1])
      return next[best]
    }
  }

  @Test(.enabled(if: hasCorpus), arguments: [(1, 1, 7, UInt32(1)), (112, 1, 4, 2), (36, 1, 12, 3), (2, 1, 3, 4)])
  func trackerMatchesSpecDefinition(_ surah: Int, _ from: Int, _ to: Int, _ seed: UInt32) throws {
    let c = Shared.corpus!
    let chars = perturbed(recitation(c, surah, from, to), seed: seed)
    let tracker = Tracker(corpus: c, surah: surah, startWordIndex: try c.wordIndex(surah, from, 0))
    var ref = Reference(column: tracker.column, cursorCell: tracker.cursorCell)
    for h in chars {
      let cost = ref.step(tracker, h)
      tracker.feed([h])
      #expect(tracker.cursorCell == ref.cursorCell)
      #expect(tracker.cursorLocalWord == ref.cursorLocalWord)
      #expect(tracker.cursorCost == cost)
      #expect(tracker.column.elementsEqual(ref.column) { $0.bitPattern == $1.bitPattern })
      if tracker.cursorCell != ref.cursorCell { break }
    }
  }

  @Test(.enabled(if: hasCorpus)) func retractIsTheTrackerThatNeverHeard() throws {
    let c = Shared.corpus!
    let chars = perturbed(recitation(c, 67, 1, 6), seed: 5)
    let start = try c.wordIndex(67, 1, 0)
    let tracker = Tracker(corpus: c, surah: 67, startWordIndex: start)
    tracker.feed(chars)
    for n in [7, 40, 0, 1000] {
      let keep = max(0, tracker.heard.count - n)
      let kept = Array(tracker.heard.prefix(keep))
      tracker.retract(n)
      let fresh = Tracker(corpus: c, surah: 67, startWordIndex: start)
      fresh.feed(kept)
      #expect(tracker.heard == fresh.heard && tracker.trail == fresh.trail && tracker.costs == fresh.costs)
      #expect(tracker.column == fresh.column && tracker.cursorCell == fresh.cursorCell && tracker.lost == fresh.lost)
      let more = Array(chars[keep..<min(chars.count, keep + 25)])
      tracker.feed(more)
      fresh.feed(more)
      #expect(tracker.column == fresh.column)
    }
  }

  @Test(.enabled(if: hasCorpus), arguments: [(67, 1, 14, UInt32(11)), (18, 1, 12, 12), (104, 1, 9, 13)])
  func cachedVerdictsEqualAFreshTrace(_ surah: Int, _ from: Int, _ to: Int, _ seed: UInt32) throws {
    let c = Shared.corpus!
    let chars = perturbed(recitation(c, surah, from, to), seed: seed)
    #expect(chars.count > 300) // crosses a segment cut
    let tracker = Tracker(corpus: c, surah: surah, startWordIndex: try c.wordIndex(surah, from, 0))
    let tracer = VerdictTracer(tracker: tracker)
    var backward = 0
    for (i, h) in chars.enumerated() {
      tracker.feed([h])
      if tracker.trail.count > 1 && tracker.trail[tracker.trail.count - 1] < tracker.trail[tracker.trail.count - 2] { backward += 1 }
      if i % 5 != 0 && i != chars.count - 1 { continue }
      for settled in [false, true] {
        let got = tracer.verdicts(settled: settled)
        #expect(tracer.verdicts(settled: settled).elementsEqual(got, by: ===)) // memoised until the tracker moves
        #expect(got == VerdictTracer(tracker: tracker).verdicts(settled: settled))
      }
    }
    #expect(backward > 0) // the recitation really jumped back
  }
}
