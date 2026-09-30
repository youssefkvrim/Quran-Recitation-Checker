import Foundation
import Testing
@testable import RecitationKit

/// Opt-in (`RUN_PERF=1`, release build): engine cost per 480 ms chunk over a
/// long scripted recitation. The model is scripted, so this is the JS-port
/// equivalent of the v0.1 profile: fbank + CTC decode + engine + emission.
@Suite("Performance", .enabled(if: ProcessInfo.processInfo.environment["RUN_PERF"] == "1" && hasCorpus))
struct PerformanceTests {
  @Test(arguments: [(2, 1, 120), (18, 1, 110)])
  func longRecitation(_ surah: Int, _ from: Int, _ to: Int) throws {
    let c = Shared.corpus!
    let ids = Dictionary(zipformerTokens.enumerated().filter { $0.element.utf16.count == 1 }.map { ($0.element.utf16.first!, $0.offset) },
                         uniquingKeysWith: { a, _ in a })
    var frames: [Int] = []
    for a in from...to {
      for ch in c.ayahPhonemes(surah, a) { frames += [ids[ch]!, 250] }
      frames += [Int](repeating: 250, count: 15)
    }
    let backend = ScriptedBackend(frames: frames)
    let session = RecitationSession(corpus: c, index: Shared.index!, backend: backend)
    let chunk = [Float](repeating: 0, count: 7680)
    var times: [Double] = []
    var matches = 0
    let clock = ContinuousClock()
    while !backend.done {
      var events: [RecitationEvent] = []
      let t = clock.measure { events = try! session.feed(chunk) }
      times.append(Double(t.components.attoseconds) / 1e15 + Double(t.components.seconds) * 1e3)
      matches += events.filter { if case .verseMatch = $0 { return true }; return false }.count
    }
    let sorted = times.sorted()
    let tenth = max(1, times.count / 10)
    func avg(_ xs: ArraySlice<Double>) -> String { String(format: "%.2f", xs.reduce(0, +) / Double(xs.count)) }
    print(String(format: "PERF surah %d:%d-%d  chunks %d (%.0f s audio)  p50 %.2f ms  p99 %.2f ms  max %.2f ms  first-tenth %@ ms  last-tenth %@ ms  total %.0f ms  matches %d",
                 surah, from, to, times.count, Double(times.count) * 0.48, sorted[sorted.count / 2], sorted[sorted.count * 99 / 100], sorted.last!,
                 avg(times.prefix(tenth)), avg(times.suffix(tenth)), times.reduce(0, +), matches))
    #expect(matches == to - from + 1)
  }
}
