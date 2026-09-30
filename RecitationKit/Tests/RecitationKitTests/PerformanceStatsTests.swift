import Foundation
import Testing
@testable import RecitationKit

@Suite("Performance stats")
struct PerformanceStatsTests {
  private func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

  @Test func splitsModelAndEngineTimePerWindow() {
    var stats = PerformanceStats()
    #expect(stats.model == nil && stats.realTimeFactor == nil)
    // Two feeds without a model run, then one with a run: the run's engine
    // step absorbs the earlier feeds' fbank time.
    stats.record(audioSamples: 1360, feed: .milliseconds(2), model: .zero, runs: 0, lag: .milliseconds(3))
    stats.record(audioSamples: 1360, feed: .milliseconds(3), model: .zero, runs: 0)
    stats.record(audioSamples: 1360, feed: .milliseconds(30), model: .milliseconds(20), runs: 1, lag: .milliseconds(31))
    // A feed that completes two windows splits its time between them.
    stats.record(audioSamples: 7680, feed: .milliseconds(50), model: .milliseconds(40), runs: 2)
    #expect(stats.runs == 3)
    #expect(close(stats.audioSeconds, (1360 * 3 + 7680) / 16000))
    #expect(close(stats.modelSeconds, 0.060))
    #expect(close(stats.engineSeconds, 0.025))
    #expect(close(stats.model?.p50, 20) && close(stats.model?.max, 20))
    // Engine steps: 2 + 3 + 10 = 15 ms, then 5 ms for each of the two runs.
    #expect(close(stats.engine?.max, 15) && close(stats.engine?.p50, 5))
    #expect(close(stats.lag?.p50, 31) && close(stats.lag?.max, 31))
    #expect(close(stats.realTimeFactor, 0.085 / ((1360 * 3 + 7680) / 16000)))
  }

  @Test func percentilesCoverOnlyTheLatestWindow() {
    var stats = PerformanceStats()
    let n = PerformanceStats.window + 44
    for i in 0..<n { stats.record(audioSamples: 7680, feed: .milliseconds(i), model: .milliseconds(i), runs: 1) }
    #expect(stats.runs == n)
    // Only runs 44..<n remain: 256 values.
    #expect(close(stats.model?.max, Double(n - 1)))
    #expect(close(stats.model?.p50, Double(44 + PerformanceStats.window / 2)))
    #expect(close(stats.model?.p95, Double(44 + PerformanceStats.window * 95 / 100)))
    #expect(close(stats.engine?.max, 0))
  }

  @Test(.enabled(if: hasCorpus)) func sessionTimesEveryModelRun() throws {
    final class SlowBackend: ZipformerBackend {
      let inner: ScriptedBackend
      init(_ inner: ScriptedBackend) { self.inner = inner }
      func reset() { inner.reset() }
      func run(features: [Float]) throws -> [Float] {
        Thread.sleep(forTimeInterval: 0.002)
        return try inner.run(features: features)
      }
    }
    let scripted = ScriptedBackend(frames: [Int](repeating: 250, count: 60))
    let session = RecitationSession(corpus: Shared.corpus!, index: Shared.index!, backend: SlowBackend(scripted))
    #expect(session.modelRuns == 0 && session.modelTime == .zero)
    for _ in 0..<12 { _ = try session.feed([Float](repeating: 0, count: 1360)) }
    #expect(session.modelRuns == scripted.runs && scripted.runs > 0)
    #expect(session.modelTime >= .milliseconds(2 * scripted.runs))
  }
}
