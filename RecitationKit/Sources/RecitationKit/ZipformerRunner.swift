/// I/O manifest of a streaming Zipformer2-CTC export (spec §2).
public struct ZipformerIO: Equatable, Sendable {
  public struct Input: Equatable, Sendable {
    public enum DType: String, Sendable { case float32, int64 }
    public var name: String
    public var dims: [Int]
    public var dtype: DType
    public init(name: String, dims: [Int], dtype: DType) {
      self.name = name
      self.dims = dims
      self.dtype = dtype
    }
    public var elementCount: Int { dims.reduce(1, *) }
  }

  /// Fbank frames per forward (T).
  public var windowFrames: Int
  /// Fbank frames consumed per forward.
  public var hopFrames: Int
  public var featureDim: Int
  public var vocabSize: Int
  /// `x` plus every streaming state. Each state `s` is replaced by output `new_s`.
  public var inputs: [Input]

  public var stateInputs: [Input] { inputs.filter { $0.name != "x" } }
}

/// One streaming model: runs a window of features with its own carried state.
/// ONNX Runtime today (the app), Core ML later, a script in tests.
public protocol ZipformerBackend: AnyObject {
  /// Zero every streaming state. Pre-allocate the zero state so this cannot fail.
  func reset()
  /// Run one window of `windowFrames × featureDim` features (row-major) and
  /// carry the states forward. Returns row-major `[frames × vocabSize]` natural-log probabilities.
  func run(features: [Float]) throws -> [Float]
}

/// Buffers fbank frames into overlapping windows (spec §2): run once 61 frames
/// are buffered, then drop 48. A partial window is never scored.
public final class ZipformerRunner {
  public let io: ZipformerIO
  public let backend: ZipformerBackend
  private var pending: [Float] = []
  /// Wall-clock time spent in `backend.run` since creation, and how many runs.
  public private(set) var modelTime: Duration = .zero
  public private(set) var modelRuns = 0

  public init(backend: ZipformerBackend, io: ZipformerIO = .shipped) {
    self.backend = backend
    self.io = io
  }

  public var leftoverFrames: Int { pending.count / io.featureDim }

  public func reset() {
    pending.removeAll(keepingCapacity: true)
    backend.reset()
  }

  /// Append flat fbank frames; returns the log-probs of every window that completed.
  public func accept(_ frames: [Float]) throws -> (logProbs: [Float], frames: Int) {
    pending.append(contentsOf: frames)
    let window = io.windowFrames * io.featureDim
    let hop = io.hopFrames * io.featureDim
    var logProbs: [Float] = []
    while pending.count >= window {
      let start = ContinuousClock.now
      logProbs.append(contentsOf: try backend.run(features: Array(pending[0..<window])))
      modelTime += ContinuousClock.now - start
      modelRuns += 1
      pending.removeFirst(hop)
    }
    return (logProbs, logProbs.count / io.vocabSize)
  }
}
