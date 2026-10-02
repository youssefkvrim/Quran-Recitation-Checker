/// Engine tuning (spec §10, `DEFAULT_CONFIG`). Frame counts are CTC frames at 25 Hz.
public struct EngineConfig: Equatable, Sendable {
  public var jumpCost: Double = 12
  public var repeatCost: Double = 10
  public var commitDwell: Int = 6
  public var okDistance: Double = 0.15
  public var unsureDistance: Double = 0.4
  public var minHeardFraction: Double = 0.34
  public var minMargin: Double = 0.35
  public var lostWindow: Int = 120
  public var lostRate: Double = 0.35
  public var holdWindow: Int = 30
  public var holdRate: Double = 0.45
  public var searchMinChars: Int = 12
  public var searchQueryChars: Int = 250
  public var searchDecisiveDistance: Double = 0.35
  public var searchDecisiveMargin: Double = 0.1
  public var searchEveryFrames: Int = 25
  public var searchEveryChars: Int = 12
  public var locateFailedFrames: Int = 375
  public var relocateEveryFrames: Int = 37
  public var relocateQueryChars: Int = 100
  public var relocateMaxDistance: Double = 0.3
  public var relocateRateMargin: Double = 0.12
  public var idleFrames: Int = 200
  public var maxStruggles: Int = 3
  public var settleFrames: Int = 25
  /// After a complete basmala, decide between the surah openings first
  /// (`SurahOpenings`). Nil reproduces the original engine and its spec
  /// vectors, which lock al-An'ām, al-Kahf, Sabaʾ, Fāṭir, al-Jumuʿa and
  /// at-Taghābun recited with their basmala onto al-Fātiḥa. The app sets
  /// `.standard`.
  public var surahOpenings: SurahOpenings.Rule?

  public init() {}

  public static let `default` = EngineConfig()
}

public enum Audio {
  public static let sampleRate = 16_000
  public static let fbankBins = 80
  public static let frameLength = 400
  public static let frameShift = 160
  /// CTC output frames per second.
  public static let ctcHz = 25
}

/// Heard chars kept for search and relocation queries.
let bufferCap = 1000
