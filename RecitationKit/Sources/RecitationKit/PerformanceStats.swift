/// Rolling wall-clock profile of a live session, for the app's performance
/// readout. The host times each `feed` and takes the model's share from
/// `RecitationSession.modelTime`; one model run covers 480 ms of audio.
public struct PerformanceStats: Sendable {
  /// Milliseconds.
  public struct Summary: Sendable, Equatable {
    public var p50: Double
    public var p95: Double
    public var max: Double
  }

  /// Model runs (and feeds, for lag) kept for the percentiles: about two minutes.
  public static let window = 256

  /// Totals since creation.
  public private(set) var audioSeconds = 0.0
  public private(set) var modelSeconds = 0.0
  public private(set) var engineSeconds = 0.0
  public private(set) var runs = 0

  private var modelMs = Ring()
  private var engineMs = Ring()
  private var lagMs = Ring()
  /// Engine time since the last model run; the next run's step absorbs it.
  private var pendingEngine = 0.0

  public init() {}

  /// One `feed` call: its audio, its wall-clock time, the model's share of it
  /// and runs, and (if known) how long after capture the feed returned.
  public mutating func record(audioSamples: Int, feed: Duration, model: Duration, runs: Int, lag: Duration? = nil) {
    let feedSeconds = feed.seconds, modelShare = model.seconds
    audioSeconds += Double(audioSamples) / Double(Audio.sampleRate)
    modelSeconds += modelShare
    engineSeconds += max(0, feedSeconds - modelShare)
    pendingEngine += max(0, feedSeconds - modelShare)
    if runs > 0 {
      self.runs += runs
      for _ in 0..<runs {
        modelMs.append(modelShare * 1000 / Double(runs))
        engineMs.append(pendingEngine * 1000 / Double(runs))
      }
      pendingEngine = 0
    }
    if let lag { lagMs.append(lag.seconds * 1000) }
  }

  /// Model time per 480 ms window.
  public var model: Summary? { modelMs.summary }
  /// Everything else per 480 ms window: fbank, CTC decode, search, tracking, emission.
  public var engine: Summary? { engineMs.summary }
  /// From capture to the end of the feed that consumed it.
  public var lag: Summary? { lagMs.summary }
  /// Compute time as a fraction of audio time.
  public var realTimeFactor: Double? {
    audioSeconds > 0 ? (modelSeconds + engineSeconds) / audioSeconds : nil
  }

  private struct Ring: Sendable {
    private var values: [Double] = []
    private var next = 0

    mutating func append(_ value: Double) {
      if values.count < PerformanceStats.window {
        values.append(value)
      } else {
        values[next] = value
        next = (next + 1) % PerformanceStats.window
      }
    }

    var summary: Summary? {
      guard !values.isEmpty else { return nil }
      let sorted = values.sorted()
      let n = sorted.count
      return Summary(p50: sorted[n / 2], p95: sorted[min(n - 1, n * 95 / 100)], max: sorted[n - 1])
    }
  }
}

extension Duration {
  var seconds: Double {
    let (s, atto) = components
    return Double(s) + Double(atto) * 1e-18
  }
}
